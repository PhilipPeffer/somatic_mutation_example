#!/usr/bin/env bash
# Step 2: obtain paired FASTQ for each read group.
#
# Source column of config/samples.tsv:
#   sra:<RUN>             download the .sra file from the AWS Open Data mirror
#                         (s3://sra-pub-run-odp, us-east-1, no egress charge),
#                         convert with fasterq-dump, gzip, and cache the FASTQ in
#                         s3://$BUCKET/fastq/<rg>/ (reused by later runs/relaunches)
#   s3://R1.fq.gz,s3://R2.fq.gz   your own FASTQ already in S3 (nothing to cache)
#
# SUBSAMPLE_READS=N (>0) keeps only the first N read pairs: a cheap smoke test.

fastq_s3_prefix() {  # cache location for a read group's FASTQ
  if (( SUBSAMPLE_READS > 0 )); then
    echo "$FASTQ_S3/$1/subsample_${SUBSAMPLE_READS}"
  else
    echo "$FASTQ_S3/$1/full"
  fi
}

fastq_local_dir() { echo "$FASTQ_DIR/$1/$(basename "$(fastq_s3_prefix "$1")")"; }

prepare_fastq_from_sra() {
  local rg=$1 acc=${RG_SOURCE[$1]#sra:}
  local out tmp
  out=$(fastq_local_dir "$rg")
  tmp=$SCRATCH/tmp/sra_$acc
  mkdir -p "$out" "$tmp/$acc"

  log "Fetching ${acc}.sra from the AWS Open Data SRA mirror"
  aws s3 cp --only-show-errors --no-sign-request \
    "s3://sra-pub-run-odp/sra/$acc/$acc" "$tmp/$acc/$acc"

  if (( SUBSAMPLE_READS > 0 )); then
    fastq-dump -X "$SUBSAMPLE_READS" --split-3 --gzip --outdir "$out" "$tmp/$acc/$acc"
  else
    # --split-3: mates to _1/_2; orphan reads (if any) go to a separate file we drop.
    fasterq-dump --split-3 --threads "$NT" --temp "$tmp" --outdir "$out" "$tmp/$acc/$acc"
    rm -rf "$tmp"   # free space before compressing
    pigz -p "$NT" "$out/${acc}_1.fastq" "$out/${acc}_2.fastq"
  fi
  rm -rf "$tmp"

  if [[ -e "$out/${acc}.fastq" || -e "$out/${acc}.fastq.gz" ]]; then
    warn "${acc}: unpaired reads found and discarded"
    rm -f "$out/${acc}.fastq" "$out/${acc}.fastq.gz"
  fi
  if ! is_dry_run; then
    [[ -s "$out/${acc}_1.fastq.gz" && -s "$out/${acc}_2.fastq.gz" ]] \
      || die "${acc}: expected paired-end reads (_1/_2 files) from fasterq-dump"
    mv "$out/${acc}_1.fastq.gz" "$out/R1.fastq.gz"
    mv "$out/${acc}_2.fastq.gz" "$out/R2.fastq.gz"
  fi
  (cd "$out" && md5sum R1.fastq.gz R2.fastq.gz > md5sums.txt)

  aws s3 sync --only-show-errors "$out/" "$(fastq_s3_prefix "$rg")/"
}

# ensure_fastq <rg> : make R1/R2 available locally; prints the directory
ensure_fastq() {
  local rg=$1 src=${RG_SOURCE[$1]} dir
  dir=$(fastq_local_dir "$rg")
  mkdir -p "$dir"
  if [[ -s "$dir/R1.fastq.gz" && -s "$dir/R2.fastq.gz" ]]; then
    echo "$dir"; return 0
  fi
  case "$src" in
    sra:*)
      aws s3 sync --only-show-errors "$(fastq_s3_prefix "$rg")/" "$dir/" >&2
      (cd "$dir" && md5sum -c --quiet md5sums.txt) >&2 || die "FASTQ checksum mismatch for $rg"
      ;;
    s3://*,s3://*)
      local r1=${src%%,*} r2=${src#*,}
      if (( SUBSAMPLE_READS > 0 )); then
        local n=$(( SUBSAMPLE_READS * 4 ))
        # head closes the pipe early by design; ignore the resulting SIGPIPE.
        (set +o pipefail; aws s3 cp "$r1" - | pigz -dc | head -n "$n" | pigz > "$dir/R1.fastq.gz")
        (set +o pipefail; aws s3 cp "$r2" - | pigz -dc | head -n "$n" | pigz > "$dir/R2.fastq.gz")
      else
        s3_cp "$r1" "$dir/R1.fastq.gz" >&2
        s3_cp "$r2" "$dir/R2.fastq.gz" >&2
      fi
      ;;
    *) die "unsupported source '$src' for read group $rg (use sra:<RUN> or s3://R1,s3://R2)" ;;
  esac
  echo "$dir"
}
