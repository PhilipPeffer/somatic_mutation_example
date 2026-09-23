#!/bin/bash
# EC2 user-data, rendered by aws/launch.sh (it fills in the double-underscore placeholders).
# Runs once as root at first boot:
#   1. hard runtime limit      2. NVMe instance store -> /scratch (RAID0)
#   3. code at the exact commit 4. pixi env from the lockfile
#   5. pipeline                 6. upload logs, power off (= terminate)
set -euo pipefail

BUCKET='__BUCKET__'
RUN_ID='__RUN_ID__'
CODE_KEY='__CODE_KEY__'
PIXI_VERSION='__PIXI_VERSION__'
MAX_RUNTIME_HOURS='__MAX_RUNTIME_HOURS__'
KEEP_INSTANCE_ON_FAILURE='__KEEP_INSTANCE_ON_FAILURE__'
OVERRIDES_B64='__OVERRIDES_B64__'
export AWS_REGION='__AWS_REGION__'
export AWS_DEFAULT_REGION=$AWS_REGION HOME=/root

LOG=/var/log/pipeline-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
RUN_S3=s3://$BUCKET/runs/$RUN_ID
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
IID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
echo "bootstrap: run=${RUN_ID} instance=${IID} code=${CODE_KEY}"

finish() {
  local rc=$?
  echo "bootstrap: exit code ${rc}"
  aws s3 cp --only-show-errors "$LOG" "$RUN_S3/logs/bootstrap.${IID}.log" || true
  if [[ $rc -ne 0 && "$KEEP_INSTANCE_ON_FAILURE" == 1 ]]; then
    echo "bootstrap: KEEP_INSTANCE_ON_FAILURE=1, leaving instance up (runtime limit still applies)"
    return
  fi
  shutdown -h now   # launch template sets shutdown behaviour = terminate
}
trap finish EXIT

# 1. Safety net: never bill for more than MAX_RUNTIME_HOURS, whatever happens.
systemd-run --on-active="${MAX_RUNTIME_HOURS}h" --unit=max-runtime /usr/sbin/shutdown -h now

# 2. Scratch space on the local NVMe instance store (fast, and included in the price).
dnf install -y -q mdadm
mapfile -t DEVS < <(lsblk -dpno NAME,MODEL | awk '/Instance Storage/ {print $1}')
mkdir -p /scratch
if (( ${#DEVS[@]} == 0 )); then
  echo "bootstrap: WARNING no instance store found; using the root volume for /scratch"
else
  DEV=${DEVS[0]}
  if (( ${#DEVS[@]} > 1 )); then
    mdadm --create /dev/md0 --run --level=0 --raid-devices=${#DEVS[@]} "${DEVS[@]}"
    DEV=/dev/md0
  fi
  mkfs.xfs -f -q "$DEV"
  mount -o noatime "$DEV" /scratch
fi
df -h /scratch

# 3. Pipeline code, exactly as packaged by launch.sh (git archive of one commit).
mkdir -p /scratch/code
aws s3 cp --only-show-errors "s3://$BUCKET/$CODE_KEY" - | tar -xz -C /scratch/code
echo "$OVERRIDES_B64" | base64 -d > /scratch/code/config/overrides.env

# 4. Tool environment from the committed lockfile.
curl -fsSL --retry 5 -o /usr/local/bin/pixi \
  "https://github.com/prefix-dev/pixi/releases/download/${PIXI_VERSION}/pixi-x86_64-unknown-linux-musl"
chmod +x /usr/local/bin/pixi
export PIXI_CACHE_DIR=/scratch/pixi-cache
cd /scratch/code
pixi install -e pipeline --frozen

# 5. Run. Resumes from S3 checkpoints if this RUN_ID ran before.
pixi run -e pipeline --frozen bash pipeline/run_pipeline.sh
