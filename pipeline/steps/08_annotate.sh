#!/usr/bin/env bash
# Step 8: functional annotation of the PASS somatic calls.
#
#   Ensembl VEP (offline cache)  -> <RUN_ID>.<caller>.pass.vep.vcf.gz
#     --everything: consequence per transcript, SYMBOL, HGVS, canonical/MANE,
#     SIFT/PolyPhen, gnomAD exome+genome and 1000G AFs, ClinVar significance,
#     COSMIC/dbSNP IDs of co-located variants, PubMed. The pick flags match
#     what vcf2maf expects; every transcript's annotation is kept in CSQ.
#   vcf2maf (--inhibit-vep)      -> <RUN_ID>.<caller>.pass.maf
#     One line per variant on the picked transcript, with tumor/normal
#     depths: the MAF format used by GDC/TCGA, cBioPortal and maftools.
#
# VEP and vcf2maf live in their own pixi environment ("annotate"). The VEP
# cache (~25 GB, Ensembl release VEP_CACHE_VERSION, GRCh38) is downloaded once,
# checked against Ensembl's CHECKSUMS, and kept as a tarball in
# s3://$BUCKET/references/vep/ for later runs and relaunches.

annot_env() { pixi run --manifest-path "$REPO_DIR/pixi.toml" -e annotate --frozen "$@"; }
is_dry_run && annot_env() { printf '[dry-run] %s\n' "$*" >&2; }

vep_cache_tarball() { echo "homo_sapiens_vep_${VEP_CACHE_VERSION}_GRCh38.tar.gz"; }

prepare_vep_cache() {
  local tgz dir=$SCRATCH/tmp/vep_download base ok=0
  tgz=$(vep_cache_tarball)
  mkdir -p "$dir"
  for base in "https://ftp.ensembl.org/pub" "https://ftp.ebi.ac.uk/ensemblorg/pub"; do
    local url=$base/release-${VEP_CACHE_VERSION}/variation/indexed_vep_cache
    log "Downloading VEP cache ${tgz} from ${url}"
    if curl -fsSL --retry 5 --retry-all-errors -o "$dir/$tgz" "$url/$tgz"; then
      curl -fsSL --retry 5 -o "$dir/CHECKSUMS" "$url/CHECKSUMS" || warn "no CHECKSUMS file at $url"
      ok=1; break
    fi
    warn "download from $base failed"
  done
  (( ok )) || die "could not download the VEP cache ${tgz}"

  # Ensembl publishes BSD `sum` checksums (checksum, blocks, filename).
  if ! is_dry_run && [[ -s "$dir/CHECKSUMS" ]]; then
    local want got
    want=$(awk -v f="$tgz" '$3 == f {print $1, $2}' "$dir/CHECKSUMS")
    got=$(sum "$dir/$tgz" | awk '{print $1, $2}')
    [[ -n "$want" ]] || die "no checksum for ${tgz} in Ensembl's CHECKSUMS"
    [[ "$want" == "$got" ]] || die "VEP cache checksum mismatch (expected ${want}, got ${got})"
    log "VEP cache checksum OK (${got})"
  fi
  (cd "$dir" && md5sum "$tgz" > "$tgz.md5")
  s3_cp "$dir/$tgz" "$VEP_S3/$tgz"
  s3_cp "$dir/$tgz.md5" "$VEP_S3/$tgz.md5"
  rm -rf "$dir"
}

fetch_vep_cache() {  # unpack the cached tarball to $VEP_DIR (once per instance)
  local tgz
  tgz=$(vep_cache_tarball)
  if [[ -d "$VEP_DIR/homo_sapiens/${VEP_CACHE_VERSION}_GRCh38" ]]; then return 0; fi
  mkdir -p "$VEP_DIR"
  s3_cp "$VEP_S3/$tgz" "$VEP_DIR/$tgz"
  s3_cp "$VEP_S3/$tgz.md5" "$VEP_DIR/$tgz.md5"
  (cd "$VEP_DIR" && md5sum -c --quiet "$tgz.md5") || die "VEP cache tarball corrupted in S3"
  is_dry_run || tar -xzf "$VEP_DIR/$tgz" -C "$VEP_DIR"
  rm -f "$VEP_DIR/$tgz"
}

annotate_somatic() {
  local p=$WORK/vcf/$RUN_ID.$CALLER.pass
  need "vcf/$(basename "$p").vcf.gz"
  fetch_vep_cache

  local forks=$(( NT < 16 ? NT : 16 ))   # VEP needs ~1-2 GB per fork
  # shellcheck disable=SC2086  # VEP_ARGS is intentionally word-split
  annot_env vep \
    --offline --cache --dir_cache "$VEP_DIR" --cache_version "$VEP_CACHE_VERSION" \
    --species homo_sapiens --assembly GRCh38 --fasta "$REF" \
    --input_file "$p.vcf.gz" --format vcf --vcf --output_file "$p.vep.vcf" --force_overwrite \
    --fork "$forks" --buffer_size 5000 --no_progress \
    --everything --check_existing --failed 1 --shift_hgvs 1 --total_length \
    --allele_number --no_escape --xref_refseq \
    --flag_pick_allele --pick_order canonical,tsl,biotype,rank,ccds,length \
    --stats_file "$WORK/metrics/$RUN_ID.$CALLER.vep_summary.html" \
    ${VEP_ARGS:-}

  annot_env vcf2maf.pl --inhibit-vep \
    --input-vcf "$p.vep.vcf" --output-maf "$p.maf" \
    --ref-fasta "$REF" --ncbi-build GRCh38 --species homo_sapiens \
    --tumor-id "$TUMOR" --normal-id "$NORMAL" \
    --vcf-tumor-id "$TUMOR" --vcf-normal-id "$NORMAL" \
    --tmp-dir "$WORK/intermediate"

  bgzip -f -@ "$NT" "$p.vep.vcf"
  tabix -f -p vcf "$p.vep.vcf.gz"

  if ! is_dry_run; then
    log "MAF variant classes: $(awk -F'\t' 'NR>2 {n[$9]++} END {for (k in n) printf "%s=%d ", k, n[k]}' "$p.maf")"
  fi
  put "vcf/$(basename "$p").vep.vcf.gz" "vcf/$(basename "$p").vep.vcf.gz.tbi" "vcf/$(basename "$p").maf"
  local f
  for f in "$WORK/metrics/$RUN_ID.$CALLER".vep_summary*; do
    if [[ -e "$f" ]]; then put "metrics/$(basename "$f")"; fi
  done
}
