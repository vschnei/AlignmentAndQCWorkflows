##############################################################################
## Domain-specific code (maybe put this into a dedicated library file)
##############################################################################
##
## Include into your code with: source "$TOOL_WORKFLOW_LIB"
##

source "$TOOL_BASH_LIB"

WORKFLOWLIB___SHELL_OPTIONS=$(set +o)
set +o verbose
set +o xtrace

markWithPicard () {
    [[ "$markDuplicatesVariant" == "picard" || ("$markDuplicatesVariant" == "" && "$useBioBamBamMarkDuplicates" == "false") ]]
    return $?
}


markWithSambamba () {
    [[ "$markDuplicatesVariant" == "sambamba" ]]
    return $?
}


markWithBiobambam () {
    [[ "$markDuplicatesVariant" == "biobambam" || ("$markDuplicatesVariant" == "" && "$useBioBamBamMarkDuplicates" == "true") ]]
    return $?
}


mbuf () {
    local bufferSize="$1"
    shift
    assertNonEmpty "$bufferSize" "No buffer size defined for mbuf()" || return $?
    "$MBUFFER_BINARY" -m "$bufferSize" -q -l /dev/null ${@}
}


## The return the directory, to which big temporary files should be written, e.g. for sorting.
getBigScratchDirectory () {
    local suggestedLocation="${1}"
    local scratchDir
    if [[ "${useRoddyScratchAsBigFileScratch:-false}" == true ]]; then
        scratchDir="${RODDY_SCRATCH}"
    elif [[ -z $suggestedLocation ]]; then
        scratchDir="$outputAnalysisBaseDirectory/tmp"
    else
        scratchDir="$suggestedLocation"
    fi
    mkdir -p "$scratchDir" || throw "$NOT_WRITABLE_CODE" "$NOT_WRITABLE_MSG: '$scratchDir'"
    echo "$scratchDir"
}



analysisType () {
    if [[  "${runExomeAnalysis-false}" = "true" ]]; then
        echo "exome"
    else
        echo "genome"
    fi
}


md5File () {
   local inputFile="${1-/dev/stdin}"
   local outputFile="${2-/dev/stdout}"
   assertNonEmpty "$inputFile"  "inputFile not defined" || return $?
   assertNonEmpty "$outputFile" "outputFile not defined" || return $?
   cat "$inputFile" \
        | ${CHECKSUM_BINARY} \
        | cut -d ' ' -f 1 \
        > "$outputFile"
}


samtoolsIndex () {
   local inputFile="${1-/dev/stdin}"
   local outputFile="${2-/dev/stdout}"
   assertNonEmpty "$inputFile"  "inputFile not defined" || return $?
   assertNonEmpty "$outputFile" "outputFile not defined" || return $?
   "$SAMTOOLS_BINARY" index "$inputFile" "$outputFile"
}


fakeDupMarkMetrics () {
   local inputFile="${1-/dev/stdin}"
   local outputFile="${2-/dev/stdout}"
   assertNonEmpty "$inputFile"  "inputFile not defined" || return $?
   assertNonEmpty "$outputFile" "outputFile not defined" || return $?
   "$PERL_BINARY" "$TOOL_FAKE_DUPMARK_METRICS" "$inputFile" "${SAMPLE}_${pid}" \
        > "$outputFile"
}


toIEqualsList () {
    declare -a inputFiles=($@)
    for inFile in ${inputFiles[@]}; do
	    echo -n "I=$inFile "
    done
    echo
}


# Stolen from http://stackoverflow.com/questions/3685970/check-if-an-array-contains-a-value
arrayContains () {
    local ELEMENT="${1}"
    assertNonEmpty "$ELEMENT" "arrayContains called without parameters" || return $?
    local DELIM=","
    printf "${DELIM}%s${DELIM}" "${@:2}" | grep -q "${DELIM}${ELEMENT}${DELIM}"
}

matchPrefixInArray () {
    local ELEMENT="${1}"
    assertNonEmpty "$ELEMENT" "matchPrefixInArray called without parameters" || return $?
    local DELIM=" "
    printf "${DELIM}%s${DELIM}" "${@:2}" | grep -q -P "${DELIM}${ELEMENT}[^${DELIM}]*${DELIM}"
}

isControlSample () {
    assertNonEmpty "$1" "isControlSample expects sample type name as single parameter" || return $?
    declare -a prefixes="${possibleControlSampleNamePrefixes[@]}"
    matchPrefixInArray "$1" "${prefixes[@]}"
}

isTumorSample () {
    assertNonEmpty "$1" "isTumorSample expects sample type name as single parameter" || return $?
    declare -a prefixes="${possibleTumorSampleNamePrefixes[@]}"
    matchPrefixInArray "$1" "${prefixes[@]}"
}

sampleType () {
    assertNonEmpty "$1" "sampleType expects sample type name as single parameter" || return $?
    if isControlSample "$1" && isTumorSample "$1"; then
        throw_illegal_argument "Sample '$1' cannot be control and tumor at the same time"
    elif isControlSample "$1"; then
        echo "control"
    elif isTumorSample "$1"; then
        echo "tumor"
    else
        throw_illegal_argument "'$1' is neither control nor tumor"
    fi
}

runFingerprinting () {
    local bamFile="${1:?No input BAM file given}"
    local fingerPrintsFile="${2:?No output fingerprints file given}"
    if [[ "${runFingerprinting:-false}" == true && ${useAcceleratedHardware:-false} != true ]]; then
        "${PYTHON_BINARY}" "${TOOL_FINGERPRINT}" "${fingerprintingSitesFile}" "${bamFile}" > "${fingerPrintsFile}.tmp" || throw 43 "Fingerprinting failed"
        mv "${fingerPrintsFile}.tmp" "${fingerPrintsFile}" || throw 39 "Could not move file"
    fi
}


# Remove a single directory, owned by the current user, recursively. Certain file names are forbidden and it is checked
# that only a single file or directory (including contained files) will be removed.
saferRemoveSingleDirRecursively () {
    local file="${1:?No file given}"
    if [[ "${file}" == "" || "${file}" == "." || "${file}" == "/" || "${file}" == "*" ]]; then
        throw 1 "Trying to recursively remove with forbidden file name: '${file}'"
    fi
    declare -a owner=( $(stat -c "%U" "${file}") )
    if [[ "${#owner[@]}" -gt 1 ]]; then
        throw 1 "Trying to remove multiple files with file pattern: '${file}'"
    fi
    if [[ "${owner}" != $(whoami) ]]; then
        throw 1 "${file} is owned by ${owner}, so it won't be deleted by $(whoami)"
    fi
    rm -rf "${file}"
}

removeRoddyBigScratch () {
    if [[ "${RODDY_BIG_SCRATCH}" && "${RODDY_BIG_SCRATCH}" != "${RODDY_SCRATCH}" ]]; then  # $RODDY_SCRATCH is also deleted by the wrapper.
        saferRemoveSingleDirRecursively "${RODDY_BIG_SCRATCH}" # Clean-up big-file scratch directory. Only called if no error in wait or mv before.
    fi
}

checkBamIsComplete () {
    local bamFile="${1:?No BAM file given}"
    local result
    result=$("$TOOL_BAM_IS_COMPLETE" "$bamFile")
    if [[ $? ]]; then
        echo "BAM is terminated! $bamFile" >> /dev/stderr
    else
        throw 40 "BAM is not terminated! $bamFile"
    fi
}

checkBwaLog() {
    local bamFile="${1:?No BAM file given}"
    local bwaOutput="${2:?No BWA STDERR output file given}"
    local sortLog="${3:?No sort log given}"

    # disable file size checks if the interprocess streaming is active
    useMBufferStreaming=${useMBufferStreaming-false}
    if [[ $useMBufferStreaming != true ]]
    then

        if [[ "2048" -gt `stat -c %s $bamFile` ]]; then
            throw 33 "Output file is too small!"
        fi

        # TODO Check that?
        if [[ "$?" != "0"  ]]; then
            throw 32 "There was a non-zero exit code in bwa aln; exiting..."
        fi
    fi

    # Check for segfault messages
    success=`grep " fault" ${bwaOutput}`
    if [[ ! -z "$success" ]]; then
        throw 31 "found segfault $success in bwa logfile!"
    fi

    # Barbara Aug 10 2015: I can't remember what bwa aln and sampe reported as "error".
    # bluebee bwa has "error_count" in bwa-0.7.8-r2.05; and new in bwa-0.7.8-r2.06: "WARNING:top_bs_ke_be_hw: dummy be execution, only setting error."
    # these are not errors that would lead to fail, in contrast to "ERROR: Bus error"
    success=`grep -i "error" ${bwaOutput} | grep -v "error_count" | grep -v "dummy be execution"`
    if [[ ! -z "$success" ]]; then
        throw 36 "found error $success in bwa logfile!"
    fi

    # Check for BWA abortion.
    success=`grep "Abort. Sorry." ${bwaOutput}`
    if [[ ! -z "$success" ]]; then
        throw 37 "found error $success in bwa logfile!"
    fi

    # samtools sort may complain about truncated temp files and for each line outputs
    # the error message. This happens when the same files are written at the same time,
    # see http://sourceforge.net/p/samtools/mailman/samtools-help/thread/BAA90EF6FE3B4D45A7B2F6E0EC5A8366DA3AB5@USTLMLLYC102.rf.lilly.com/
    # This happens when the scheduler puts the same job on 2 nodes bc. the prefix for samtools-0.1.19 -o $prefix is constructed using the job ID
    if [ ! -z $sortLog ] && [ -f $sortLog ]; then
        success=`grep "is truncated. Continue anyway." $sortLog`
        if [[ ! -z "$success" ]]; then
            throw 38 "echo found error $success in samtools sorting logfile!"
        fi
    else
        echo "there is no samtools sort log file" >> /dev/stderr
    fi
    echo all OK
}


eval "$WORKFLOWLIB___SHELL_OPTIONS"
