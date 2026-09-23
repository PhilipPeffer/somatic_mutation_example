#!/usr/bin/env bash
# Shared helpers for the tumor-normal WGS pipeline. Sourced by run_pipeline.sh.
#
# Conventions
#   * Local working copy of a run lives in $WORK and mirrors $RUN_S3 (same
#     relative paths), so `put <rel>` / `need <rel>` move files between them.
#   * Every step is wrapped in `step`/`step_at`: it is skipped when its S3
#     checkpoint marker exists, which is what makes a spot interruption
#     resumable by simply launching a new instance with the same RUN_ID.
#   * DRY_RUN=1 replaces every external tool with a stub that only prints the
#     command, so the full command sequence can be reviewed without AWS,
#     Sentieon or data (see `pixi run -e cloud dry-run`).

set -euo pipefail

log()  { printf '[%(%Y-%m-%dT%H:%M:%S)T] %s\n' -1 "$*" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

is_dry_run() { [[ "${DRY_RUN:-0}" == 1 ]]; }

if is_dry_run; then
  # Stub heavy/external tools: print the invocation and succeed.
  for _tool in sentieon aws curl fasterq-dump fastq-dump pigz bgzip tabix \
               bcftools samtools multiqc md5sum fastqc trim_galore sum; do
    eval "${_tool}() { printf '[dry-run] %s\n' \"${_tool} \$*\" >&2; }"
  done
  unset _tool
fi

# ---------------------------------------------------------------------------
# S3 helpers
# ---------------------------------------------------------------------------
s3_exists() {  # s3_exists s3://bucket/key -> 0 if the object exists
  is_dry_run && return 1
  aws s3 ls "$1" >/dev/null 2>&1
}

s3_cp() { aws s3 cp --only-show-errors "$@"; }

# put <path relative to $WORK>... : upload run outputs to the same path under $RUN_S3
put() {
  local rel
  for rel in "$@"; do
    s3_cp "$WORK/$rel" "$RUN_S3/$rel"
  done
}

# need <path relative to $WORK>... : download from $RUN_S3 if not present locally
need() {
  local rel
  for rel in "$@"; do
    if [[ ! -s "$WORK/$rel" ]]; then
      mkdir -p "$(dirname "$WORK/$rel")"
      s3_cp "$RUN_S3/$rel" "$WORK/$rel"
    fi
  done
}

# ---------------------------------------------------------------------------
# Checkpointed steps
# ---------------------------------------------------------------------------
# step_at <marker-s3-uri> <name> <function> [args...]
step_at() {
  local marker=$1 name=$2; shift 2
  if s3_exists "$marker"; then
    log "SKIP  ${name} (checkpoint ${marker} exists)"
    return 0
  fi
  log "START ${name}"
  local t0=$SECONDS
  "$@"
  local dt=$((SECONDS - t0))
  local local_marker="$WORK/checkpoints/${name}.done"
  mkdir -p "$(dirname "$local_marker")"
  printf 'step=%s\nfinished_utc=%s\nseconds=%s\ninstance_type=%s\ngit_sha=%s\n' \
    "$name" "$(date -u +%FT%TZ)" "$dt" "${INSTANCE_TYPE:-unknown}" "${GIT_SHA:-unknown}" \
    > "$local_marker"
  printf '%s\t%s\n' "$name" "$dt" >> "$WORK/logs/step_timings.tsv"
  s3_cp "$local_marker" "$marker"
  log "DONE  ${name} in $((dt / 60)) min"
}

# step <name> <function> [args...] : checkpoint stored under the run prefix
step() {
  local name=$1; shift
  step_at "$RUN_S3/checkpoints/${name}.done" "$name" "$@"
}

# ---------------------------------------------------------------------------
# Sample sheet
# ---------------------------------------------------------------------------
# Populates:
#   READ_GROUPS (array, sheet order)   RG_SAMPLE[rg] RG_SOURCE[rg] RG_LIB[rg] RG_PL[rg]
#   TUMOR, NORMAL (sample names)
declare -a READ_GROUPS=()
declare -A RG_SAMPLE=() RG_SOURCE=() RG_LIB=() RG_PL=()
TUMOR="" NORMAL=""

load_samples() {
  local tsv=$1 sample role source rg lib pl
  [[ -s "$tsv" ]] || die "sample sheet not found: $tsv"
  while IFS=$'\t' read -r sample role source rg lib pl; do
    [[ -z "$sample" || "$sample" == \#* ]] && continue
    [[ -n "${RG_SAMPLE[$rg]:-}" ]] && die "duplicate read group id '$rg' in $tsv"
    READ_GROUPS+=("$rg")
    RG_SAMPLE[$rg]=$sample RG_SOURCE[$rg]=$source RG_LIB[$rg]=$lib RG_PL[$rg]=${pl:-ILLUMINA}
    case "$role" in
      tumor)  [[ -z "$TUMOR"  || "$TUMOR"  == "$sample" ]] || die "more than one tumor sample";  TUMOR=$sample ;;
      normal) [[ -z "$NORMAL" || "$NORMAL" == "$sample" ]] || die "more than one normal sample"; NORMAL=$sample ;;
      *) die "role must be 'tumor' or 'normal', got '$role'" ;;
    esac
  done < "$tsv"
  [[ -n "$TUMOR" && -n "$NORMAL" ]] || die "sample sheet needs one tumor and one normal sample"
  [[ "$TUMOR" != "$NORMAL" ]] || die "tumor and normal sample names must differ"
}

read_groups_of() {  # read_groups_of <sample> -> prints rg ids, one per line
  local rg
  for rg in "${READ_GROUPS[@]}"; do
    [[ "${RG_SAMPLE[$rg]}" == "$1" ]] && echo "$rg"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Instance helpers
# ---------------------------------------------------------------------------
imds() {  # imds <path> : IMDSv2 query, e.g. imds meta-data/instance-type
  is_dry_run && { echo "dry-run"; return 0; }
  local token
  token=$(curl -sS -m 2 -X PUT http://169.254.169.254/latest/api/token \
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' 2>/dev/null) || return 1
  curl -sSf -m 2 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/$1" 2>/dev/null
}

# Background loop: push the log to S3 every 2 minutes and record a spot
# interruption notice (AWS gives ~2 minutes of warning) as soon as it appears.
start_background_monitors() {
  is_dry_run && return 0
  (
    while sleep 10; do
      if action=$(imds meta-data/spot/instance-action); then
        log "SPOT INTERRUPTION NOTICE: ${action}. Relaunch with the same RUN_ID to resume."
        echo "$action" > "$WORK/logs/spot_interruption.json"
        s3_cp "$WORK/logs/spot_interruption.json" "$RUN_S3/logs/spot_interruption.$(date +%s).json" || true
        s3_cp "$PIPELINE_LOG" "$RUN_S3/logs/pipeline.log" || true
        exit 0
      fi
      if (( SECONDS % 120 < 10 )); then
        s3_cp "$PIPELINE_LOG" "$RUN_S3/logs/pipeline.log" 2>/dev/null || true
      fi
    done
  ) &
  MONITOR_PID=$!
}
