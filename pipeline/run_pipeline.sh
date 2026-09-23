#!/usr/bin/env bash
# Tumor-normal WGS, FASTQ -> somatic VCF, with Sentieon. No orchestrator:
# this script runs every step in order on one machine and checkpoints each
# step to S3 so a replacement spot instance can pick up where the last stopped.
#
# Normally started by aws/user_data.sh.tpl on the EC2 instance:
#     pixi run -e pipeline --frozen bash pipeline/run_pipeline.sh
# To print the full command sequence locally without running anything:
#     pixi run -e cloud dry-run
#
# Step order (details and exact commands in pipeline/steps/*.sh):
#   0  install Sentieon + license check          (per instance)
#   1  reference bundle (GRCh38)                 (once per bucket, cached in S3)
#   2  SRA -> paired FASTQ.gz                    (once per read group, cached in S3)
#   3  Trim Galore + FastQC, per read group             } one checkpoint
#   4  bwa mem + sort, per read group                    } per read group
#   5  QC metrics + duplicate marking, per sample
#   6  base quality score recalibration + coverage metrics, per sample
#   7  somatic calling + filtering (TNhaplotyper2 by default)
#   8  QC report + run manifest

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${CONFIG:-$REPO_DIR/config/pipeline.env}

# Export everything in the config so tools (e.g. SENTIEON_* variables) see it.
set -a
# shellcheck source=../config/pipeline.env
source "$CONFIG"
# Per-launch overrides written by aws/launch.sh (e.g. --smoke); recorded with the run.
OVERRIDES=${OVERRIDES:-$REPO_DIR/config/overrides.env}
if [[ -s "$OVERRIDES" ]]; then
  # shellcheck source=/dev/null
  source "$OVERRIDES"
fi
set +a

# shellcheck source=lib.sh
source "$REPO_DIR/pipeline/lib.sh"
for f in "$REPO_DIR"/pipeline/steps/*.sh; do
  # shellcheck source=/dev/null
  source "$f"
done

# ---------------------------------------------------------------------------
# Settings and paths
# ---------------------------------------------------------------------------
: "${BUCKET:?set BUCKET in config/pipeline.env}"
: "${RUN_ID:?set RUN_ID in config/pipeline.env}"
GENOME=${GENOME:-hg38}
CALLER=${CALLER:-tnhaplotyper2}
SUBSAMPLE_READS=${SUBSAMPLE_READS:-0}
CALL_INTERVALS=${CALL_INTERVALS:-}
SAMPLES_TSV=$REPO_DIR/${SAMPLES_TSV:-config/samples.tsv}

if is_dry_run; then
  SCRATCH=${SCRATCH:-$REPO_DIR/.dryrun}
else
  SCRATCH=${SCRATCH:-/scratch}
fi
NT=${THREADS:-$(nproc)}

REF_S3=s3://$BUCKET/references/$GENOME
REF_DIR=$SCRATCH/ref/$GENOME
FASTQ_S3=s3://$BUCKET/fastq
FASTQ_DIR=$SCRATCH/fastq
RUN_S3=s3://$BUCKET/runs/$RUN_ID
INTER_S3=s3://$BUCKET/intermediate/$RUN_ID   # expired by an S3 lifecycle rule
WORK=$SCRATCH/runs/$RUN_ID

GIT_SHA=$(cat "$REPO_DIR/GIT_SHA" 2>/dev/null || git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
INSTANCE_TYPE=$(imds meta-data/instance-type || echo unknown)
export GIT_SHA INSTANCE_TYPE

mkdir -p "$WORK"/{logs,checkpoints,intermediate,bam,metrics,vcf,report} "$REF_DIR" "$FASTQ_DIR"
PIPELINE_LOG=$WORK/logs/pipeline.log
# On a relaunch after a spot interruption, continue the previous log/timings.
if ! is_dry_run; then
  s3_cp "$RUN_S3/logs/pipeline.log" "$PIPELINE_LOG" 2>/dev/null || true
  s3_cp "$RUN_S3/logs/step_timings.tsv" "$WORK/logs/step_timings.tsv" 2>/dev/null || true
fi
touch "$WORK/logs/step_timings.tsv"
exec > >(tee -a "$PIPELINE_LOG") 2>&1
STARTED_UTC=$(date -u +%FT%TZ)

log "run=${RUN_ID} git=${GIT_SHA} instance=${INSTANCE_TYPE} threads=${NT} scratch=${SCRATCH}"
log "caller=${CALLER} subsample_reads=${SUBSAMPLE_READS} call_intervals=${CALL_INTERVALS:-<whole genome>}"
log "fastqc=${RUN_FASTQC:-1} trim_reads=${TRIM_READS:-1} trim_args=${TRIM_ARGS:-<none>}"
is_dry_run && log "DRY RUN: external commands are printed, not executed"

load_samples "$SAMPLES_TSV"
log "tumor=${TUMOR} normal=${NORMAL} read_groups=${READ_GROUPS[*]}"

start_background_monitors
on_exit() {
  local rc=$?
  [[ -n "${MONITOR_PID:-}" ]] && kill "$MONITOR_PID" 2>/dev/null
  if (( rc == 0 )); then log "PIPELINE FINISHED OK"; else log "PIPELINE FAILED (exit ${rc})"; fi
  s3_cp "$PIPELINE_LOG" "$RUN_S3/logs/pipeline.log" || true
  [[ -f "$WORK/logs/step_timings.tsv" ]] && { s3_cp "$WORK/logs/step_timings.tsv" "$RUN_S3/logs/step_timings.tsv" || true; }
}
trap on_exit EXIT

# Record the exact configuration used next to the results.
s3_cp "$CONFIG" "$RUN_S3/config/pipeline.env"
s3_cp "$SAMPLES_TSV" "$RUN_S3/config/samples.tsv"
[[ -s "$OVERRIDES" ]] && s3_cp "$OVERRIDES" "$RUN_S3/config/overrides.env"

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
install_sentieon                                                   # 0

step_at "$REF_S3/_READY" "reference_${GENOME}" prepare_reference   # 1
fetch_reference

for rg in "${READ_GROUPS[@]}"; do                                   # 2, 3 + 4
  # Skip FASTQ preparation entirely once the read group is aligned.
  if ! s3_exists "$RUN_S3/checkpoints/align_${rg}.done" && [[ "${RG_SOURCE[$rg]}" == sra:* ]]; then
    step_at "$(fastq_s3_prefix "$rg")/_READY" "fastq_${rg}" prepare_fastq_from_sra "$rg"
  fi
  step "align_${rg}" align_read_group "$rg"                          # (QC/trim inside)
done

for sm in "$TUMOR" "$NORMAL"; do                                    # 5 + 6
  step "dedup_${sm}" metrics_and_dedup "$sm"
  step "bqsr_${sm}"  bqsr_and_coverage "$sm"
done

step "call_${CALLER}" call_somatic                                  # 7
step "report" make_report                                           # 8

log "Results: ${RUN_S3}/vcf/  (fetch with: pixi run -e cloud fetch-results)"
