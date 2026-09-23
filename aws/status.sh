#!/usr/bin/env bash
# Show the state of a run: its instance(s), completed steps, and the log tail.
#     pixi run -e cloud status [--smoke]

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$@"
require_aws

echo "== Run ${RUN_ID}  (${RUN_S3})"
echo
echo "== Instances"
aws ec2 describe-instances \
  --filters "Name=tag:RunId,Values=${RUN_ID}" "Name=tag:Project,Values=${PROJECT}" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle,State.Name,LaunchTime,StateReason.Message]' \
  --output table || true
echo
echo "== Completed steps (checkpoints)"
aws s3 ls "${RUN_S3}/checkpoints/" 2>/dev/null | awk '{print "  " $1, $2, $4}' || echo "  none yet"
echo
echo "== Step timings (seconds)"
aws s3 cp "${RUN_S3}/logs/step_timings.tsv" - 2>/dev/null | column -t | sed 's/^/  /' || echo "  none yet"
echo
echo "== Last log lines (log is synced to S3 every ~2 min)"
aws s3 cp "${RUN_S3}/logs/pipeline.log" - 2>/dev/null | tail -n 15 \
  || echo "  no pipeline log yet (instance bootstrapping takes ~5 min); see bootstrap logs in ${RUN_S3}/logs/"
