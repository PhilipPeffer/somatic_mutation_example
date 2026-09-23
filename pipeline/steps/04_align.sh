#!/usr/bin/env bash
# Step 4: alignment, one read group at a time.
#
#   sentieon bwa mem   = BWA-MEM (identical results, faster)
#   -K 10000000        = fixed batch size, so the output does not depend on the
#                        number of threads/instance type (reproducibility)
#   sentieon util sort = coordinate sort + BAM + index (like samtools sort)
#
# Before aligning: Trim Galore (TRIM_READS=1, default) and FastQC on the raw
# and trimmed reads (in the background); see 03_fastq_qc_trim.sh.
#
# ALT-aware alignment is enabled automatically because the reference ships the
# bwa .alt file. The sorted BAM goes to s3://$BUCKET/intermediate/$RUN_ID/ so
# dedup can resume after an interruption; it is removed at the end of the run.

align_read_group() {
  local rg=$1 sm=${RG_SAMPLE[$1]} fq out trimmed
  fq=$(ensure_fastq "$rg")
  out=$WORK/intermediate/${rg}.sorted.bam
  local r1=$fq/R1.fastq.gz r2=$fq/R2.fastq.gz

  name_fastq_for_reports "$rg" "$fq"
  fastqc_start "${rg}_raw" "$fq/${rg}_R1.fastq.gz" "$fq/${rg}_R2.fastq.gz"
  if [[ "${TRIM_READS:-1}" == 1 ]]; then
    trimmed=$(trim_reads "$rg" "$fq")
    r1=${trimmed% *} r2=${trimmed#* }
    fastqc_start "${rg}_trimmed" "$r1" "$r2"
  fi

  sentieon bwa mem \
      -R "@RG\tID:${rg}\tSM:${sm}\tLB:${RG_LIB[$rg]}\tPL:${RG_PL[$rg]}\tPU:${rg}" \
      -K 10000000 -t "$NT" \
      "$REF" "$r1" "$r2" \
    | sentieon util sort -r "$REF" -t "$NT" --sam2bam -o "$out" -i -

  fastqc_finish "$rg"

  s3_cp "$out" "$INTER_S3/${rg}.sorted.bam"
  s3_cp "$out.bai" "$INTER_S3/${rg}.sorted.bam.bai"
  rm -rf "$fq"   # FASTQ stays cached in S3; free local scratch for the next sample
}
