#!/usr/bin/env bash
#
# AltTab Cloud Agent install script.
#
# IMPORTANT: AltTab is a macOS-only AppKit/Carbon app. It overrides the native
# macOS Cmd+Tab, drives the Accessibility (AX) API, and links the private
# SkyLight framework, so it CANNOT be compiled or run on Linux — `swift build`
# fails immediately with "no such module 'AppKit'". Cloud Agents run on Linux,
# so this environment only provides the Swift 6.3.x toolchain for code
# navigation, editing, refactoring, `swift package` manifest tooling and syntax
# work. A real build/run/notarize still requires a macOS host with Xcode or the
# Command Line Tools (see build.sh and CLAUDE.md).
#
# Idempotent: re-running is safe. It skips the toolchain download when the exact
# version is already installed and only refreshes the symlinks and SwiftPM state.
set -euo pipefail

# Pinned to match the repo's Swift 6.3.x (CLAUDE.md) on the Ubuntu 24.04 host.
SWIFT_VERSION="6.3.3"
SWIFTLY_HOME="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"
TOOLCHAIN_BIN="$SWIFTLY_HOME/toolchains/$SWIFT_VERSION/usr/bin"

log() { printf '==> %s\n' "$*"; }

install_swift() {
  log "Installing Swift $SWIFT_VERSION (this downloads ~1 GB on first run)"

  # Runtime/build libraries the Swift toolchain needs on Ubuntu 24.04.
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
    libz3-dev pkg-config tzdata zip unzip zlib1g-dev curl ca-certificates

  # swiftly is the official toolchain manager; it verifies the download signature.
  if [ ! -x "$SWIFTLY_HOME/bin/swiftly" ]; then
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/swiftly.tar.gz" \
      "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
    tar -C "$tmp" -xzf "$tmp/swiftly.tar.gz"
    # --no-modify-profile: PATH is handled below via /usr/local/bin symlinks.
    SWIFTLY_HOME_DIR="$SWIFTLY_HOME" "$tmp/swiftly" init \
      --skip-install --no-modify-profile --quiet-shell-followup --assume-yes
    rm -rf "$tmp"
  fi

  # shellcheck disable=SC1091
  . "$SWIFTLY_HOME/env.sh"
  # Run from $HOME so swiftly's `--use` writes its `.swift-version` marker there
  # instead of polluting the checked-out repo working directory (/workspace).
  ( cd "$HOME" && swiftly install --use "$SWIFT_VERSION" )
}

# 1. Install the toolchain only when the exact version is missing (idempotent).
if [ ! -x "$TOOLCHAIN_BIN/swift" ]; then
  install_swift
else
  log "Swift $SWIFT_VERSION already installed — skipping download"
fi

# 2. Expose the toolchain on the default PATH for every agent shell (login,
#    non-login, and non-interactive) by symlinking the real toolchain binaries
#    into /usr/local/bin. This is how the official Swift images place `swift`.
log "Linking Swift $SWIFT_VERSION binaries into /usr/local/bin"
for bin in "$TOOLCHAIN_BIN"/*; do
  sudo ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"
done

# 3. Verify the toolchain and prepare SwiftPM. `swift package resolve` validates
#    that Package.swift parses under this toolchain (there are no dependencies).
#    A full `swift build` is intentionally NOT run here: it cannot succeed on
#    Linux for this macOS-only app.
log "Swift toolchain:"
swift --version
log "Resolving SwiftPM package"
swift package resolve

log "Done. Note: 'swift build' requires macOS (AppKit/Carbon/SkyLight)."
