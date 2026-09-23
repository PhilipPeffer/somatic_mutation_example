#!/usr/bin/env bash
# Download a run's results (VCFs, metrics, report, logs, config) to results/<RUN_ID>/.
# BAMs are left in S3 unless --bams is given (they are ~100+ GB).
#     pixi run -e cloud fetch-results [--smoke] [--bams]

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$@"
require_aws

EXCLUDE=(--exclude "bam/*.bam" --exclude "bam/*.bai")
for a in "${ARGS[@]}"; do
  case "$a" in
    --bams) EXCLUDE=() ;;
    *) die "unknown option: $a" ;;
  esac
done

DEST=$REPO_DIR/results/$RUN_ID
mkdir -p "$DEST"
aws s3 sync --only-show-errors "${EXCLUDE[@]}" "$RUN_S3/" "$DEST/"
log "Results in ${DEST#"$REPO_DIR"/}:"
find "$DEST" -maxdepth 2 -type f \( -name '*.vcf.gz' -o -name '*.html' -o -name 'run_manifest.json' \) \
  | sed "s|$REPO_DIR/|  |"
