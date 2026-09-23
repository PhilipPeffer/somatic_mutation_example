#!/usr/bin/env bash
# Step 4: alignment QC metrics and duplicate marking, per sample (all read
# groups of the sample are merged here).
#
#   MeanQualityByCycle, QualDistribution, GCBias, AlignmentStat,
#   InsertSizeMetricAlgo    = Picard CollectMultipleMetrics equivalents
#   LocusCollector + Dedup  = Picard MarkDuplicates (duplicates are marked, not removed)

metrics_and_dedup() {
  local sm=$1 rg bam m
  local -a in=()
  for rg in $(read_groups_of "$sm"); do
    bam=$WORK/intermediate/${rg}.sorted.bam
    if [[ ! -s "$bam" ]]; then
      s3_cp "$INTER_S3/${rg}.sorted.bam" "$bam"
      s3_cp "$INTER_S3/${rg}.sorted.bam.bai" "$bam.bai"
    fi
    in+=(-i "$bam")
  done
  m=$WORK/metrics/$sm

  sentieon driver -r "$REF" -t "$NT" "${in[@]}" \
    --algo MeanQualityByCycle "$m.mq_metrics.txt" \
    --algo QualDistribution "$m.qd_metrics.txt" \
    --algo GCBias --summary "$m.gc_summary.txt" "$m.gc_metrics.txt" \
    --algo AlignmentStat --adapter_seq '' "$m.aln_metrics.txt" \
    --algo InsertSizeMetricAlgo "$m.is_metrics.txt"

  sentieon driver -t "$NT" "${in[@]}" \
    --algo LocusCollector --fun score_info "$WORK/intermediate/$sm.score.txt.gz"
  sentieon driver -t "$NT" "${in[@]}" \
    --algo Dedup --score_info "$WORK/intermediate/$sm.score.txt.gz" \
    --metrics "$m.dedup_metrics.txt" "$WORK/bam/$sm.deduped.bam"

  # PDF plots are a convenience; never fail the run over them.
  sentieon plot GCBias -o "$m.gc_bias.pdf" "$m.gc_metrics.txt" || warn "plot GCBias failed"
  sentieon plot QualDistribution -o "$m.qual_dist.pdf" "$m.qd_metrics.txt" || warn "plot QualDistribution failed"
  sentieon plot MeanQualityByCycle -o "$m.mean_qual_by_cycle.pdf" "$m.mq_metrics.txt" || warn "plot MeanQualityByCycle failed"
  sentieon plot InsertSizeMetricAlgo -o "$m.insert_size.pdf" "$m.is_metrics.txt" || warn "plot InsertSize failed"

  put "bam/$sm.deduped.bam" "bam/$sm.deduped.bam.bai"
  local f
  for f in "$m".*; do if [[ -e "$f" ]]; then put "metrics/$(basename "$f")"; fi; done

  # Local copies are no longer needed (S3 copies remain until the run finishes).
  for rg in $(read_groups_of "$sm"); do
    rm -f "$WORK/intermediate/${rg}.sorted.bam" "$WORK/intermediate/${rg}.sorted.bam.bai"
  done
}
