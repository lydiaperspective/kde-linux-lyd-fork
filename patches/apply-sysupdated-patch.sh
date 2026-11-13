#!/bin/sh


# SPDX-FileCopyrightText: 2026 Lydia Hornbrook
# SPDX-License-Identifier: GPL-3.0-or-later

# Usage: apply-sysupdated-patch.sh <kde-linux-sysupdated checkout>
# Replaces the hardcoded KDE server in the daemon with upstreamBase(). Fails loudly if upstream changed.
set -eu
dir=$1
here=$(dirname "$0")
cp "$here/sysupdated-baseurl.go" "$dir/baseurl.go"
sed -i 's|fmt.Sprintf("https://kde-linux-images.s3.kde.org/%s/%s", variant_id, endpoint)|fmt.Sprintf("%s%s/%s", upstreamBase(), variant_id, endpoint)|' "$dir/main.go"
sed -i 's|url.Parse("https://kde-linux-images.s3.kde.org/" + path)|url.Parse(upstreamBase() + path)|' "$dir/main.go"
if [ "$(grep -c 'upstreamBase()' "$dir/main.go")" != 2 ]; then
    echo "sysupdated patch did not apply cleanly (upstream main.go changed?)" >&2
    exit 1
fi
