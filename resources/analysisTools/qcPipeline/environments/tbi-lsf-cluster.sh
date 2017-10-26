#!/usr/bin/env bash

set -xv

# Load/Unload a module with $name and using the version given by the $versionVariable.
# If the version is not given, take the name, put it into upper case and append _VERSION.
versionVariable () {
    local name="${1:?No binary name given}"
    local versionVariable="${2:-}"
    if [[ -z "$versionVariable" ]]; then
        local ucVersionVariable
        ucVersionVariable=$(echo "$name" | tr '[a-z]' '[A-Z]')
        echo "${ucVersionVariable}_VERSION"
    else
        echo "$versionVariable"
    fi
}
export -f versionVariable

moduleLoad() {
    local name="${1:?No module name given}"
    local versionVariable="${2:-}"
    versionVariable=$(versionVariable "$name" "$versionVariable")
    if [[ -z "${!versionVariable}" ]]; then
        throw 200 "$versionVariable is not set"
    fi
    module load "${name}/${!versionVariable}" || throw 200 "Could not load '${name}/${!versionVariable}'"
}
export -f moduleLoad

moduleUnload() {
    local name="${1:?No module name given}"
    local versionVariable="${2:-}"
    local versionVariable=$(versionVariable "$name" "$versionVariable")
    if [[ -z "${!versionVariable}" ]]; then
        throw 200 "versionVariable for $name is not set"
    fi
    module unload "${name}/${!versionVariable}" || throw 200 "Could not unload '${name}/${!versionVariable}'"
}
export -f moduleUnload

moduleLoad htslib
export BGZIP_BINARY=bgzip
export TABIX_BINARY=tabix

moduleLoad R
export RSCRIPT_BINARY=Rscript

moduleLoad java
export JAVA_BINARY=java

moduleLoad fastqc
export FASTQC_BINARY=fastqc

moduleLoad perl
export PERL_BINARY=perl

moduleLoad python
export PYTHON_BINARY=python

moduleLoad pypy
export PYPY_BINARY=pypy-c

moduleLoad samtools
export SAMTOOLS_BINARY=samtools
export BCFTOOLS_BINARY=bcftools

moduleLoad bedtools
export INTERSECTBED_BINARY=intersectBed
export COVERAGEBED_BINARY=coverageBed
export FASTAFROMBED_BINARY=fastaFromBed

moduleLoad libmaus
moduleLoad biobambam
export BAMSORT_BINARY=bamsort
export BAMMARKDUPLICATES_BINARY=bammarkduplicates

moduleLoad picard
export PICARD_BINARY=picard.sh

moduleLoad vcftools
export VCFTOOLS_SORT_BINARY=vcf-sort

# There are different sambamba versions used for different tasks. The reason has something to do with performance and differences in the versions.
# We define functions here that take the same parameters as the original sambamba, but apply them to the appropriate version by first loading
# the correct version and after the call unloading the version. The _BINARY variables are set to the functions.

# The sambamba version used for sorting, viewing. Note that v0.5.9 is segfaulting on Convey during view or sort.
sambamba_sort_view() {
    moduleLoad sambamba
    sambamba "$@"
    moduleUnload sambamba
}
export -f sambamba_sort_view
export SAMBAMBA_BINARY=sambamba

# The sambamba version used only for flagstats. For the flagstats sambamba 0.4.6 used is equivalent to samtools 0.1.19 flagstats. Newer versions
# use the new way of counting in samtools (accounting for supplementary reads).
# Warning: Currently bwaMemSortSlim uses sambamba flagstats, while mergeAndMarkOrRemoveSlim uses samtools flagstats.
sambamba_flagstat() {
    moduleLoad sambamba SAMBAMBA_FLAGSTATS_VERSION
    sambamba "$@"
    moduleUnload sambamba SAMBAMBA_FLAGSTATS_VERSION
}
export -f sambamba_flagstat
export SAMBAMBA_FLAGSTATS_BINARY=sambamba_flagstat

# The sambamba version used only for duplication marking and merging. Use the bash function here!
# Should be changeable independently also for performance and stability reasons.
sambamba_markdup() {
    moduleLoad sambamba SAMBAMBA_MARKDUP_VERSION
    sambamba "$@"
    moduleUnload sambamba SAMBAMBA_MARKDUP_VERSION
}
export -f sambamba_markdup
export SAMBAMBA_MARKDUP_BINARY=sambamba_markdup


if [[ "$WORKFLOW_ID" == "bisulfiteCoreAnalysis" ]]; then
    ## For bisulfite alignment, we suffix the the value of BINARY_VERSION by '-bisulfite', because that's the name in LSF cluster.
    export BWA_VERSION="${BWA_VERSION:?BWA_VERSION is not set}-bisulfite"
    moduleLoad bwa
    export BWA_BINARY=bwa

elif [[ "$WORKFLOW_ID" == "qcAnalysis" || "$WORKFLOW_ID" == "exomeAnalysis" ]]; then
    if [[ "${useAcceleratedHardware:-false}" == false ]]; then
        moduleLoad bwa
        export BWA_BINARY=bwa
    elif [[ "${useAcceleratedHardware:-true}" == true ]]; then
        moduleLoad bwa-bb BWA_VERSION
        export BWA_ACCELERATED_BINARY=bwa-bb
    else
        throw 200 "Uninterpretable value for boolean 'useAcceleratedHardware': '$useAcceleratedHardware'"
    fi
else
    throw 200 "Unknown workflow ID '$WORKFLOW_ID'"
fi

# Unversioned binaries.
export MBUFFER_BINARY=mbuffer
export CHECKSUM_BINARY=md5sum
