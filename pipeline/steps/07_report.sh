#!/usr/bin/env bash
# Step 7: QC summary, MultiQC report and a machine-readable run manifest
# (everything needed to reproduce or audit the run), then clean up the
# intermediate BAMs in S3.

make_report() {
  local p=$WORK/vcf/$RUN_ID r=$WORK/report
  local pass=$p.$CALLER.pass.vcf.gz
  need "vcf/$(basename "$pass")"

  bcftools stats "$pass" > "$WORK/metrics/$RUN_ID.$CALLER.pass.bcftools_stats.txt"
  local snvs indels
  snvs=$(bcftools view -H -v snps "$pass" | wc -l)
  indels=$(bcftools view -H -v indels "$pass" | wc -l)
  log "PASS somatic calls: ${snvs} SNVs, ${indels} indels"

  multiqc --force --quiet --outdir "$r" --filename "$RUN_ID.multiqc.html" "$WORK/metrics" \
    || warn "MultiQC failed"

  # Tool versions and checksums for the manifest.
  local sentieon_ver="dry-run" vcf_md5="dry-run"
  if ! is_dry_run; then
    sentieon_ver=$(sentieon driver --version 2>&1 | head -1)
    vcf_md5=$(md5sum "$pass" | cut -d' ' -f1)
  fi
  jq -n \
    --arg run_id "$RUN_ID" --arg git_sha "$GIT_SHA" \
    --arg started "$STARTED_UTC" --arg finished "$(date -u +%FT%TZ)" \
    --arg instance_type "$INSTANCE_TYPE" \
    --arg instance_id "$(imds meta-data/instance-id || echo unknown)" \
    --arg ami_id "$(imds meta-data/ami-id || echo unknown)" \
    --arg lifecycle "$(imds meta-data/instance-life-cycle || echo unknown)" \
    --arg region "${AWS_REGION:-}" --arg threads "$NT" \
    --arg sentieon "$sentieon_ver" --arg caller "$CALLER" \
    --arg samtools "$(samtools --version 2>/dev/null | head -1)" \
    --arg bcftools "$(bcftools --version 2>/dev/null | head -1)" \
    --arg sratools "$(fasterq-dump --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
    --arg pixi_lock_sha256 "$(sha256sum "$REPO_DIR/pixi.lock" | cut -d' ' -f1)" \
    --arg tumor "$TUMOR" --arg normal "$NORMAL" \
    --arg subsample "$SUBSAMPLE_READS" --arg intervals "$CALL_INTERVALS" \
    --arg pass_vcf "$(basename "$pass")" --arg pass_vcf_md5 "$vcf_md5" \
    --arg snvs "$snvs" --arg indels "$indels" \
    --rawfile samples "$SAMPLES_TSV" \
    --rawfile timings "$WORK/logs/step_timings.tsv" \
    '{run_id:$run_id, git_sha:$git_sha, started_utc:$started, finished_utc:$finished,
      instance:{type:$instance_type, id:$instance_id, ami:$ami_id, lifecycle:$lifecycle,
                region:$region, threads:($threads|tonumber)},
      software:{sentieon:$sentieon, samtools:$samtools, bcftools:$bcftools,
                sra_tools:$sratools, pixi_lock_sha256:$pixi_lock_sha256},
      params:{caller:$caller, subsample_reads:($subsample|tonumber), call_intervals:$intervals},
      samples:{tumor:$tumor, normal:$normal, sheet:$samples},
      results:{pass_vcf:$pass_vcf, pass_vcf_md5:$pass_vcf_md5,
               pass_snvs:($snvs|tonumber? // null), pass_indels:($indels|tonumber? // null)},
      step_seconds:($timings | split("\n") | map(select(length>0) | split("\t") | {(.[0]):(.[1]|tonumber)}) | add)}' \
    > "$r/run_manifest.json"

  local f
  for f in "$r"/* "$WORK/metrics/$RUN_ID".*; do
    if [[ -f "$f" ]]; then s3_cp "$f" "$RUN_S3/${f#"$WORK"/}"; fi
  done
  aws s3 rm --only-show-errors --recursive "$INTER_S3/"
}
