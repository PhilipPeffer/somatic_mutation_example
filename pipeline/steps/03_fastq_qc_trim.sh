#!/usr/bin/env bash
# Step 3: pre-alignment QC and optional read trimming, per read group.
# Runs inside the align step (step 4), on the local FASTQ just before alignment,
# so it adds no extra checkpoints or S3 copies of the reads.
#
# FastQC (RUN_FASTQC=1, default)
#   Raw-read QC: per-base quality, adapter content, GC, overrepresented
#   sequences. It runs in the background while the reads are aligned (one
#   thread per file), so it adds little wall time. Reports go to
#   metrics/fastqc/ and into the MultiQC report.
#
# Trim Galore (TRIM_READS=1, default off; see docs/WALKTHROUGH.md step 13)
#   Adapter trimming, auto-detected, plus 3' quality trimming (-q 20). Pairs
#   where a mate becomes shorter than --length are dropped. Extra options go
#   in TRIM_ARGS, e.g. "--length 36" or "--fastqc" for post-trim FastQC.
#   Trimming reports go to metrics/trimming/ and into MultiQC.
#
# Both tools name their reports after the input file, so the FASTQs are first
# linked as <rg>_R1/<rg>_R2; this keeps read groups apart in MultiQC.

name_fastq_for_reports() {  # name_fastq_for_reports <rg> <dir>
  ln -sf R1.fastq.gz "$2/${1}_R1.fastq.gz"
  ln -sf R2.fastq.gz "$2/${1}_R2.fastq.gz"
}

fastqc_start() {  # fastqc_start <rg> <dir> : background FastQC; sets FASTQC_PID
  FASTQC_PID=""
  [[ "${RUN_FASTQC:-1}" == 1 ]] || return 0
  mkdir -p "$WORK/metrics/fastqc"
  fastqc --threads 2 --quiet --outdir "$WORK/metrics/fastqc" \
    "$2/${1}_R1.fastq.gz" "$2/${1}_R2.fastq.gz" > "$WORK/logs/fastqc_${1}.log" 2>&1 &
  FASTQC_PID=$!
  log "FastQC started in the background for ${1}"
}

fastqc_finish() {  # fastqc_finish <rg> : wait for FastQC and upload its reports
  [[ -n "${FASTQC_PID:-}" ]] || return 0
  wait "$FASTQC_PID" || die "FastQC failed for ${1} (see logs/fastqc_${1}.log)"
  local r f
  for r in R1 R2; do
    for f in "${1}_${r}_fastqc.zip" "${1}_${r}_fastqc.html"; do
      if [[ -e "$WORK/metrics/fastqc/$f" ]]; then put "metrics/fastqc/$f"; fi
    done
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
  for f in "$out"/*_trimming_report.* "$out"/*_fastqc.*; do
    if [[ -e "$f" ]]; then mv "$f" "$rep/" && put "metrics/trimming/$(basename "$f")"; fi
  done
  echo "$out/${rg}_val_1.fq.gz $out/${rg}_val_2.fq.gz"
}
