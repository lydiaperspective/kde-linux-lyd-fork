
#!/usr/bin/env bash
#
# KDE Linux publishing script
#
# Publishes systemd-sysupdate artifacts directly to the local
# Caddy artifact directory on lyd-opti.
#
# Environment:
#
# OUT             Build output directory (default: mkosi.output)
# DEST            Artifact root (default: /srv/artifacts)
# KEEP            Number of versions to retain (default: 4)
# UPLOAD_ISO      Set to 1 to publish the newest ISO (default: 0)
#
# SIGN_GNUPGHOME  GPG home (default: /var/lib/github-runner/gnupg)
# SIGN_KEY        Existing signing key fingerprint (optional)
# ALLOW_KEYGEN    Set to 1 to generate a key if none exists (default: 0)
#
# Directory layout:
#
# /srv/artifacts/
#   nvidia580xx-legacy/
#     sysupdate/
#       v2/
#         SHA256SUMS
#         SHA256SUMS.gpg
#         kde-linux_<version>.efi
#         kde-linux_<version>_root-x86-64.caibx
#         kde-linux_<version>_root-x86-64.erofs
#     iso/

set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

OUT=${OUT:-mkosi.output}
DEST=${DEST:-/srv/artifacts}
KEEP=${KEEP:-4}
UPLOAD_ISO=${UPLOAD_ISO:-0}

SIGN_GNUPGHOME=${SIGN_GNUPGHOME:-/var/lib/github-runner/gnupg}
FINGERPRINT_FILE="$SIGN_GNUPGHOME/signing-key-fingerprint"

V2="$DEST/nvidia580xx-legacy/sysupdate/v2"
ISO_DIR="$DEST/nvidia580xx-legacy/iso"

# ------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------

if ! [[ "$KEEP" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: KEEP must be a positive integer." >&2
    exit 1
fi

if [[ "$UPLOAD_ISO" != "0" && "$UPLOAD_ISO" != "1" ]]; then
    echo "ERROR: UPLOAD_ISO must be 0 or 1." >&2
    exit 1
fi

if [[ ! -d "$OUT" ]]; then
    echo "ERROR: Build output directory does not exist: $OUT" >&2
    exit 1
fi

if [[ ! -w "$DEST" && -d "$DEST" ]]; then
    echo "ERROR: Cannot write to artifact directory: $DEST" >&2
    exit 1
fi

mkdir -p "$DEST" "$V2"

# ------------------------------------------------------------
# GPG configuration and key management
# ------------------------------------------------------------

mkdir -p "$SIGN_GNUPGHOME"
chmod 700 "$SIGN_GNUPGHOME"

export GNUPGHOME="$SIGN_GNUPGHOME"

echo "Checking KDE Linux signing key..."

# Use explicitly configured fingerprint first,
# otherwise use the saved fingerprint.
if [[ -z "${SIGN_KEY:-}" && -f "$FINGERPRINT_FILE" ]]; then
    SIGN_KEY=$(<"$FINGERPRINT_FILE")
fi

# If a key was explicitly configured, verify that it exists.
if [[ -n "${SIGN_KEY:-}" ]]; then
    if ! gpg --batch --list-secret-keys "$SIGN_KEY" >/dev/null 2>&1; then
        echo "ERROR: Configured signing key not found: $SIGN_KEY" >&2
        exit 1
    fi
else
    # Find existing secret signing keys.
    mapfile -t SECRET_KEYS < <(
        gpg --batch --with-colons --list-secret-keys |
        awk -F: '
            $1 == "sec" { need_fpr=1; next }
            need_fpr && $1 == "fpr" {
                print $10
                need_fpr=0
            }
        '
    )

    if [[ ${#SECRET_KEYS[@]} -eq 1 ]]; then
        SIGN_KEY="${SECRET_KEYS[0]}"

    elif [[ ${#SECRET_KEYS[@]} -gt 1 ]]; then
        echo "ERROR: Multiple secret keys found." >&2
        echo "Set SIGN_KEY to the correct fingerprint." >&2
        exit 1

    else
        # No existing key. Generate only when explicitly allowed.
        if [[ "${ALLOW_KEYGEN:-0}" != "1" ]]; then
            echo "ERROR: No signing key found." >&2
            echo "Set ALLOW_KEYGEN=1 for first-time key generation." >&2
            exit 1
        fi

        echo "Generating a new KDE Linux signing key..."

        gpg --batch --pinentry-mode loopback \
            --passphrase '' \
            --quick-generate-key \
            "KDE Linux Update Signing <updates@kde-linux.local>" \
            ed25519 sign 5y

        SIGN_KEY=$(
            gpg --batch --with-colons --list-secret-keys |
            awk -F: '
                $1 == "sec" { need_fpr=1; next }
                need_fpr && $1 == "fpr" {
                    print $10
                    exit
                }
            '
        )

        if [[ -z "$SIGN_KEY" ]]; then
            echo "ERROR: Could not retrieve generated key fingerprint." >&2
            exit 1
        fi

        printf '%s\n' "$SIGN_KEY" > "$FINGERPRINT_FILE"
        chmod 600 "$FINGERPRINT_FILE"

        echo "Generated signing key: $SIGN_KEY"
        echo "IMPORTANT: Export and distribute its public key to clients."
    fi
fi

export SIGN_KEY

echo "Using signing key: $SIGN_KEY"

# ------------------------------------------------------------
# Find newest build
# ------------------------------------------------------------

newest=$(
    find "$OUT" -maxdepth 1 -type f \
        -name 'kde-linux_*_root-x86-64.erofs' |
    sort -V |
    tail -n 1
)

if [[ -z "$newest" || ! -f "$newest" ]]; then
    echo "ERROR: No EROFS image found in $OUT" >&2
    exit 1
fi

VERSION=$(
    basename "$newest" |
    sed -E 's/^kde-linux_(.*)_root-x86-64\.erofs$/\1/'
)

EFI="$OUT/kde-linux_${VERSION}.efi"
CAIBX="$OUT/kde-linux_${VERSION}_root-x86-64.caibx"

for file in "$EFI" "$CAIBX"; do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Missing required build artifact: $file" >&2
        exit 1
    fi
done

echo
echo "Publishing KDE Linux version: $VERSION"
echo

# ------------------------------------------------------------
# Stage artifacts
# ------------------------------------------------------------

STAGE=$(mktemp -d "$DEST/.publish-${VERSION}.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

echo "Staging artifacts..."

cp --reflink=auto \
    "$newest" \
    "$EFI" \
    "$CAIBX" \
    "$STAGE/"

# ------------------------------------------------------------
# Generate checksums
# ------------------------------------------------------------

echo "Generating SHA256SUMS..."

(
    cd "$STAGE"

    sha256sum -- \
        "kde-linux_${VERSION}.efi" \
        "kde-linux_${VERSION}_root-x86-64.caibx" \
        "kde-linux_${VERSION}_root-x86-64.erofs" \
        > SHA256SUMS
)

# ------------------------------------------------------------
# Sign checksums
# ------------------------------------------------------------

echo "Signing SHA256SUMS..."

gpg --batch --yes \
    --local-user "$SIGN_KEY" \
    --output "$STAGE/SHA256SUMS.gpg" \
    --detach-sign "$STAGE/SHA256SUMS"

# Verify signature before publishing.
echo "Verifying signature..."

gpg --verify \
    "$STAGE/SHA256SUMS.gpg" \
    "$STAGE/SHA256SUMS"

# ------------------------------------------------------------
# Publish payload files
# ------------------------------------------------------------

echo "Publishing payload files..."

for file in \
    "kde-linux_${VERSION}.efi" \
    "kde-linux_${VERSION}_root-x86-64.caibx" \
    "kde-linux_${VERSION}_root-x86-64.erofs"
do
    install -m 0644 "$STAGE/$file" "$V2/$file"
done

# ------------------------------------------------------------
# Prune old versions
# ------------------------------------------------------------

echo "Checking version retention..."

mapfile -t VERSIONS < <(
    find "$V2" -maxdepth 1 -type f \
        -name 'kde-linux_*_root-x86-64.erofs' \
        -printf '%f\n' |
    sed -E 's/^kde-linux_(.*)_root-x86-64\.erofs$/\1/' |
    sort -Vr
)

for old in "${VERSIONS[@]:$KEEP}"; do
    echo "Removing old version: $old"

    rm -f \
        "$V2/kde-linux_${old}.efi" \
        "$V2/kde-linux_${old}_root-x86-64.caibx" \
        "$V2/kde-linux_${old}_root-x86-64.erofs"
done

# ------------------------------------------------------------
# Publish manifests LAST
# ------------------------------------------------------------

echo "Publishing signed manifests..."

install -m 0644 \
    "$STAGE/SHA256SUMS" \
    "$V2/SHA256SUMS.tmp"

install -m 0644 \
    "$STAGE/SHA256SUMS.gpg" \
    "$V2/SHA256SUMS.gpg.tmp"

mv -f "$V2/SHA256SUMS.tmp" "$V2/SHA256SUMS"
mv -f "$V2/SHA256SUMS.gpg.tmp" "$V2/SHA256SUMS.gpg"

# ------------------------------------------------------------
# Optional ISO publishing
# ------------------------------------------------------------

if [[ "$UPLOAD_ISO" == "1" ]]; then
    ISO="$OUT/kde-linux_${VERSION}.iso"

    if [[ ! -f "$ISO" ]]; then
        echo "ERROR: Requested ISO not found: $ISO" >&2
        exit 1
    fi

    mkdir -p "$ISO_DIR"

    echo "Publishing ISO..."

    install -m 0644 "$ISO" "$ISO_DIR/"
fi

# ------------------------------------------------------------
# Finished
# ------------------------------------------------------------

echo
echo "========================================"
echo " KDE Linux publishing completed"
echo " Version: $VERSION"
echo " Destination: $V2"
echo " Retained versions: $KEEP"
echo "========================================"
