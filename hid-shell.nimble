# Package

version       = "0.1.0"
author        = "Vandal"
description   = "Headless raw-HID shell payload for the Vandal agent"
license       = "MIT"
srcDir        = "src"
bin           = @["hid_shell"]

# Dependencies

requires "nim >= 2.0.0"
# Runtime dep: system hidapi library
# - Debian/Ubuntu: sudo apt install libhidapi-hidraw0
# - Fedora:        sudo dnf install hidapi
# - macOS:         brew install hidapi
# - Windows:       ship hidapi.dll next to the .exe

# Tasks

task buildRelease, "Build a stripped release binary for the current host":
  exec "nim c -d:release -d:strip --opt:size --threads:on " &
       "--app:gui --out:hid_shell src/hid_shell.nim"

task buildLinux, "Build the Linux x86_64 binary (size-optimised)":
  # Mirrors scripts/build_all.sh build_linux().
  exec "nim c -d:release -d:strip --opt:size --threads:on " &
       "--mm:orc " &
       "--stackTrace:off --lineTrace:off --lineDir:off " &
       "--passC:\"-Os -ffunction-sections -fdata-sections " &
         "-fno-unwind-tables -fno-asynchronous-unwind-tables " &
         "-fno-ident -fmerge-all-constants\" " &
       "--passL:\"-Wl,--gc-sections -Wl,--build-id=none -Wl,-s\" " &
       "--out:hid_shell-linux-x86_64 src/hid_shell.nim"

task buildWindows, "Build the Windows x86_64 binary (mingw cross, size-optimised)":
  # Mirrors scripts/build_all.sh build_windows() — see that file for the
  # rationale behind every flag. Net effect: roughly half the .exe size
  # of a plain `-d:release` build while keeping unhandled-exception
  # MessageBox diagnostics intact.
  exec "nim c -d:release -d:strip --opt:size --threads:on " &
       "--mm:orc " &
       "--stackTrace:off --lineTrace:off --lineDir:off " &
       "--cpu:amd64 --os:windows --app:gui " &
       "--passC:\"-Os -ffunction-sections -fdata-sections " &
         "-fno-unwind-tables -fno-asynchronous-unwind-tables " &
         "-fno-ident -fmerge-all-constants\" " &
       "--passL:\"-Wl,--gc-sections -Wl,--build-id=none " &
         "-Wl,--no-insert-timestamp\" " &
       "--out:hid_shell-windows-x86_64.exe src/hid_shell.nim"

task buildMacos, "Build the macOS arm64 binary (cross, size-optimised)":
  # Mirrors scripts/build_all.sh build_macos(). -mcpu=apple-m1 pins the
  # AArch64 feature set to silence zig 0.14's spurious SVE warnings.
  # -d:strip is intentionally omitted: Apple ld rejects `-s`.
  exec "nim c -d:release --opt:size --threads:on " &
       "--mm:orc " &
       "--stackTrace:off --lineTrace:off --lineDir:off " &
       "--cpu:arm64 --os:macosx " &
       "--passC:\"-Os -mcpu=apple-m1 -ffunction-sections -fdata-sections " &
         "-fno-unwind-tables -fno-asynchronous-unwind-tables " &
         "-fno-ident -fmerge-all-constants\" " &
       "--passL:\"-mcpu=apple_m1 -Wl,-dead_strip\" " &
       "--out:hid_shell-macos-arm64 src/hid_shell.nim"
