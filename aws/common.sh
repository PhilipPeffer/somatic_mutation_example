#!/usr/bin/env bash
# Shared setup for the Codespace-side scripts in aws/. Sourced, not executed.
# Loads config/pipeline.env and handles the common flags:
#   --smoke   operate on the smoke-test run (RUN_ID + "_smoke", small instance)

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${CONFIG:-$REPO_DIR/config/pipeline.env}
# shellcheck source=../config/pipeline.env
source "$CONFIG"

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

SMOKE=0
ARGS=()
for _a in "$@"; do
  case "$_a" in
    --smoke) SMOKE=1 ;;
    *) ARGS+=("$_a") ;;
  esac
done
unset _a

if (( SMOKE )); then
  RUN_ID=${RUN_ID}_smoke
  INSTANCE_TYPES=${SMOKE_INSTANCE_TYPES:-$INSTANCE_TYPES}
fi

export AWS_REGION AWS_DEFAULT_REGION=$AWS_REGION
RUN_S3=s3://$BUCKET/runs/$RUN_ID

ROLE_NAME=${PROJECT}-node-role
PROFILE_NAME=${PROJECT}-node-profile
SG_NAME=${PROJECT}-node-sg
LT_NAME=${PROJECT}-node

require_aws() {
  [[ "$BUCKET" != CHANGE-ME* ]] || die "edit BUCKET in config/pipeline.env first"
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "no valid AWS credentials (see docs/WALKTHROUGH.md, step 2)"
}

# Instances belonging to this run that are pending/running.
run_instances() {
  aws ec2 describe-instances \
    --filters "Name=tag:RunId,Values=${RUN_ID}" "Name=tag:Project,Values=${PROJECT}" \
              "Name=instance-state-name,Values=pending,running,stopping" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}
