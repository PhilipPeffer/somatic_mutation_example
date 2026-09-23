#!/usr/bin/env bash
# Step 1: GRCh38 reference bundle (Broad/GATK hg38 v0 + GATK somatic resources).
#
# Built once per bucket and cached at s3://$BUCKET/references/$GENOME/; every
# later run (and every relaunched spot instance) just syncs the cache.
# Files, sources and expected MD5s are pinned in config/references_$GENOME.tsv.
#
#   FASTA + .fai + .dict + bwa index (+ .alt for ALT-aware alignment)
#   dbSNP 138, Mills/1000G gold-standard indels, known indels  -> BQSR
#   af-only gnomAD (germline resource), 1000G PON               -> TNhaplotyper2
#   small_exac_common_3 (common biallelic SNPs)                 -> ContaminationModel

prepare_reference() {
  local manifest=$REPO_DIR/config/references_${GENOME}.tsv
  local -a args=()
  local name md5 url
  while IFS=$'\t' read -r name md5 url; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    args+=(-o "$REF_DIR/$name" "$url")
  done < "$manifest"

  log "Downloading $(( ${#args[@]} / 3 )) reference files (~20 GB)"
  curl -fsSL --retry 5 --retry-all-errors --parallel --parallel-max 8 "${args[@]}"

  # Verify every download against the pinned MD5 (where the source publishes one).
  local bad=0 got
  : > "$REF_DIR/md5sums.txt"
  while IFS=$'\t' read -r name md5 url; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    got=$(md5sum "$REF_DIR/$name" | cut -d' ' -f1)
    printf '%s  %s\n' "$got" "$name" >> "$REF_DIR/md5sums.txt"
    if [[ "$md5" != "-" && -n "$got" && "$got" != "$md5" ]]; then
      warn "MD5 mismatch for $name: expected $md5 got $got"; bad=1
    fi
  done < "$manifest"
  (( bad == 0 )) || die "reference download corrupted; delete ${REF_DIR} and retry"

  # dbSNP is only published uncompressed; bgzip + tabix so Sentieon can index-query it.
  bgzip -@ "$NT" "$REF_DIR/Homo_sapiens_assembly38.dbsnp138.vcf"
  tabix -p vcf "$REF_DIR/Homo_sapiens_assembly38.dbsnp138.vcf.gz"

  aws s3 sync --only-show-errors "$REF_DIR/" "$REF_S3/"
}

fetch_reference() {
  aws s3 sync --only-show-errors "$REF_S3/" "$REF_DIR/"
  REF=$REF_DIR/Homo_sapiens_assembly38.fasta
  DBSNP=$REF_DIR/Homo_sapiens_assembly38.dbsnp138.vcf.gz
  MILLS=$REF_DIR/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz
  KNOWN_INDELS=$REF_DIR/Homo_sapiens_assembly38.known_indels.vcf.gz
  GNOMAD=$REF_DIR/af-only-gnomad.hg38.vcf.gz
  PON=$REF_DIR/1000g_pon.hg38.vcf.gz
  CONTAM_SITES=$REF_DIR/small_exac_common_3.hg38.vcf.gz
  if ! is_dry_run; then
    local f
    for f in "$REF" "$REF.bwt" "$DBSNP" "$MILLS" "$KNOWN_INDELS" "$GNOMAD" "$PON" "$CONTAM_SITES"; do
      [[ -s "$f" ]] || die "reference file missing: $f"
    done
  fi
}
