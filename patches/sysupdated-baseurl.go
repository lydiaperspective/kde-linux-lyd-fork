//
//# SPDX-FileCopyrightText: 2026 Lydia Hornbrook
//# SPDX-License-Identifier: GPL-3.0-or-later
// Local patch for the lyd fork: lets a self-hosted update server replace KDE's.

package main

import (
	"os"
	"strings"
)

// upstreamBase returns the base URL of the update server, with a trailing slash.
// Set KDE_LINUX_SYSUPDATED_BASE_URL (e.g. in a systemd drop-in) to override KDE's server.
func upstreamBase() string {
	base := os.Getenv("KDE_LINUX_SYSUPDATED_BASE_URL")
	if base == "" {
		base = "https://kde-linux-images.s3.kde.org/"
	}
	if !strings.HasSuffix(base, "/") {
		base += "/"
	}
	return base
}
