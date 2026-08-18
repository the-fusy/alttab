# AltTab Cloud Agent base image.
#
# IMPORTANT: AltTab is a macOS-only AppKit/Carbon app (it overrides the native
# macOS Cmd+Tab, drives the Accessibility API, and links the private SkyLight
# framework). It CANNOT be compiled or run on Linux — `swift build` fails with
# "no such module 'AppKit'". Cloud Agents run on Linux, so this image only
# provides the Swift 6.3.x toolchain for code navigation, editing, refactoring,
# `swift package` manifest tooling, and syntax checks. A real build/run still
# requires a macOS host with Xcode/Command Line Tools.
#
# Base: official Swift image on Ubuntu 24.04 (noble) — matches the repo's pinned
# Swift 6.3.x (see CLAUDE.md) and the Cloud Agent Ubuntu 24.04 host.
FROM swift:6.3.3-noble

# git + curl for SwiftPM and general tooling (skill: install git/curl in custom
# images). Ensure a non-root `ubuntu` user (uid 1000) exists to match the Cloud
# Agent default runtime user, creating it only if the base image lacks it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && (id -u ubuntu >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --uid 1000 ubuntu)

USER ubuntu
