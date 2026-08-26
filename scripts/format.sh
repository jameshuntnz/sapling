#!/bin/bash
# Format all Swift sources in place, using swift-format from the toolchain.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift format --in-place --recursive --parallel Sources Tests Package.swift
echo "formatted"
