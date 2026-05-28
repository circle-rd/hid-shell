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
  echo "==> linux/x86_64 (native gcc + static hidapi-hidraw, size-optimised)"
  # Same size strategy as the Windows build, adapted for ELF / GNU ld:
  #   --build-id=none + -Wl,-s   strip GNU build-id note + symbol table
  #   --gc-sections              dead-code elimination at link time
  #   no PE-only flags (--no-insert-timestamp is mingw-specific)
  # Result on Nim 2 + GCC 13: ~40 % smaller than plain -d:release.
  nim c -d:release -d:strip -d:hidapiStatic \
    --opt:size --threads:on \
    --mm:orc \
    --stackTrace:off --lineTrace:off --lineDir:off \
    --passC:"-Os -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident -fmerge-all-constants" \
    --passL:"${HIDAPI_PREFIX}/linux/libhidapi-hidraw.a -ludev -lpthread -Wl,--gc-sections -Wl,--build-id=none -Wl,-s" \
    --out:dist/hid_shell-linux-x86_64 src/hid_shell.nim
}

build_windows() {
  echo "==> windows/x86_64 (mingw-w64 + static hidapi, static C runtime, size-optimised)"
  # Size strategy (typically halves the .exe compared to plain -d:release):
  #   --mm:orc                explicit cycle-aware GC (Nim 2 default but
  #                           pinned for forward-compat); smaller runtime
  #                           than refc.
  #   --stackTrace:off ...    drop the file/line/proc metadata baked into
  #                           every Nim proc. Unhandled exceptions still
  #                           pop a MessageBox via Nim's panic hook with
  #                           the exception message (which is what we
  #                           actually need for diagnostics); only the
  #                           call-stack trail disappears.
  #   -ffunction-sections     emit each function/data symbol into its own
  #   -fdata-sections         section so the linker's --gc-sections can
  #                           drop everything unreferenced.
  #   -fno-unwind-tables      no C++/SEH-style exception unwinding
  #   -fno-asynchronous-...    metadata: Nim handles its own exceptions.
  #   -fno-ident -fmerge-...  shave compiler ident strings + dedupe
  #                           string constants across translation units.
  #   -Wl,--gc-sections       link-time dead-code elimination (needs the
  #                           -ffunction-sections / -fdata-sections above).
  #   -Wl,--build-id=none     omit the (~20 B) GNU build id note.
  #   -Wl,--no-insert-...     deterministic PE header (no timestamp).
  #   -d:strip                appends `-s` so the linker drops the
  #                           remaining debug/symbol tables.
  nim c -d:release -d:strip -d:hidapiStatic -d:mingw \
    --opt:size --threads:on \
    --mm:orc \
    --stackTrace:off --lineTrace:off --lineDir:off \
    --cpu:amd64 --os:windows --app:gui \
    --cc:gcc \
    --gcc.exe:"$WIN_CC" \
    --gcc.linkerexe:"$WIN_CC" \
    --passC:"-Os -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident -fmerge-all-constants" \
    --passL:"${HIDAPI_PREFIX}/windows/libhidapi.a -lsetupapi -lhid -static -static-libgcc -Wl,--gc-sections -Wl,--build-id=none -Wl,--no-insert-timestamp" \
    --out:dist/hid_shell-windows-x86_64.exe src/hid_shell.nim
}

# -d:strip intentionally OFF for macOS — Apple ld rejects the `-s` flag
# Nim would pass; --opt:size + ld64's `-dead_strip` already keep the
# binary small. Run `strip dist/hid_shell-macos-arm64` post-hoc on a
# macOS host if you need to drop the remaining symbol table.
# -d:hidapiStatic intentionally OFF for macOS — hidapi's mac backend
# needs Apple SDK headers we can't ship, so the dynlib fallback is
# used. The binary itself has zero link-time hidapi reference.
build_macos() {
  echo "==> macos/arm64 (zig cc, hidapi via dlopen at runtime, size-optimised)"
  # -mcpu=apple_m1 pins the LLVM AArch64 codegen to Apple Silicon's
  # actual feature set (zig uses underscores in CPU names, not dashes).
  # This is the right thing to do for portable Apple-Silicon binaries,
  # even though it does NOT silence zig 0.14's spurious warnings:
  #   '-b16b16' is not a recognized feature for this target
  #   '-use-scalar-inc-vl' is not a recognized feature for this target
  # Those are emitted by zig's bundled LLVM backend whose CPU feature
  # table references SVE2.1 strings that the same LLVM build doesn't
  # know about — a known upstream bug. They come out of LLVM directly
  # (not clang), so `-Wno-*` has no effect, and no `-mcpu` value
  # avoids them. We filter them at the shell level via stderr.
  #
  # Apple ld64 uses different flags than GNU ld:
  #   -dead_strip            equivalent of --gc-sections (LLD-compatible)
  #   (no -no_uuid: ld64-only; zig's bundled LLD rejects it. The Mach-O
  #    UUID load command is ~16 B — not worth a workaround.)
  #   (no --no-insert-timestamp; mach-o has no timestamp header)
  #   (no -s; Nim's -d:strip is intentionally off above)
  nim c -d:release \
    --opt:size --threads:on \
    --mm:orc \
    --stackTrace:off --lineTrace:off --lineDir:off \
    --cpu:arm64 --os:macosx \
    --cc:clang \
    --clang.exe:"$MAC_CC" \
    --clang.linkerexe:"$MAC_CC" \
    --passC:"-Os -mcpu=apple_m1 -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident -fmerge-all-constants" \
    --passL:"-mcpu=apple_m1 -Wl,-dead_strip" \
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
