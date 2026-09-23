#!/usr/bin/env bash
# Step 6: base quality score recalibration (GATK BaseRecalibrator equivalent)
# plus genome-wide coverage metrics (Picard CollectWgsMetrics equivalent),
# in a single pass over the deduplicated BAM.
#
# Only the recalibration table is written; it is applied on the fly with
# `-q` during variant calling, which saves writing another ~100 GB BAM.

bqsr_and_coverage() {
  local sm=$1
  need "bam/$sm.deduped.bam" "bam/$sm.deduped.bam.bai"

  sentieon driver -r "$REF" -t "$NT" -i "$WORK/bam/$sm.deduped.bam" \
    --algo QualCal -k "$DBSNP" -k "$MILLS" -k "$KNOWN_INDELS" \
      "$WORK/bam/$sm.recal_data.table" \
    --algo WgsMetricsAlgo "$WORK/metrics/$sm.wgs_metrics.txt"

  put "bam/$sm.recal_data.table" "metrics/$sm.wgs_metrics.txt"
}
