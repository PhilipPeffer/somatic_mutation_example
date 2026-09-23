#!/usr/bin/env bash
# Stop spending money.
#     pixi run -e cloud teardown [--smoke]   terminate this run's instance(s)
#     pixi run -e cloud teardown --infra     also delete launch template, security
#                                            group, instance profile and IAM role
# The S3 bucket (your data and results) is never deleted by this script.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$@"
require_aws

INFRA=0
for a in "${ARGS[@]}"; do
  case "$a" in
    --infra) INFRA=1 ;;
    *) die "unknown option: $a" ;;
  esac
done

ids=$(run_instances)
if [[ -n "$ids" ]]; then
  log "Terminating ${ids}"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $ids >/dev/null
else
  log "No running instances for ${RUN_ID}"
fi

if (( INFRA )); then
  others=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=${PROJECT}" \
    "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [[ -n "$others" ]]; then
    log "Waiting for instances to terminate: ${others}"
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $others
  fi
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME" >/dev/null 2>&1 \
    && log "Deleted launch template ${LT_NAME}"
  for sg in $(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" \
                --query 'SecurityGroups[].GroupId' --output text); do
    aws ec2 delete-security-group --group-id "$sg" && log "Deleted security group ${sg}"
  done
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" 2>/dev/null \
    && log "Deleted instance profile ${PROFILE_NAME}"
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "${PROJECT}-bucket-access" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null && log "Deleted IAM role ${ROLE_NAME}"
  cat >&2 <<MSG
Infrastructure removed. Your data is still in s3://${BUCKET}. To delete it (irreversible):
  aws s3 rm --recursive s3://${BUCKET} && aws s3api delete-bucket --bucket ${BUCKET}
MSG
fi
