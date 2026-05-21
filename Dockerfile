# syntax=docker/dockerfile:1.6
#
# HID-Shell cross-compilation toolchain.
#
# Bundles everything needed to produce the three release binaries used
# by the Vandal universal launcher (extensions/shell_launcher.txt):
#
#   - hid_shell-linux-x86_64        (native gcc + libhidapi-hidraw.a)
#   - hid_shell-windows-x86_64.exe  (mingw-w64    + libhidapi.a, static C runtime)
#   - hid_shell-macos-arm64         (zig cc       + dynlib hidapi at runtime)
#
# hidapi is statically linked into the Linux and Windows binaries so
# those targets need NO user-installed hidapi package. macOS is an
# exception: hidapi's mac backend requires Apple's proprietary IOKit
# SDK headers which cannot legally be redistributed, so the macOS
# binary keeps the runtime-dlopen path and the target host needs
# `brew install hidapi`. See README.md "Fully autonomous macOS binary"
# for the opt-in process to build a static macOS binary on a real Mac.
#
# Remaining runtime deps on the END-USER host:
#
#   - Linux:   libudev (part of systemd — universal on modern desktops)
#   - Windows: setupapi.dll, hid.dll (system DLLs, always present)
#   - macOS:   libhidapi.dylib via Homebrew + IOKit/CoreFoundation (system)
#
# Usage:
#
#   docker build --target toolchain -t hid-shell-toolchain .
#   docker run --rm -v "$PWD":/workspace -w /workspace \
#       hid-shell-toolchain ./scripts/build_all.sh
#
# `./scripts/docker-build.sh` wraps that for local development. The
# binaries themselves are published as assets on the GitHub Release
# page by .github/workflows/publish-binaries.yml — that workflow only
# uses the `toolchain` stage below.
#

# =============================================================================
# Toolchain (Nim + Zig + mingw + hidapi static archives)
# =============================================================================
FROM ubuntu:26.04 AS toolchain

ARG HIDAPI_VERSION=0.14.0

ENV DEBIAN_FRONTEND=noninteractive \
    HIDAPI_PREFIX=/opt/hidapi

# ---- Toolchain (all from apt on Ubuntu 26.04) -------------------------------
# - nim (2.2.4):                 Nim compiler + nimble
# - zig0.14 (0.14.1):            used as the macOS arm64 cross-clang via
#                                `zig cc -target aarch64-macos-none`
# - gcc-mingw-w64-x86-64:        Windows x86_64 cross compiler
# - build-essential / libc6-dev: native Linux gcc + linker
# - libudev-dev:                 headers needed to build hidapi-hidraw
# - curl / ca-certificates:      fetch the hidapi source tarball
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        build-essential \
        gcc-mingw-w64-x86-64 \
        libudev-dev \
        nim \
        zig0.14 \
    && rm -rf /var/lib/apt/lists/* \
    && nim --version | head -1 \
    && zig0.14 version

# ---- zigcc shim for macOS arm64 --------------------------------------------
# Ubuntu's zig0.14 package installs the binary as `zig0.14` (not `zig`),
# so we wrap it once with the macOS target baked in.
RUN printf '#!/bin/sh\nexec /usr/bin/zig0.14 cc -target aarch64-macos-none "$@"\n' \
        > /usr/local/bin/zigcc-macos-arm64 \
    && chmod +x /usr/local/bin/zigcc-macos-arm64

# ---- hidapi static libraries (Linux + Windows only) ------------------------
# Each backend is a single self-contained .c file plus the shared header.
# We compile to .o then archive with the matching `ar` so Nim's link
# step can pull the static lib via --passL.
#
# macOS is intentionally NOT built statically: hidapi's mac backend
# includes <IOKit/hid/IOHIDManager.h>, which lives in Apple's Xcode SDK
# (not redistributable). The macOS binary therefore uses Nim's `dynlib`
# fallback in src/hidapi_ffi.nim and requires `brew install hidapi` on
# the target host.
RUN set -eux; \
    curl -fsSL "https://github.com/libusb/hidapi/archive/refs/tags/hidapi-${HIDAPI_VERSION}.tar.gz" \
        | tar -xz -C /tmp; \
    SRC=/tmp/hidapi-hidapi-${HIDAPI_VERSION}; \
    mkdir -p ${HIDAPI_PREFIX}/include ${HIDAPI_PREFIX}/linux ${HIDAPI_PREFIX}/windows; \
    cp ${SRC}/hidapi/hidapi.h ${HIDAPI_PREFIX}/include/; \
    \
    echo "==> hidapi linux (hidraw backend)"; \
    gcc -c -O2 -fPIC -I${SRC}/hidapi ${SRC}/linux/hid.c -o /tmp/hid-linux.o; \
    ar rcs ${HIDAPI_PREFIX}/linux/libhidapi-hidraw.a /tmp/hid-linux.o; \
    \
    echo "==> hidapi windows (win32 backend, mingw)"; \
    x86_64-w64-mingw32-gcc -c -O2 -I${SRC}/hidapi ${SRC}/windows/hid.c -o /tmp/hid-windows.o; \
    x86_64-w64-mingw32-ar rcs ${HIDAPI_PREFIX}/windows/libhidapi.a /tmp/hid-windows.o; \
    \
    rm -rf ${SRC} /tmp/hid-*.o; \
    ls -lR ${HIDAPI_PREFIX}

# ---- Workspace --------------------------------------------------------------
WORKDIR /workspace

CMD ["bash"]
