#!/bin/bash
# Fail on any style or documentation violation.
#
# Sources are held to a stricter rule set than tests (see Sources/.swift-format):
# production code may not force-unwrap or force-try.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# swift-format's config decoder rejects keys it doesn't know, and reports that
# as "The data couldn't be read because it isn't in the correct format" once
# per source file. That is a useless way to learn your toolchain is too old, so
# check the version up front and say what's actually wrong.
REQUIRED_MAJOR=6
REQUIRED_MINOR=3

version="$(swift format --version 2>/dev/null || echo "0.0.0")"
major="${version%%.*}"
rest="${version#*.}"
minor="${rest%%.*}"

if [ "${major:-0}" -lt "$REQUIRED_MAJOR" ] ||
   { [ "${major:-0}" -eq "$REQUIRED_MAJOR" ] && [ "${minor:-0}" -lt "$REQUIRED_MINOR" ]; }; then
    cat >&2 <<MSG
error: swift-format $version is too old for this repository's configuration.

  Required: $REQUIRED_MAJOR.$REQUIRED_MINOR or newer (ships with Swift $REQUIRED_MAJOR.$REQUIRED_MINOR)
  Found:    $version  ($(swift --version 2>/dev/null | head -1))

.swift-format uses rules this version does not recognise, and swift-format
reports that as an unreadable configuration once per file rather than as a
version problem.

If this is a Sapling build node, its base image's Xcode is older than the
toolchain this repository targets. See docs/BASE-IMAGE.md.
MSG
    exit 1
fi

swift format lint --recursive --parallel --strict Sources Tests Package.swift
echo "lint clean"
