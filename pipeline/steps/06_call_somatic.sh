#!/usr/bin/env bash
# Step 6: somatic SNV/indel calling on the tumor-normal pair.
#
# CALLER=tnhaplotyper2 (default) - Sentieon's implementation of GATK Mutect2
#   TNhaplotyper2      = Mutect2 (with af-only gnomAD germline resource + PON)
#   OrientationBias    = LearnReadOrientationModel (FFPE/oxoG artifacts)
#   ContaminationModel = GetPileupSummaries + CalculateContamination
#   TNfilter           = FilterMutectCalls
#
# CALLER=tnscope - Sentieon's own caller. Set TNSCOPE_MODEL_S3 to the WGS
#   machine-learning model bundle obtained from Sentieon, plus any
#   model-specific options in TNSCOPE_ARGS (see the model's README).
#
# CALL_INTERVALS (e.g. "chr22") restricts calling; used by the smoke test.
#
# Outputs (vcf/):  <RUN_ID>.<caller>.filtered.vcf.gz  all calls with FILTER set
#                  <RUN_ID>.<caller>.pass.vcf.gz      PASS calls only

call_somatic() {
  local t n p final
  t=$WORK/bam/$TUMOR n=$WORK/bam/$NORMAL p=$WORK/vcf/$RUN_ID
  need "bam/$TUMOR.deduped.bam" "bam/$TUMOR.deduped.bam.bai" "bam/$TUMOR.recal_data.table" \
       "bam/$NORMAL.deduped.bam" "bam/$NORMAL.deduped.bam.bai" "bam/$NORMAL.recal_data.table"

  local -a iv=()
  [[ -n "$CALL_INTERVALS" ]] && iv=(--interval "$CALL_INTERVALS")
  local -a inputs=(-i "$t.deduped.bam" -q "$t.recal_data.table"
                   -i "$n.deduped.bam" -q "$n.recal_data.table")

  case "$CALLER" in
    tnhaplotyper2)
      sentieon driver -r "$REF" -t "$NT" "${iv[@]}" "${inputs[@]}" \
        --algo TNhaplotyper2 --tumor_sample "$TUMOR" --normal_sample "$NORMAL" \
          --germline_vcf "$GNOMAD" --pon "$PON" \
          "$p.tnhaplotyper2.unfiltered.vcf.gz" \
        --algo OrientationBias --tumor_sample "$TUMOR" \
          "$p.orientation_priors.txt" \
        --algo ContaminationModel --tumor_sample "$TUMOR" --normal_sample "$NORMAL" \
          --vcf "$CONTAM_SITES" --tumor_segments "$p.contamination_segments.txt" \
          "$p.contamination.txt"

      sentieon driver -r "$REF" -t "$NT" \
        --algo TNfilter --tumor_sample "$TUMOR" --normal_sample "$NORMAL" \
          -v "$p.tnhaplotyper2.unfiltered.vcf.gz" \
          --contamination "$p.contamination.txt" \
          --tumor_segments "$p.contamination_segments.txt" \
          --orientation_priors "$p.orientation_priors.txt" \
          "$p.tnhaplotyper2.filtered.vcf.gz"
      final=$p.tnhaplotyper2.filtered.vcf.gz
      ;;
    tnscope)
      # shellcheck disable=SC2086  # TNSCOPE_ARGS is intentionally word-split
      sentieon driver -r "$REF" -t "$NT" "${iv[@]}" "${inputs[@]}" \
        --algo TNscope --tumor_sample "$TUMOR" --normal_sample "$NORMAL" \
          --dbsnp "$DBSNP" ${TNSCOPE_ARGS:-} \
          "$p.tnscope.unfiltered.vcf.gz"
      if [[ -n "${TNSCOPE_MODEL_S3:-}" ]]; then
        s3_cp "$TNSCOPE_MODEL_S3" "$WORK/intermediate/tnscope.model"
        sentieon driver -r "$REF" -t "$NT" \
          --algo TNModelApply -m "$WORK/intermediate/tnscope.model" \
          -v "$p.tnscope.unfiltered.vcf.gz" "$p.tnscope.filtered.vcf.gz"
        final=$p.tnscope.filtered.vcf.gz
      else
        warn "TNscope without an ML model: using the caller's built-in filters only"
        final=$p.tnscope.unfiltered.vcf.gz
      fi
      ;;
    *) die "unknown CALLER '$CALLER' (tnhaplotyper2 or tnscope)" ;;
  esac

  bcftools view -f PASS -Oz -o "$p.$CALLER.pass.vcf.gz" "$final"
  bcftools index -t "$p.$CALLER.pass.vcf.gz"

  local f
  for f in "$WORK"/vcf/*; do if [[ -e "$f" ]]; then put "vcf/$(basename "$f")"; fi; done
}
