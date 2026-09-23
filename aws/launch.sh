#!/usr/bin/env bash
# Launch one spot instance that runs the whole pipeline and then terminates.
#     pixi run -e cloud launch              # full run
#     pixi run -e cloud launch --smoke      # cheap test run first (recommended)
#     pixi run -e cloud launch --dry-run    # print user-data + fleet request only
#
# Relaunching the same RUN_ID after a spot interruption resumes from the last
# completed step. The code shipped to the instance is a `git archive` of HEAD,
# so commit your changes first (or pass --allow-dirty for experiments).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "$@"

DRY=0 ALLOW_DIRTY=0
for a in "${ARGS[@]}"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    *) die "unknown option: $a" ;;
  esac
done
(( DRY )) || require_aws

cd "$REPO_DIR" || exit 1
# --- 1. one instance per run ------------------------------------------------
if (( ! DRY )); then
  existing=$(run_instances)
  [[ -z "$existing" ]] || die "run ${RUN_ID} already has instance(s): ${existing} (see: pixi run -e cloud status)"
fi

# --- 2. package the code at this exact commit --------------------------------
GIT_SHA=$(git rev-parse HEAD)
TREE=HEAD
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  (( ALLOW_DIRTY || DRY )) || die "uncommitted changes; commit them (reproducibility) or pass --allow-dirty"
  TREE=$(git stash create)
  GIT_SHA=${GIT_SHA}-dirty-$(date +%Y%m%d%H%M%S)
  log "WARNING: packaging uncommitted changes as ${GIT_SHA}"
fi
CODE_KEY=code/${GIT_SHA}.tar.gz
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/code"
git archive "$TREE" | tar -x -C "$TMP/code"
echo "$GIT_SHA" > "$TMP/code/GIT_SHA"
tar -czf "$TMP/code.tar.gz" -C "$TMP/code" .

# --- 3. per-launch overrides (smoke test) ------------------------------------
OVERRIDES="# written by aws/launch.sh\n"
if (( SMOKE )); then
  OVERRIDES+="RUN_ID=${RUN_ID}\nSUBSAMPLE_READS=${SMOKE_SUBSAMPLE_READS}\nCALL_INTERVALS=${SMOKE_CALL_INTERVALS}\n"
fi
OVERRIDES_B64=$(printf '%b' "$OVERRIDES" | base64 -w0)

# --- 4. render user-data -------------------------------------------------------
sed -e "s|__BUCKET__|${BUCKET}|" -e "s|__RUN_ID__|${RUN_ID}|" -e "s|__CODE_KEY__|${CODE_KEY}|" \
    -e "s|__PIXI_VERSION__|${PIXI_VERSION}|" -e "s|__MAX_RUNTIME_HOURS__|${MAX_RUNTIME_HOURS}|" \
    -e "s|__KEEP_INSTANCE_ON_FAILURE__|${KEEP_INSTANCE_ON_FAILURE}|" \
    -e "s|__OVERRIDES_B64__|${OVERRIDES_B64}|" -e "s|__AWS_REGION__|${AWS_REGION}|" \
    "$REPO_DIR/aws/user_data.sh.tpl" > "$TMP/user_data.sh"
grep -q '__[A-Z_]*__' "$TMP/user_data.sh" && die "unrendered placeholder in user-data"

# --- 5. fleet request: 1 spot instance, cheapest-with-capacity of the candidates -
if (( DRY )); then
  SUBNETS=${SUBNET_IDS:-subnet-DRYRUN-a subnet-DRYRUN-b}
else
  SUBNETS=${SUBNET_IDS:-$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
    --query 'Subnets[].SubnetId' --output text)}
  [[ -n "$SUBNETS" ]] || die "no default subnets found; set SUBNET_IDS in config/pipeline.env"
fi
# Overrides = every (instance type x subnet) combination.
OVERRIDES_JSON=$(jq -n --arg types "$INSTANCE_TYPES" --arg subnets "$(tr -s " \t\n" " " <<<"$SUBNETS")" --arg price "$SPOT_MAX_PRICE" '
  [ ($types | split(" ") | map(select(length>0)))[] as $t
  | ($subnets | split(" ") | map(select(length>0)))[] as $s
  | {InstanceType: $t, SubnetId: $s} + (if $price == "" then {} else {MaxPrice: $price} end) ]')

TAGS=$(jq -n --arg run "$RUN_ID" --arg project "$PROJECT" --arg sha "$GIT_SHA" '
  [{Key:"Name",Value:("sentieon-"+$run)},{Key:"Project",Value:$project},
   {Key:"RunId",Value:$run},{Key:"GitSha",Value:$sha}]')
LT_DATA=$(jq -n --arg ud "$(base64 -w0 < "$TMP/user_data.sh")" --argjson tags "$TAGS" '{
  UserData: $ud,
  TagSpecifications: [{ResourceType:"instance", Tags:$tags}, {ResourceType:"volume", Tags:$tags}]}')

fleet_json() {  # $1 = launch template version
  jq -n --arg lt "$LT_NAME" --arg v "$1" --argjson ov "$OVERRIDES_JSON" '{
    Type: "instant",
    LaunchTemplateConfigs: [{LaunchTemplateSpecification: {LaunchTemplateName: $lt, Version: $v},
                             Overrides: $ov}],
    TargetCapacitySpecification: {TotalTargetCapacity: 1, DefaultTargetCapacityType: "spot"},
    SpotOptions: {AllocationStrategy: "price-capacity-optimized"}}'
}

if (( DRY )); then
  log "DRY RUN - nothing was sent to AWS"
  echo "===== user-data ====="; cat "$TMP/user_data.sh"
  echo "===== overrides.env ====="; printf '%b' "$OVERRIDES"
  echo "===== launch template version data (UserData elided) ====="; jq '.UserData="<base64>"' <<<"$LT_DATA"
  echo "===== create-fleet request ====="; fleet_json '<new version>'
  exit 0
fi

log "Uploading code (${GIT_SHA}) to s3://${BUCKET}/${CODE_KEY}"
aws s3 cp --only-show-errors "$TMP/code.tar.gz" "s3://${BUCKET}/${CODE_KEY}"

# shellcheck disable=SC2016  # '$Default' is a literal launch-template version alias
LT_VERSION=$(aws ec2 create-launch-template-version --launch-template-name "$LT_NAME" \
  --source-version '$Default' --version-description "run ${RUN_ID} ${GIT_SHA}" \
  --launch-template-data "$LT_DATA" --query LaunchTemplateVersion.VersionNumber --output text)

log "Requesting spot capacity for ${RUN_ID} (types: ${INSTANCE_TYPES})"
RESULT=$(aws ec2 create-fleet --cli-input-json "$(fleet_json "$LT_VERSION")")
IID=$(jq -r '.Instances[0].InstanceIds[0] // empty' <<<"$RESULT")
if [[ -z "$IID" ]]; then
  jq -r '.Errors[]? | "\(.LaunchTemplateAndOverrides.Overrides.InstanceType // "?") \(.ErrorCode): \(.ErrorMessage)"' <<<"$RESULT" | sort -u >&2
  die "no spot capacity granted. Add instance types/regions, raise SPOT_MAX_PRICE, or retry later."
fi
ITYPE=$(jq -r '.Instances[0].InstanceType' <<<"$RESULT")

cat >&2 <<MSG

Launched ${IID} (${ITYPE}, spot) for run ${RUN_ID}
  progress   pixi run -e cloud status$( (( SMOKE )) && echo " --smoke")
  log        pixi run -e cloud logs$( (( SMOKE )) && echo " --smoke")
  shell      aws ssm start-session --target ${IID}   (needs the Session Manager plugin)
  results    s3://${BUCKET}/runs/${RUN_ID}/
The instance terminates itself when the pipeline finishes (or fails).
If it is interrupted, just run this command again: completed steps are skipped.
MSG
