#!/usr/bin/env bash
# Step 3: pre-alignment QC and read trimming, per read group.
# Runs inside the align step (step 4), on the local FASTQ just before alignment,
# so it adds no extra checkpoints or S3 copies of the reads.
#
# Trim Galore (TRIM_READS=1, default; see docs/WALKTHROUGH.md step 13)
#   Adapter trimming (adapter auto-detected) plus 3' quality trimming (-q 20).
#   Pairs where a mate ends up shorter than --length are dropped. Adapter
#   remnants soft-clipped at read ends can look like low-VAF somatic variants
#   to a sensitive caller; trimming removes them before alignment. SEQC2 also
#   trimmed adapters and low-quality bases (with Trimmomatic) before aligning.
#   Options: TRIM_ARGS (default "--length 36"). Reports go to metrics/trimming/.
#
# FastQC (RUN_FASTQC=1, default)
#   On the raw reads and, when trimming, on the trimmed reads too, so the
#   report shows adapter content and quality before and after. Both FastQC
#   jobs run in the background while the reads are aligned, so they add
#   little wall time. Reports go to metrics/fastqc/.
#
# Both tools name their reports after the input file, so the FASTQs are first
# linked as <rg>_R1/<rg>_R2 (trimmed: <rg>_val_1/<rg>_val_2); this keeps read
# groups apart in the MultiQC report.

FASTQC_PIDS=()

name_fastq_for_reports() {  # name_fastq_for_reports <rg> <dir>
  ln -sf R1.fastq.gz "$2/${1}_R1.fastq.gz"
  ln -sf R2.fastq.gz "$2/${1}_R2.fastq.gz"
}

fastqc_start() {  # fastqc_start <label> <fastq1> <fastq2> : FastQC in the background
  [[ "${RUN_FASTQC:-1}" == 1 ]] || return 0
  mkdir -p "$WORK/metrics/fastqc"
  fastqc --threads 2 --quiet --outdir "$WORK/metrics/fastqc" "$2" "$3" \
    > "$WORK/logs/fastqc_${1}.log" 2>&1 &
  FASTQC_PIDS+=("$!")
  log "FastQC started in the background for ${1}"
}

fastqc_finish() {  # fastqc_finish <rg> : wait for this read group's FastQC jobs, upload reports
  local pid f
  for pid in "${FASTQC_PIDS[@]}"; do
    wait "$pid" || die "FastQC failed for ${1} (see logs/fastqc_${1}_*.log)"
  done
  FASTQC_PIDS=()
  for f in "$WORK/metrics/fastqc/${1}"_*_fastqc.*; do
    if [[ -e "$f" ]]; then put "metrics/fastqc/$(basename "$f")"; fi
  done
  log "FastQC finished for ${1}"
}

# trim_reads <rg> <dir> : prints "<R1> <R2>" of the trimmed reads
trim_reads() {
  local rg=$1 dir=$2 out=$2/trimmed rep=$WORK/metrics/trimming
  mkdir -p "$out" "$rep"
  # shellcheck disable=SC2086  # TRIM_ARGS is intentionally word-split
  trim_galore --paired --cores "$NT" --basename "$rg" --output_dir "$out" ${TRIM_ARGS:-} \
    "$dir/${rg}_R1.fastq.gz" "$dir/${rg}_R2.fastq.gz" >&2
  local f
  for f in "$out"/*_trimming_report.*; do
    if [[ -e "$f" ]]; then mv "$f" "$rep/" && put "metrics/trimming/$(basename "$f")"; fi
  done
  echo "$out/${rg}_val_1.fq.gz $out/${rg}_val_2.fq.gz"
}
