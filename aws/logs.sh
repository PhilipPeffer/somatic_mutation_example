#!/usr/bin/env bash
# Print the pipeline log from S3 (synced from the instance every ~2 minutes).
#     pixi run -e cloud logs [--smoke] [N lines, default 100 | all] [--bootstrap]
#
# For a live view, open a shell on the instance with SSM and tail the log:
#     aws ssm start-session --target <instance-id>
#     sudo tail -f /scratch/runs/<RUN_ID>/logs/pipeline.log

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$@"
require_aws

N=100 BOOT=0
for a in "${ARGS[@]}"; do
  case "$a" in
    --bootstrap) BOOT=1 ;;
    all|[0-9]*) N=$a ;;
    *) die "unknown option: $a" ;;
  esac
done

if (( BOOT )); then
  for key in $(aws s3 ls "${RUN_S3}/logs/" | awk '/bootstrap\./ {print $4}'); do
    echo "===== ${key}"
    aws s3 cp "${RUN_S3}/logs/${key}" - | { if [[ $N == all ]]; then cat; else tail -n "$N"; fi; }
  done
  exit 0
fi

aws s3 cp "${RUN_S3}/logs/pipeline.log" - | { if [[ $N == all ]]; then cat; else tail -n "$N"; fi; }
