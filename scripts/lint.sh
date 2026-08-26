#!/bin/bash
# Fail on any style or documentation violation.
#
# Sources are held to a stricter rule set than tests (see Sources/.swift-format):
# production code may not force-unwrap or force-try.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift format lint --recursive --parallel --strict Sources Tests Package.swift
echo "lint clean"
