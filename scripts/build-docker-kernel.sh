#!/bin/bash
# Copyright 2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# build-docker-kernel.sh
# Build a Docker-capable guest kernel from the Firecracker Amazon Linux kernel source
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$FC_ROOT/resources/guest_configs"
KERNEL_SRC="${KERNEL_SRC:-$FC_ROOT/resources/linux}"
OUTPUT_DIR="${OUTPUT_DIR:-$FC_ROOT/resources/x86_64}"
KERNEL_VERSION="${KERNEL_VERSION:-6.1}"
JOBS="${JOBS:-$(nproc)}"

info()  { printf '[info] %s\n' "$*"; }
error() { printf '[error] %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"; }
need_cmd make
need_cmd gcc

if [ "$(uname -m)" != "x86_64" ]; then
    error "Docker kernel build is only supported on x86_64"
fi

# 1. Clone kernel source
if [ ! -d "$KERNEL_SRC" ]; then
    info "Cloning Amazon Linux kernel source..."
    git clone --no-checkout --filter=tree:0 \
        https://github.com/amazonlinux/linux "$KERNEL_SRC"
fi

cd "$KERNEL_SRC"

# 2. Select tag
TAG=$(git --no-pager tag -l --sort=-v:refname \
    | grep "microvm-kernel-$KERNEL_VERSION\..*\.amzn2" \
    | head -n1)
[ -z "$TAG" ] && error "No tag found for kernel version $KERNEL_VERSION"
info "Using kernel tag: $TAG"

make distclean || true
git checkout "$TAG"
git checkout -B "docker-$TAG"

# 3. Concatenate configs
info "Concatenating kernel configs: base + ci + docker"
cat \
    "$CONFIG_DIR/microvm-kernel-ci-x86_64-$KERNEL_VERSION.config" \
    "$CONFIG_DIR/ci.config" \
    "$CONFIG_DIR/docker.config" \
    > .config

# 4. Build
info "Starting kernel build (jobs=$JOBS)..."
make olddefconfig
make -j"$JOBS" vmlinux

# 5. Output
LATEST_VERSION=$(cat include/config/kernel.release)
normalized_version=$(echo "$LATEST_VERSION" | sed -E "s/(.*[[:digit:]]).*/\1/g")
OUTPUT_FILE="$OUTPUT_DIR/vmlinux-${normalized_version}-docker"
mkdir -p "$OUTPUT_DIR"
cp -v vmlinux "$OUTPUT_FILE"
cp -v .config "$OUTPUT_FILE.config"

info "Kernel build complete: $OUTPUT_FILE"
info "Size: $(du -sh "$OUTPUT_FILE" | cut -f1)"

# Cleanup
git reset --hard HEAD
git clean -f -d
git checkout -
