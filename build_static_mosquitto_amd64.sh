#!/usr/bin/env bash
#
# Build a fully static mosquitto broker binary (musl libc, static OpenSSL)
# inside an Alpine container. No local toolchain needed, just docker.
#
#   ./build_static_mosquitto_amd64.sh            # writes ./build_amd64/mosquitto
#   ./build_static_mosquitto_amd64.sh /some/dir  # writes /some/dir/mosquitto

set -euo pipefail

cd "$(dirname "$0")"

MOSQUITTO_VERSION=2.1.2
MIMALLOC_VERSION=v3.5.0
ALPINE_IMAGE=alpine:3.20
OUT_DIR=${1:-build_amd64}

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

echo ">> building mosquitto $MOSQUITTO_VERSION (static, musl, mimalloc) via $ALPINE_IMAGE"

docker run --rm \
    -e MOSQUITTO_VERSION="$MOSQUITTO_VERSION" \
    -e MIMALLOC_VERSION="$MIMALLOC_VERSION" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$OUT_DIR:/out" \
    "$ALPINE_IMAGE" sh -eu -c '
        apk add --no-cache \
            build-base cmake linux-headers wget ca-certificates git \
            openssl-dev openssl-libs-static zlib-static cjson-dev >/dev/null

        # mimalloc replaces the (musl) allocator via its malloc/free/... override
        # symbols, which only win the link if the archive is force-included with
        # --whole-archive.
        git -c advice.detachedHead=false clone --depth 1 --branch "$MIMALLOC_VERSION" \
            https://github.com/microsoft/mimalloc.git
        cmake -B mimalloc/build -S mimalloc \
            -DCMAKE_BUILD_TYPE=Release \
            -DMI_BUILD_SHARED=OFF \
            -DMI_BUILD_TESTS=OFF \
            -DCMAKE_C_FLAGS="-static" \
            >/dev/null
        cmake --build mimalloc/build -j"$(nproc)" >/dev/null
        MIMALLOC_LIB="$(pwd)/mimalloc/build/libmimalloc.a"

        wget -q "https://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz"
        tar xzf "mosquitto-${MOSQUITTO_VERSION}.tar.gz"
        cd "mosquitto-${MOSQUITTO_VERSION}"

        cmake -B build \
            -DCMAKE_C_FLAGS="-static" \
            -DCMAKE_EXE_LINKER_FLAGS="-static -Wl,--whole-archive,$MIMALLOC_LIB,--no-whole-archive" \
            -DOPENSSL_USE_STATIC_LIBS=TRUE \
            -DCJSON_LIBRARY=/usr/lib/libcjson.a \
            -DCJSON_INCLUDE_DIR=/usr/include \
            -DWITH_WEBSOCKETS=OFF \
            -DWITH_PLUGIN_PERSIST_SQLITE=OFF \
            -DWITH_DOCS=OFF \
            -DWITH_TESTS=OFF \
            >/dev/null

        cmake --build build --target mosquitto -j"$(nproc)" >/dev/null

        strip build/src/mosquitto
        cp build/src/mosquitto /out/mosquitto

        # container runs as root, so /out would otherwise end up root-owned
        # on the host; hand it back to the invoking user.
        chown "$HOST_UID:$HOST_GID" /out/mosquitto
    '

echo ">> wrote $OUT_DIR/mosquitto"
file "$OUT_DIR/mosquitto"
