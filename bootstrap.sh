#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Harald Sitter <sitter@kde.org>
# SPDX-FileCopyrightText: 2024 Bruno Pajdek <brupaj@proton.me>

# Bootstraps an Arch Linux Docker container to be ready for building KDE Linux.

# WARNING: DO NOT CALL INTO OTHER SCRIPTS HERE.
# This file needs to be self-contained because it gets run by the CI VM provisioning in isolation.

# Exit immediately if any command fails and print all commands before they are executed.
set -ex

# From https://hub.docker.com/_/archlinux/:
#
# "For Security Reasons, these images strip the pacman lsign key.
# This is because the same key would be spread to all containers of the same image,
# allowing for malicious actors to inject packages (via, for example, a man-in-the-middle).
# In order to create a lsign-key run pacman-key --init on the first execution,
# but be careful to not redistribute that key."
#
pacman-key --init
# On VM images make sure we have the keyring populated.
pacman-key --populate


# --------------------------------------------------
# CachyOS repository setup
# --------------------------------------------------

CACHYOS_KEY="882DCFE48E2051D48E2562ABF3B607488DB35A47"
CACHYOS_MIRROR="https://mirror.cachyos.org/repo/x86_64/cachyos"

# Download the CachyOS signing key.
curl -4 -fsSL \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/${CACHYOS_KEY}" \
    -o /tmp/cachyos-key.asc

# Verify that the downloaded key has the expected fingerprint.
ACTUAL_FINGERPRINT=$(
    gpg --show-keys --with-colons /tmp/cachyos-key.asc |
    awk -F: '$1 == "fpr" { print $10; exit }'
)

if [ "$ACTUAL_FINGERPRINT" != "$CACHYOS_KEY" ]; then
    echo "ERROR: CachyOS signing key fingerprint mismatch!" >&2
    exit 1
fi

# Import and locally sign the CachyOS key.
pacman-key --add /tmp/cachyos-key.asc
pacman-key --lsign-key "$CACHYOS_KEY"

rm -f /tmp/cachyos-key.asc

# --------------------------------------------------
# Retrieve the latest CachyOS package filenames
# --------------------------------------------------

# Download the repository database.
curl -4 -fsSL \
    "${CACHYOS_MIRROR}/cachyos.db" \
    -o /tmp/cachyos.db

# Extract the actual package archive filename from the database.
get_package_filename() {
    PACKAGE_PATTERN=$1

    ENTRY=$(
        bsdtar -tf /tmp/cachyos.db |
        grep "^${PACKAGE_PATTERN}[^/]*/desc$" |
        sort -V |
        tail -n 1
    )

    if [ -z "$ENTRY" ]; then
        echo "ERROR: Could not find ${PACKAGE_PATTERN} in CachyOS repository." >&2
        return 1
    fi

    FILENAME=$(
        bsdtar -xOf /tmp/cachyos.db "$ENTRY" |
        awk '$0 == "%FILENAME%" { getline; print; exit }'
    )

    if [ -z "$FILENAME" ]; then
        echo "ERROR: Could not determine archive filename for ${ENTRY}." >&2
        return 1
    fi

    printf '%s\n' "$FILENAME"
}

CACHYOS_KEYRING=$(get_package_filename cachyos-keyring-)
CACHYOS_MIRRORLIST=$(get_package_filename cachyos-mirrorlist-)

echo "CachyOS keyring: ${CACHYOS_KEYRING}"
echo "CachyOS mirrorlist: ${CACHYOS_MIRRORLIST}"

# --------------------------------------------------
# Download packages and signatures
# --------------------------------------------------

for PACKAGE in "$CACHYOS_KEYRING" "$CACHYOS_MIRRORLIST"; do

    curl -4 -fsSL \
        "${CACHYOS_MIRROR}/${PACKAGE}" \
        -o "/tmp/${PACKAGE}"

    curl -4 -fsSL \
        "${CACHYOS_MIRROR}/${PACKAGE}.sig" \
        -o "/tmp/${PACKAGE}.sig"

done

# --------------------------------------------------
# Install CachyOS keyring and mirrorlist
# --------------------------------------------------

pacman -U --noconfirm \
    "/tmp/${CACHYOS_KEYRING}" \
    "/tmp/${CACHYOS_MIRRORLIST}"

# Clean up downloaded files.
rm -f /tmp/cachyos.db \
    "/tmp/${CACHYOS_KEYRING}" \
    "/tmp/${CACHYOS_KEYRING}.sig" \
    "/tmp/${CACHYOS_MIRRORLIST}" \
    "/tmp/${CACHYOS_MIRRORLIST}.sig"

# --------------------------------------------------
# Enable CachyOS repository
# --------------------------------------------------

if ! grep -q '^\[cachyos\]$' /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<'EOF'

[cachyos]
SigLevel = PackageRequired
Include = /etc/pacman.d/cachyos-mirrorlist
EOF
fi

# --------------------------------------------------
# End CachyOS repository setup
# --------------------------------------------------


# Restore the pacman.conf file from the pacman package. The docker one is crippled with NoExtract options and the like :(
#  --refresh twice to force a refresh
mkdir /tmp/pacman
pacman --sync --refresh --refresh --downloadonly --noconfirm pacman
tar --extract --file "$(printf '%s\n' /var/cache/pacman/pkg/pacman-[0-9]*.pkg.tar.zst | sort -V | tail -n 1)" --directory /tmp/pacman
cp /tmp/pacman/etc/pacman.conf /etc/pacman.conf

cp /etc/pacman.conf /etc/pacman.conf.nolinux # store a backup for use in the packages pipeline

# Ensure the packages repo and the base image do not go out of sync
# by using the same snapshot date from BUILD_REPO.txt for both
# WARNING: code copy in build.sh
BUILD_REPO=$(curl --fail --silent https://kde-linux-packages.s3.kde.org/testing/repo/build_repo.txt)
if [ -z "$BUILD_REPO" ]; then
  echo "ERROR: Could not fetch build_repo.txt — refusing to build out-of-sync image." >&2
  exit 1
fi
echo "Server = ${BUILD_REPO}/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist

# ParallelDownloads is enabled by default since pacman 7.0.0.r6.gc685ae6-2,
# so no need to uncomment or manually set it unless we want to change the value.

# Update the system and install packages we'll need for building KDE Linux.
#  --refresh twice to force a refresh
pacman --sync --refresh --refresh --noconfirm --sysupgrade \
    mkosi \
    arch-install-scripts \
    base-devel \
    btrfs-progs \
    clang \
    compsize \
    cpio \
    dosfstools \
    duperemove \
    erofs-utils \
    flatpak \
    git \
    go \
    openssh \
    qemu-base \
    qemu-img \
    rsync \
    ruby \
    ruby-nokogiri \
    rust \
    squashfs-tools \
    transmission-cli \
    tree \
    ukify \
    wget \
    lzip \
    python-pip

pip install --break-system-packages 'BuildStream>=2.7' buildstream-plugins dulwich tomlkit
