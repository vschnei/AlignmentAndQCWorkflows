#!/bin/bash
#
# Copyright (c) 2019 German Cancer Research Center (DKFZ).
#
# Distributed under the MIT License (license terms are at https://github.com/DKFZ-ODCF/AlignmentAndQCWorkflows).
#

set -o pipefail
set -ue

source "$TOOL_WORKFLOW_LIB"

printInfo

setUp_BashSucksVersion
trap "echo 'Exit trap called -- cleaning up' >> /dev/stderr; cleanUp_BashSucksVersion" EXIT

ID="${RUN}_$LANE"
SM="sample_${SAMPLE}_$PID"

# RODDY_SCRATCH is used here. It is $PBS_SCRATCH_DIR/$PBS_JOBID for Torque/PBS, and /tmp/roddyScratch/jobid for SGE.
RODDY_BIG_SCRATCH=$(getBigScratchDirectory "$FILENAME_SORTED_BAM.tmp")
mkdir -p "$RODDY_BIG_SCRATCH"

# pipes via local scratch dir
NP_READBINS_IN="$RODDY_SCRATCH/np_readbins_in"
NP_COVERAGEQC_IN="$RODDY_SCRATCH/np_coverageqc_in"
NP_COMBINEDANALYSIS_IN="$RODDY_SCRATCH/np_combinedanalysis_in"
NP_FLAGSTATS="$RODDY_SCRATCH/np_flagstats_in"
NP_SAMTOOLS_INDEX_IN="$RODDY_SCRATCH/np_samtools_index_in"
NP_BWA_OUT="$RODDY_SCRATCH/np_bwa_out"
NP_BCONV_OUT="$RODDY_SCRATCH/np_bconv_out"

MBUF_SMALL="${MBUFFER_BINARY} -m '$MBUFFER_SIZE_SMALL' -q -l /dev/null"
MBUF_LARGE="${MBUFFER_BINARY} -m '$MBUFFER_SIZE_LARGE' -q -l /dev/null"

mkfifo ${NP_READBINS_IN} ${NP_COVERAGEQC_IN} ${NP_COMBINEDANALYSIS_IN} ${NP_FLAGSTATS} ${NP_BWA_OUT} ${NP_BCONV_OUT}

bamname=$(basename "$FILENAME_SORTED_BAM")
INDEX_FILE="$FILENAME_SORTED_BAM.bai"
tempSortedBamFile="$FILENAME_SORTED_BAM.tmp"
tempFileForSort="$RODDY_BIG_SCRATCH/${bamname}_forsorting"
tempBamIndexFile="$FILENAME_SORTED_BAM.tmp.bai"
tempFlagstatsFile="$FILENAME_FLAGSTATS.tmp"

# Error tracking
# samtools sort may complain about truncated temp files and for each line outputs
# the error message. This happens when the same files are written at the same time,
# see http://sourceforge.net/p/samtools/mailman/samtools-help/thread/BAA90EF6FE3B4D45A7B2F6E0EC5A8366DA3AB5@USTLMLLYC102.rf.lilly.com/
TMP_FILE="$tempSortedBamFile"
FILENAME_BWA_LOG="$DIR_TEMP/${bamname}_errlog_bwamem"
NP_SORT_ERRLOG="$RODDY_SCRATCH/NP_SORT_ERRLOG"
FILENAME_SORT_LOG="$DIR_TEMP/${bamname}_errlog_sort"
FILENAME_BWA_EC="$DIR_TEMP/${bamname}_ec_bbam"
NP_BAMSORT="$RODDY_SCRATCH/NAMED_PIPE_BAMSORT"
mkfifo "$NP_BAMSORT"


if [[ -n "$RAW_SEQ_1" ]]; then
    source "$TOOL_DEFAULT_PLUGIN_LIB"
    setCompressionToolsBasedOnFileCompression "$RAW_SEQ_1"
fi

# In case the BAM already exists, but QC files are missing, create these only
# TODO: This logic currently is not directly/simply reflected. Instead there are multiple if branches. Consider refactoring.
bamFileExists=false
if [[ -f "$FILENAME_SORTED_BAM" ]] && [[ -s "$FILENAME_SORTED_BAM" ]]; then
    checkBamIsComplete "$FILENAME_SORTED_BAM"
	bamFileExists=true
fi

# Test whether one of the fastq files is a fake fastq file to simulate paired-end sequencing in PIDs with mixed sequencing (single- and paired-end).
declare -i LENGTH_SEQ_1=$(getFastqAsciiStream "$RAW_SEQ_1" | head | wc -l)
declare -i LENGTH_SEQ_2=$(getFastqAsciiStream "$RAW_SEQ_2" | head | wc -l)
if [[ $LENGTH_SEQ_1 -eq 0 ]] && [[ $LENGTH_SEQ_2 -eq 0 ]]; then
    throw 1 "Both input files are empty: '$RAW_SEQ_1' and '$RAW_SEQ_2'"
elif [[ $LENGTH_SEQ_1 -eq 0 ]] || [[ $LENGTH_SEQ_2 -eq 0 ]]; then
    useSingleEndProcessing=true
fi


# Determine the quality score
set +e   # The following few lines fail with exit 141 due to unknown reasons if `set -e` is set.
if [[ $LENGTH_SEQ_1 -ne 0 ]]; then
    qualityScore=$(getFastqAsciiStream "$RAW_SEQ_1" | "$PERL_BINARY" "$TOOL_SEQUENCER_DETECTION")
else
    qualityScore=$(getFastqAsciiStream "$RAW_SEQ_2" | "$PERL_BINARY" "$TOOL_SEQUENCER_DETECTION")
fi
set -e

# Default: Dummy process IDs to simplify downstream logic.
# TODO Remove after completely switching to PID registry system.
true & procUnpack1=$!
true & procUnpack2=$!

fqName="fastq"
mkPipePairSource "$fqName"
if [[ "$bamFileExists" == "false" ]]; then	# we have to make the BAM
    getFastqAsciiStream "$RAW_SEQ_1" > $(getPairedPipeEndPath 1 "$fqName") & procUnpack1=$!
    getFastqAsciiStream "$RAW_SEQ_2" > $(getPairedPipeEndPath 2 "$fqName") & procUnpack2=$!

    if [[ "$qualityScore" == "illumina" ]]; then
        extendPipe $(mkPairedPipeName 1 "$fqName") "qScore" -- toIlluminaScore
        extendPipe $(mkPairedPipeName 2 "$fqName") "qScore" -- toIlluminaScore
    fi

    if [[ "${useAdaptorTrimming:-false}" == "true" ]]; then
        extendPipePair "$fqName" "trimmomatic" -- trimmomatic
    fi

    if [[ "${reorderUndirectionalWGBSReadPairs:-false}" == "true" ]]; then
        extendPipePair "$fqName" "reorder" -- reorderUndirectionalReads
    fi

    extendPipe $(mkPairedPipeName 1 "$fqName") "fqconv" -- methylCfqconv 1
	extendPipe $(mkPairedPipeName 2 "$fqName") "fqconv" -- methylCfqconv 2

    INPUT_PIPES=""
    if [[ ${LENGTH_SEQ_1} == 0 ]]; then
        cat "$(getPairedPipeEndPath 1 $fqName)" > /dev/null
    else
	    INPUT_PIPES="$(getPairedPipeEndPath 1 $fqName)"
    fi

    if [[ ${LENGTH_SEQ_2} == 0 ]]; then
        cat "$(getPairedPipeEndPath 2 $fqName)" > /dev/null
    else
	    INPUT_PIPES="${INPUT_PIPES} $(getPairedPipeEndPath 2 $fqName)"
    fi
fi

# Try to read from pipes BEFORE they are filled.
# In all cases:
# SAM output is piped to perl script that calculates various QC measures
$PERL_BINARY "$TOOL_COMBINED_BAM_ANALYSIS" \
    -i "$NP_COMBINEDANALYSIS_IN" \
    -a "$FILENAME_DIFFCHROM_MATRIX.tmp" \
    -c "$CHROM_SIZES_FILE" \
    -b "$FILENAME_ISIZES_MATRIX.tmp" \
    -f "$FILENAME_EXTENDED_FLAGSTATS.tmp" \
    -m "$FILENAME_ISIZES_STATISTICS.tmp" \
    -o "$FILENAME_DIFFCHROM_STATISTICS.tmp" \
    -p "$INSERT_SIZE_LIMIT" \
     & procIDCBA=$!

# Genome coverage (depth of coverage and other QC measures in one file)
$TOOL_COVERAGE_QC_D_IMPL \
    --alignmentFile="$NP_COVERAGEQC_IN" \
    --outputFile="$FILENAME_GENOME_COVERAGE.tmp" \
    --processors=1 \
    --basequalCutoff="$BASE_QUALITY_CUTOFF" \
    --ungappedSizes="$CHROM_SIZES_FILE" \
     & procIDGenomeCoverage=$!

# Read bins
$TOOL_GENOME_COVERAGE_D_IMPL \
    --alignmentFile="$NP_READBINS_IN" \
    --outputFile=/dev/stdout \
    --processors=4 \
    --mode=countReads \
    --windowSize="$WINDOW_SIZE" \
    | $MBUF_SMALL \
    | $PERL_BINARY $TOOL_FILTER_READ_BINS - "$CHROM_SIZES_FILE" \
    > "$FILENAME_READBINS_COVERAGE.tmp" \
    & procIDReadbinsCoverage=$!

# Use sambamba for flagstats
cat "$NP_FLAGSTATS" \
    | $SAMBAMBA_FLAGSTATS_BINARY flagstat -t 1 /dev/stdin \
    > "$tempFlagstatsFile" \
    & procIDFlagstat=$!

if [[ "$bamFileExists" == "true" ]]; then
	echo "The BAM file already exists, re-creating other output files."
	(cat ${FILENAME_SORTED_BAM} \
	    | ${MBUF_LARGE} \
	    | tee ${NP_COVERAGEQC_IN} ${NP_READBINS_IN} ${NP_FLAGSTATS} \
	    | ${SAMBAMBA_BINARY} view /dev/stdin \
	    | ${MBUF_LARGE} \
	    > $NP_COMBINEDANALYSIS_IN) \
	    & procIDOutPipe=$!

	wait $procIDOutPipe || throw 13 "Error from sambamba view pipe"
else
    # We use samtools for making the index.
    # Filter secondary and supplementary alignments (flag 2304) after alignment.
    mkfifo $NP_SORT_ERRLOG ${NP_SAMTOOLS_INDEX_IN}

    # Index bam file
    ${SAMTOOLS_BINARY} index ${NP_SAMTOOLS_INDEX_IN} ${tempBamIndexFile} & procID_IDX=$!

    # Align converted fastq files
    ${BWA_BINARY} mem \
        -t ${BWA_MEM_THREADS} \
        -R "@RG\tID:${ID}\tSM:${SM}\tLB:${LB}\tPL:ILLUMINA" \
        $BWA_MEM_OPTIONS ${INDEX_PREFIX} ${INPUT_PIPES} 2> $FILENAME_BWA_LOG \
    > ${NP_BWA_OUT} & procID_BWA=$!

    # Convert aligned reads back to original state
    ${SAMTOOLS_BINARY} view -uSbh -F 2304 ${NP_BWA_OUT} | \
    ${PYTHON_BINARY} ${TOOL_METHYL_C_TOOLS} bconv - - \
    > ${NP_BCONV_OUT} & procID_BCONV=$!

    # Sort bam file
    (set -o pipefail; \
        ${SAMTOOLS_BINARY} view -h ${NP_BCONV_OUT} | \
        tee ${NP_COMBINEDANALYSIS_IN} | \
        ${SAMTOOLS_BINARY} view -uSbh -F 2304 - | \
        $MBUF_LARGE | \
        ${SAMTOOLS_BINARY} sort -@ 8 \
            -m ${SAMPESORT_MEMSIZE} \
            -o - ${tempFileForSort} 2>$NP_SORT_ERRLOG | \
        tee ${NP_COVERAGEQC_IN} \
            ${NP_READBINS_IN} \
            ${NP_FLAGSTATS} \
            ${NP_SAMTOOLS_INDEX_IN} > ${tempSortedBamFile}; \
        echo "$? (Pipe Exit Codes: ${PIPESTATUS[@]})" > "$FILENAME_BWA_EC") \
        & procID_MEMSORT=$!

    # Filter samtools error log
    (cat $NP_SORT_ERRLOG | uniq > $FILENAME_SORT_LOG) & procID_logwrite=$!

    # Check for errors
    wait $procID_logwrite	# Do we need a check for it?
    wait $procID_BWA || throw 20 "Error in BWA alignment"
    wait $procID_BCONV || throw 21 "Error in BCONV"
    wait $procID_MEMSORT || throw 24 "Error in samtools sort"
    wait $procID_IDX || throw 10 "Error from samtools index"

fi

if [[ "$bamFileExists" == "true" ]]; then
	wait $procIDOutPipe || throw 13 "Error from sambamba view pipe"
else	# Make sure to rename BAM file when it has been produced correctly
    errorString="There was a non-zero exit code in the bwa mem - sort pipeline; exiting..."
    source "$TOOL_BWA_ERROR_CHECKING_SCRIPT"
	checkBamIsComplete "$tempSortedBamFile"
	mv ${tempSortedBamFile} ${FILENAME_SORTED_BAM} || throw 36 "Could not move file"
	# index is only created by samtools or biobambam when producing the BAM, it may be older than the BAM, so update time stamp
	if [[ -f ${tempBamIndexFile} ]]; then
	 	mv ${tempBamIndexFile} ${INDEX_FILE} && touch ${INDEX_FILE} || throw 37 "Could not move file"
	fi
fi

waitForRegisteredPids_BashSucksVersion
wait $procUnpack1 || throw 39 "Error from reading FASTQ 1"
wait $procUnpack1 || throw 40 "Error from reading FASTQ 2"

wait $procIDFlagstat || throw 14 "Error from sambamba flagstats"
wait $procIDReadbinsCoverage || throw 15 "Error from genomeCoverage read bins"
wait $procIDGenomeCoverage || throw 16 "Error from coverageQCD"
wait $procIDCBA || throw 17 "Error from combined QC perl script"

runFingerprinting "$FILENAME_SORTED_BAM" "$FILENAME_FINGERPRINTS"

# Post-pipe processing steps compiling QC information.

# Remove old warnings file if it exists (due to errors in run such as wrong chromsizes file).
# This is to ensure that old warning are not confused as new warnings!
if [[ -f "${FILENAME_QCSUMMARY}_WARNINGS.txt" ]]; then
    rm "${FILENAME_QCSUMMARY}_WARNINGS.txt"
fi
"$PERL_BINARY" "$TOOL_WRITE_QC_SUMMARY" \
    -p "$PID" \
    -s "$SAMPLE" \
    -r "$RUN" \
    -l "$LANE" \
    -w "${FILENAME_QCSUMMARY}_WARNINGS.txt" \
    -f "$tempFlagstatsFile.tmp" \
    -d "$FILENAME_DIFFCHROM_STATISTICS.tmp" \
    -i "$FILENAME_ISIZES_STATISTICS.tmp" \
    -c "$FILENAME_GENOME_COVERAGE.tmp" \
    > "$FILENAME_QCSUMMARY.tmp" \
    || throw 14 "Error from writeQCsummary.pl"

# Produce qualitycontrol.json for OTP.
"$PERL_BINARY" "$TOOL_QC_JSON" \
    "$FILENAME_GENOME_COVERAGE.tmp" \
    "$FILENAME_GROUPED_GENOME_COVERAGE.tmp" \
    "$FILENAME_ISIZES_STATISTICS.tmp" \
    "$tempFlagstatsFile" \
    "$FILENAME_DIFFCHROM_STATISTICS.tmp" \
    > "$FILENAME_QCJSON.tmp" \
    || throw 25 "Error when compiling '${FILENAME_QCJSON}', stopping here"

# Plots are only made for paired end and not on convey
if [[ "${useSingleEndProcessing:-false}" == "false" ]]; then

    $RSCRIPT_BINARY "$TOOL_INSERT_SIZE_PLOT_SCRIPT" \
        "$FILENAME_ISIZES_MATRIX.tmp" \
        "$FILENAME_ISIZES_STATISTICS.tmp" \
        "$FILENAME_ISIZES_PLOT.tmp" \
        "PE insertsize of $bamname" \
        || throw 22 "Error from insert sizes plotter "$(basename "$TOOL_INSERT_SIZE_PLOT_SCRIPT")

    $RSCRIPT_BINARY "$TOOL_PLOT_DIFFCHROM" \
        -i "$FILENAME_DIFFCHROM_MATRIX.tmp" \
        -s "$FILENAME_DIFFCHROM_STATISTICS.tmp" \
        -o "$FILENAME_DIFFCHROM_PLOT.tmp" \
        || throw 23 "Error from "$(basename "$TOOL_PLOT_DIFFCHROM")
fi

# Final phase. Move temporary files to final locations.
mv "$FILENAME_DIFFCHROM_MATRIX.tmp" "$FILENAME_DIFFCHROM_MATRIX" || throw 28 "Could not move file"
mv "$FILENAME_ISIZES_MATRIX.tmp" "$FILENAME_ISIZES_MATRIX" || throw 29 "Could not move file"
mv "$FILENAME_EXTENDED_FLAGSTATS.tmp" "$FILENAME_EXTENDED_FLAGSTATS" || throw 30 "Could not move file"
mv "$FILENAME_ISIZES_STATISTICS.tmp" "$FILENAME_ISIZES_STATISTICS" || throw 31 "Could not move file"
mv "$FILENAME_DIFFCHROM_STATISTICS.tmp" "$FILENAME_DIFFCHROM_STATISTICS" || throw 32 "Could not move file"
mv "$FILENAME_READBINS_COVERAGE.tmp" "$FILENAME_READBINS_COVERAGE" || throw 34 "Could not move file"
mv "$FILENAME_GENOME_COVERAGE.tmp" "$FILENAME_GENOME_COVERAGE" || throw 35 "Could not move file"
mv "$tempFlagstatsFile" "$FILENAME_FLAGSTATS" || throw 33 "Could not move file"
mv "$FILENAME_QCSUMMARY.tmp" "$FILENAME_QCSUMMARY" || throw 27 "Could not move file"
mv "$FILENAME_QCJSON.tmp" "$FILENAME_QCJSON" || throw 27 "Could not move file"

if [[ "${useSingleEndProcessing:-false}" == "false" ]] && [[ "$ON_CONVEY" == "false" ]]; then
    mv "$FILENAME_ISIZES_PLOT.tmp" "$FILENAME_ISIZES_PLOT" || throw 27 "Could not move file"
    mv "$FILENAME_DIFFCHROM_PLOT.tmp" "$FILENAME_DIFFCHROM_PLOT" || throw 27 "Could not move file"
fi

removeRoddyBigScratch
