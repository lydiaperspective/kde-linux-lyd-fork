#!/usr/bin/env bash
# Stage the newest build as a systemd-sysupdate tree, sign it, and push it to the home server.
#
# Env:
#   DEST_BASE   rsync destination prefix, e.g. "imgpush@lyd-opti:" (rrsync root) or a local dir ending in "/"
#   SIGN_KEY    fingerprint of the signing key in $SIGN_GNUPGHOME
#   SIGN_GNUPGHOME  gpg home holding the private signing key
#   OUT         build output dir (default mkosi.output)
#   STAGE       local mirror of what the server should hold (default ~/kde-images-stage)
#   KEEP        versions to keep (default 4, matches InstancesMax in the .transfer files)
#   BWLIMIT     rsync bandwidth limit in KiB/s (default 20000)
#   UPLOAD_ISO  set to 1 to also publish the newest ISO (default 0)
set -euo pipefail

OUT=${OUT:-mkosi.output}
STAGE=${STAGE:-$HOME/kde-images-stage}
KEEP=${KEEP:-4}
BWLIMIT=${BWLIMIT:-20000}
UPLOAD_ISO=${UPLOAD_ISO:-0}
: "${DEST_BASE:?set DEST_BASE}" "${SIGN_KEY:?set SIGN_KEY}" "${SIGN_GNUPGHOME:?set SIGN_GNUPGHOME}"

V2="$STAGE/desktop/sysupdate/v2"
mkdir -p "$V2"

# Newest version = newest erofs. The main UKI is kde-linux_<version>.efi; other *.efi
# files in the output (live, erofs addon) must not be published.
newest=$(printf '%s\n' "$OUT"/kde-linux_*_root-x86-64.erofs | sort | tail -n 1)
[ -f "$newest" ] || { echo "No erofs image found in $OUT" >&2; exit 1; }
VERSION=$(basename "$newest" | sed -E 's/^kde-linux_(.*)_root-x86-64\.erofs$/\1/')
EFI="$OUT/kde-linux_${VERSION}.efi"
[ -f "$EFI" ] || { echo "Missing $EFI" >&2; exit 1; }
echo "Publishing version $VERSION"

cp --reflink=auto "$newest" "$EFI" "$V2/"

# Keep only the newest $KEEP versions in the local mirror.
mapfile -t versions < <(cd "$V2" && printf '%s\n' kde-linux_*_root-x86-64.erofs \
    | sed -E 's/^kde-linux_(.*)_root-x86-64\.erofs$/\1/' | sort -r)
for old in "${versions[@]:$KEEP}"; do
    echo "Pruning $old"
    rm -f "$V2/kde-linux_${old}_root-x86-64.erofs" "$V2/kde-linux_${old}.efi"
done

# Checksums + detached signature, same layout upload.sh produces for KDE.
(
    cd "$V2"
    sha256sum -- *.efi *.erofs > SHA256SUMS
    GNUPGHOME="$SIGN_GNUPGHOME" gpg --batch --yes --local-user "$SIGN_KEY" \
        --output SHA256SUMS.gpg --detach-sign SHA256SUMS
)

if [ "$UPLOAD_ISO" = 1 ]; then
    mkdir -p "$STAGE/desktop/iso"
    rm -f "$STAGE"/desktop/iso/*
    cp --reflink=auto "$OUT/kde-linux_${VERSION}.iso" "$STAGE/desktop/iso/"
fi

RSYNC=(rsync -a --partial --bwlimit="$BWLIMIT")
# 1) new payload first, 2) checksums last so clients never see a listing without its files,
# 3) then delete what was pruned.
"${RSYNC[@]}" --exclude 'SHA256SUMS*' "$STAGE/desktop/" "${DEST_BASE}desktop/"
"${RSYNC[@]}" --ignore-times "$V2/SHA256SUMS" "$V2/SHA256SUMS.gpg" "${DEST_BASE}desktop/sysupdate/v2/"
"${RSYNC[@]}" --delete "$STAGE/desktop/" "${DEST_BASE}desktop/"
echo "Done: $VERSION"
