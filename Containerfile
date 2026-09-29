# Static mosquitto broker (musl libc, static OpenSSL, mimalloc), built in
# Alpine. Versions are the ARG defaults below (override with --build-arg).
# Driven by build_static_mosquitto.sh, which picks the platform and exports the
# "out" stage; it can also be used directly:
#
#   podman build --platform linux/arm64 --target out --output type=local,dest=build_arm64 .
#
# Stages are ordered from least to most frequently changing so podman's layer
# cache is reused: bumping MOSQUITTO_VERSION does not redo the apk install or
# the mimalloc build, and a rebuild with unchanged args does nothing.

# Defaults, overridable with --build-arg. Declared before FROM they are only
# visible to FROM lines, so each is redeclared (without a value) in the stage
# right before the step that uses it: that keeps a version bump from
# invalidating the cached layers above it.
ARG ALPINE_IMAGE=docker.io/library/alpine:3.20
ARG MIMALLOC_VERSION=v3.5.0
ARG MOSQUITTO_VERSION=2.1.2

FROM ${ALPINE_IMAGE} AS build

RUN apk add --no-cache \
        build-base cmake linux-headers wget ca-certificates git \
        openssl-dev openssl-libs-static zlib-static cjson-dev

# mimalloc replaces the (musl) allocator via its malloc/free/... override
# symbols, which only win the link if the archive is force-included with
# --whole-archive. MI_NO_OPT_ARCH keeps mimalloc off -march= tuning: on arm64 it
# would otherwise default to -march=armv8.3-a, which crashes with SIGILL on
# older cores (e.g. Raspberry Pi 3/4), and we want a binary that runs anywhere.
ARG MIMALLOC_VERSION
RUN git -c advice.detachedHead=false clone --depth 1 --branch "$MIMALLOC_VERSION" \
        https://github.com/microsoft/mimalloc.git \
    && cmake -B mimalloc/build -S mimalloc \
        -DCMAKE_BUILD_TYPE=Release \
        -DMI_BUILD_SHARED=OFF \
        -DMI_BUILD_TESTS=OFF \
        -DMI_NO_OPT_ARCH=ON \
        -DCMAKE_C_FLAGS="-static" \
    && cmake --build mimalloc/build -j"$(nproc)"

ARG MOSQUITTO_VERSION
RUN wget -q "https://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz" \
    && tar xzf "mosquitto-${MOSQUITTO_VERSION}.tar.gz" \
    && mv "mosquitto-${MOSQUITTO_VERSION}" mosquitto

RUN cd mosquitto \
    && cmake -B build \
        -DCMAKE_C_FLAGS="-static" \
        -DCMAKE_EXE_LINKER_FLAGS="-static -Wl,--whole-archive,/mimalloc/build/libmimalloc.a,--no-whole-archive" \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DCJSON_LIBRARY=/usr/lib/libcjson.a \
        -DCJSON_INCLUDE_DIR=/usr/include \
        -DWITH_WEBSOCKETS=OFF \
        -DWITH_PLUGIN_PERSIST_SQLITE=OFF \
        -DWITH_DOCS=OFF \
        -DWITH_TESTS=OFF \
    && cmake --build build --target mosquitto -j"$(nproc)" \
    && strip build/src/mosquitto

# Only the binary is exported; --output type=local writes it as <dest>/mosquitto,
# owned by the invoking user under rootless podman.
FROM scratch AS out
COPY --from=build /mosquitto/build/src/mosquitto /mosquitto
