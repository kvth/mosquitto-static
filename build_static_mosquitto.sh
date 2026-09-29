#!/usr/bin/env bash
#
# Build a fully static mosquitto for <arch> with podman, as described by the
# Containerfile (layers are cached, so repeat builds are fast). A build for a
# non-native arch runs under QEMU, which a rootless podman cannot register
# itself -- on Debian/Ubuntu: sudo apt install qemu-user-static binfmt-support
#
#   ./build_static_mosquitto.sh <amd64|arm64> [out_dir]  # default: build_<arch>

set -euo pipefail

cd "$(dirname "$0")"

ARCH=${1:?usage: $0 <amd64|arm64> [out_dir]}
OUT_DIR=${2:-build_$ARCH}

podman build --platform "linux/$ARCH" --target out --output "type=local,dest=$OUT_DIR" . || {
    echo "error: build failed. If it could not run $ARCH containers -- no QEMU binfmt" >&2
    echo "       handler registered -- install one, e.g. sudo apt install qemu-user-static binfmt-support" >&2
    exit 1
}

file "$OUT_DIR/mosquitto"
