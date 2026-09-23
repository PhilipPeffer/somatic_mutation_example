#!/usr/bin/env bash
# Step 0: install the pinned Sentieon release and configure the license.
#
# The release tarball is cached in your bucket (s3://$BUCKET/software/) the
# first time, so later runs keep using the identical build even if Sentieon
# retires that version from its public bucket.
#
# License (set ONE of these in config/pipeline.env):
#   SENTIEON_LICENSE_SERVER=host:port   license server provided by Sentieon
#   SENTIEON_LICENSE_S3=s3://.../x.lic  license file uploaded to your bucket
# Any extra SENTIEON_* variables Sentieon asks you to set (e.g. for its cloud
# licensing) can simply be added to config/pipeline.env; they are exported.

install_sentieon() {
  local tgz=sentieon-genomics-${SENTIEON_VERSION:?set SENTIEON_VERSION}.tar.gz
  local cache=s3://$BUCKET/software/$tgz
  local opt=$SCRATCH/opt
  SENTIEON_DIR=$opt/sentieon-genomics-$SENTIEON_VERSION
  mkdir -p "$opt"

  if ! is_dry_run && [[ ! -x "$SENTIEON_DIR/bin/sentieon" ]]; then
    if s3_exists "$cache"; then
      s3_cp "$cache" "$opt/$tgz"
    else
      log "Downloading Sentieon ${SENTIEON_VERSION} from the public sentieon-release bucket"
      aws s3 cp --only-show-errors --no-sign-request \
        "s3://sentieon-release/software/$tgz" "$opt/$tgz" \
        || curl -fsSL --retry 5 -o "$opt/$tgz" "https://s3.amazonaws.com/sentieon-release/software/$tgz"
      s3_cp "$opt/$tgz" "$cache"
    fi
    tar -xzf "$opt/$tgz" -C "$opt"
    rm -f "$opt/$tgz"
  fi
  export PATH=$SENTIEON_DIR/bin:$PATH

  if [[ -n "${SENTIEON_LICENSE_SERVER:-}" ]]; then
    export SENTIEON_LICENSE=$SENTIEON_LICENSE_SERVER
    log "License server: ${SENTIEON_LICENSE}"
    sentieon licclnt ping -s "$SENTIEON_LICENSE" \
      || die "cannot reach Sentieon license server ${SENTIEON_LICENSE}"
  elif [[ -n "${SENTIEON_LICENSE_S3:-}" ]]; then
    s3_cp "$SENTIEON_LICENSE_S3" "$opt/sentieon.lic"
    is_dry_run || chmod 600 "$opt/sentieon.lic"
    export SENTIEON_LICENSE=$opt/sentieon.lic
    log "License file: ${SENTIEON_LICENSE_S3}"
  else
    die "set SENTIEON_LICENSE_SERVER or SENTIEON_LICENSE_S3 in config/pipeline.env"
  fi

  is_dry_run || log "$(sentieon driver --version)"
}
