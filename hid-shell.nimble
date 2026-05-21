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

task buildLinux, "Build the Linux x86_64 binary":
  exec "nim c -d:release -d:strip --opt:size --threads:on " &
       "--out:hid_shell-linux-x86_64 src/hid_shell.nim"

task buildWindows, "Build the Windows x86_64 binary (mingw cross)":
  exec "nim c -d:release -d:strip --opt:size --threads:on " &
       "--cpu:amd64 --os:windows --app:gui " &
       "--out:hid_shell-windows-x86_64.exe src/hid_shell.nim"

task buildMacos, "Build the macOS arm64 binary (cross)":
  exec "nim c -d:release -d:strip --opt:size --threads:on " &
       "--cpu:arm64 --os:macosx " &
       "--out:hid_shell-macos-arm64 src/hid_shell.nim"
