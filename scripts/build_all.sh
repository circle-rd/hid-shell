#!/usr/bin/env bash
# Build all three release binaries used by the Vandal universal launcher
# (server/scripts/badusb/library/extensions/shell_launcher.txt).
#
# Recommended: run inside the project Dockerfile, which ships the cross
# compilers AND prebuilt static hidapi archives:
#
#     ./scripts/docker-build.sh
#
# Override toolchain paths via env if running bare metal:
#
#   WIN_CC          Windows C compiler  (default: x86_64-w64-mingw32-gcc)
#   MAC_CC          macOS C compiler    (default: zigcc-macos-arm64)
#   HIDAPI_PREFIX   prefix containing   include/ linux/ windows/ macos/
#                                       (default: /opt/hidapi, populated
#                                        by the project Dockerfile)
#
# hidapi is STATICALLY linked into the Linux and Windows binaries so
# those targets need nothing user-installed. The macOS binary uses the
# runtime-dlopen fallback (Nim `dynlib`) because hidapi's mac backend
# needs Apple's IOKit SDK headers which can't be redistributed; macOS
# targets therefore need `brew install hidapi`.
#
# Per-target runtime deps:
#   - Linux:   libudev (systemd — universally present)
#   - macOS:   libhidapi.dylib (brew) + IOKit/CoreFoundation system
#   - Windows: setupapi.dll / hid.dll (system DLLs)

set -euo pipefail

: "${WIN_CC:=x86_64-w64-mingw32-gcc}"
: "${MAC_CC:=zigcc-macos-arm64}"
: "${HIDAPI_PREFIX:=/opt/hidapi}"

TARGET="${1:-all}"

mkdir -p dist

build_linux() {
  echo "==> linux/x86_64 (native gcc + static hidapi-hidraw)"
  nim c -d:release -d:strip -d:hidapiStatic --opt:size --threads:on \
    --passL:"${HIDAPI_PREFIX}/linux/libhidapi-hidraw.a -ludev -lpthread" \
    --out:dist/hid_shell-linux-x86_64 src/hid_shell.nim
}

build_windows() {
  echo "==> windows/x86_64 (mingw-w64 + static hidapi, static C runtime)"
  nim c -d:release -d:strip -d:hidapiStatic -d:mingw --opt:size --threads:on \
    --cpu:amd64 --os:windows --app:gui \
    --cc:gcc \
    --gcc.exe:"$WIN_CC" \
    --gcc.linkerexe:"$WIN_CC" \
    --passL:"${HIDAPI_PREFIX}/windows/libhidapi.a -lsetupapi -lhid -static -static-libgcc" \
    --out:dist/hid_shell-windows-x86_64.exe src/hid_shell.nim
}

# -d:strip intentionally OFF for macOS — Apple ld rejects the `-s` flag
# Nim would pass; --opt:size already keeps the binary small.
# -d:hidapiStatic intentionally OFF for macOS — hidapi's mac backend
# needs Apple SDK headers we can't ship, so the dynlib fallback is
# used. The binary itself has zero link-time hidapi reference.
build_macos() {
  echo "==> macos/arm64 (zig cc, hidapi via dlopen at runtime)"
  nim c -d:release --opt:size --threads:on \
    --cpu:arm64 --os:macosx \
    --cc:clang \
    --clang.exe:"$MAC_CC" \
    --clang.linkerexe:"$MAC_CC" \
    --out:dist/hid_shell-macos-arm64 src/hid_shell.nim
}

case "$TARGET" in
  linux)   build_linux ;;
  windows) build_windows ;;
  macos)   build_macos ;;
  all)     build_linux; build_windows; build_macos ;;
  *) echo "Usage: $0 [linux|windows|macos|all]" >&2; exit 2 ;;
esac

echo "Done. Artefacts in dist/"
ls -lh dist/
