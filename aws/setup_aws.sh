#!/usr/bin/env bash
# One-time (idempotent) AWS setup, run from the Codespace:
#     pixi run -e cloud aws-setup
#
# Creates:
#   * S3 bucket          private, encrypted; lifecycle rules clean up intermediates
#   * IAM role/profile   instance may only touch this bucket (+ SSM Session Manager)
#   * Security group     no inbound rules at all (access is via SSM, not SSH)
#   * Launch template    Amazon Linux 2023, IMDSv2 only, terminate on shutdown
# Re-running is safe; it updates what already exists.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$@"
require_aws
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "Account ${ACCOUNT_ID}, region ${AWS_REGION}, bucket ${BUCKET}"

# --- S3 bucket --------------------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  log "Bucket exists: ${BUCKET}"
else
  log "Creating bucket ${BUCKET}"
  if [[ "$AWS_REGION" == us-east-1 ]]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
fi
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [
    {"ID": "expire-intermediate-bams", "Status": "Enabled",
     "Filter": {"Prefix": "intermediate/"}, "Expiration": {"Days": 14}},
    {"ID": "abort-incomplete-uploads", "Status": "Enabled",
     "Filter": {"Prefix": ""}, "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 3}}
  ]}'

# --- IAM role + instance profile --------------------------------------------
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "Creating IAM role ${ROLE_NAME}"
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${REPO_DIR}/aws/iam/trust-policy.json" \
    --tags "Key=Project,Value=${PROJECT}" >/dev/null
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "${PROJECT}-bucket-access" \
  --policy-document "$(sed "s/__BUCKET__/${BUCKET}/g" "$REPO_DIR/aws/iam/node-policy.json.tpl")"
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  log "Creating instance profile ${PROFILE_NAME}"
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  sleep 15   # IAM is eventually consistent; the launch template needs the profile
fi

# Service-linked roles EC2 needs for spot/fleet (no-op if they already exist).
for svc in spot.amazonaws.com ec2fleet.amazonaws.com; do
  aws iam create-service-linked-role --aws-service-name "$svc" >/dev/null 2>&1 || true
done

# --- Security group (egress only) -------------------------------------------
if [[ -n "$SUBNET_IDS" ]]; then
  VPC_ID=$(aws ec2 describe-subnets --subnet-ids "${SUBNET_IDS%% *}" --query 'Subnets[0].VpcId' --output text)
else
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  [[ "$VPC_ID" != None ]] || die "no default VPC in ${AWS_REGION}; set SUBNET_IDS in config/pipeline.env"
fi
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SG_ID" == None ]]; then
  log "Creating security group ${SG_NAME} in ${VPC_ID}"
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
    --description "Sentieon WGS pipeline nodes: no inbound access, egress only" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${PROJECT}}]" \
    --query GroupId --output text)
fi

# --- Launch template ----------------------------------------------------------
# The AMI is resolved now and pinned in the template (and recorded in each run's
# manifest), so re-running setup is the only thing that changes the OS image.
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
LT_DATA=$(jq -n --arg ami "$AMI_ID" --arg sg "$SG_ID" --arg profile "$PROFILE_NAME" \
  --arg project "$PROJECT" --argjson root "$ROOT_VOLUME_GB" '{
  ImageId: $ami,
  IamInstanceProfile: {Name: $profile},
  SecurityGroupIds: [$sg],
  InstanceInitiatedShutdownBehavior: "terminate",
  MetadataOptions: {HttpTokens: "required", HttpEndpoint: "enabled", HttpPutResponseHopLimit: 2},
  BlockDeviceMappings: [{DeviceName: "/dev/xvda",
    Ebs: {VolumeSize: $root, VolumeType: "gp3", DeleteOnTermination: true, Encrypted: true}}],
  TagSpecifications: [{ResourceType: "volume", Tags: [{Key: "Project", Value: $project}]}]
}')
if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" >/dev/null 2>&1; then
  V=$(aws ec2 create-launch-template-version --launch-template-name "$LT_NAME" \
    --version-description "setup ${AMI_ID}" --launch-template-data "$LT_DATA" \
    --query LaunchTemplateVersion.VersionNumber --output text)
  aws ec2 modify-launch-template --launch-template-name "$LT_NAME" --default-version "$V" >/dev/null
  log "Launch template ${LT_NAME} updated (version ${V}, ${AMI_ID})"
else
  aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
    --version-description "setup ${AMI_ID}" --launch-template-data "$LT_DATA" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Project,Value=${PROJECT}}]" >/dev/null
  log "Launch template ${LT_NAME} created (${AMI_ID})"
fi

# --- Spot vCPU quota ----------------------------------------------------------
# New accounts often start with a low limit; one 16xlarge needs 64 vCPUs.
QUOTA=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-34B43A08 \
  --query Quota.Value --output text 2>/dev/null || echo unknown)
log "Spot vCPU quota (All Standard Spot Instance Requests): ${QUOTA}"
if [[ "$QUOTA" != unknown ]] && (( ${QUOTA%.*} < 64 )); then
  log "WARNING: quota < 64 vCPUs. Request an increase (docs/WALKTHROUGH.md, step 4):"
  log "  aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-34B43A08 --desired-value 128"
fi

cat >&2 <<MSG

Setup complete.
  bucket            s3://${BUCKET}
  instance profile  ${PROFILE_NAME}
  security group    ${SG_ID} (${VPC_ID})
  launch template   ${LT_NAME}

Next: upload your Sentieon license (docs/WALKTHROUGH.md, step 5), e.g.
  aws s3 cp /path/to/your.lic ${SENTIEON_LICENSE_S3:-s3://${BUCKET}/license/sentieon.lic}
MSG
