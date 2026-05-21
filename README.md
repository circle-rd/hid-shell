# HID-Shell

Cross-platform raw-HID shell payload for the [Vandal](../Vandal) ESP32 agent.

Once launched on a host that has a Vandal device plugged in over USB, this
single binary:

1. Enumerates HID devices matching Vandal's VID/PID and the vendor usage
   page `0xFF00`.
2. Opens the vendor interface (instance 1 of the composite USB device).
3. Sends a `HELLO` and spawns a persistent OS shell (`cmd.exe` on Windows,
   `/bin/sh -i` elsewhere).
4. Pumps stdin/stdout bytes between the shell and the agent in 64-byte
   raw HID reports until the agent sends `BYE`, the USB device is
   unplugged, or the process is killed.

The wire protocol is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Download pre-built binaries

Each tagged [GitHub Release](../../releases) ships the three
cross-compiled payloads as assets, plus a `SHA256SUMS` manifest and a
generated `RELEASE_NOTES.md` describing the deployment procedure:

| Asset                              | Target              | Rename to (agent `/payloads/`) |
| ---------------------------------- | ------------------- | ------------------------------ |
| `hid_shell-linux-x86_64`           | Linux x86_64        | `sl`                           |
| `hid_shell-macos-arm64`            | macOS arm64         | `sm`                           |
| `hid_shell-windows-x86_64.exe`     | Windows x86_64      | `sw.exe`                       |

Verify and rename in one go:

```sh
sha256sum -c SHA256SUMS
mv hid_shell-linux-x86_64       sl
mv hid_shell-macos-arm64        sm
mv hid_shell-windows-x86_64.exe sw.exe
```

Then upload the three files to `/payloads/` on the Vandal agent via
the web UI (**BadUSB → File transfer**). One-time per agent — the
binaries persist on the FAT volume across reboots and the agent's
*Shell* page handles the rest (Prepare → Start).

## Build

### Recommended: Docker cross-toolchain

Produces all three release binaries from any machine with Docker
installed — no need to set up Nim, Zig, mingw, or hidapi locally:

```sh
./scripts/docker-build.sh
```

This builds the `hid-shell-builder` image (Debian + Nim 2.2.4 + Zig
0.13.0 + mingw-w64 + statically-compiled hidapi for Linux and Windows),
mounts the repo into the container, and runs `scripts/build_all.sh`.
Outputs land in `dist/`:

| Binary                          | Size  | Runtime dependencies on target |
| ------------------------------- | ----- | -------------------------------- |
| `hid_shell-linux-x86_64`        | ~96K  | `libudev` (systemd, universal), libc |
| `hid_shell-windows-x86_64.exe`  | ~134K | `setupapi.dll`, `hid.dll` (Windows built-ins) |
| `hid_shell-macos-arm64`         | ~135K | `libhidapi.dylib` — **requires `brew install hidapi` on the host** |

For an interactive shell inside the builder:

```sh
./scripts/docker-build.sh shell
```

### Local build

Requires Nim ≥ 2.0 with `nimble`, and the system `hidapi` library:

```sh
# Debian/Ubuntu
sudo apt install libhidapi-hidraw0
# Fedora
sudo dnf install hidapi
# macOS
brew install hidapi
# Windows: drop hidapi.dll next to the built .exe
#   (https://github.com/libusb/hidapi/releases)
```

Then build the host-native binary only:

```sh
nimble buildRelease
```

## Fully autonomous macOS binary (no Homebrew)

The default Docker build leaves the macOS binary linked against
`libhidapi.dylib` at runtime, because hidapi's macOS backend includes
`<IOKit/hid/IOHIDManager.h>` — a header from Apple's Xcode SDK which is
**not redistributable** and therefore cannot be baked into the public
Docker image.

If you need a macOS binary that runs on a vanilla user host (no Homebrew,
no hidapi package — the Starbucks-laptop scenario), build it on a
machine that already has the Apple SDK:

### Option A — Build on a real macOS host

On any Mac with Xcode Command Line Tools:

```sh
# One-time: install Nim and hidapi sources (any Mac toolchain works)
brew install nim
curl -fsSL https://github.com/libusb/hidapi/archive/refs/tags/hidapi-0.14.0.tar.gz \
    | tar -xz -C /tmp
cd /tmp/hidapi-hidapi-0.14.0
clang -c -O2 -arch arm64 -I hidapi mac/hid.c -o /tmp/hid-mac.o
ar rcs /tmp/libhidapi.a /tmp/hid-mac.o

# Build the static payload
cd /path/to/HID-Shell
nim c -d:release -d:strip -d:hidapiStatic \
    --opt:size --threads:on \
    --cpu:arm64 --os:macosx --cc:clang \
    --passL:"/tmp/libhidapi.a -framework IOKit -framework CoreFoundation -framework AppKit" \
    --out:dist/hid_shell-macos-arm64 src/hid_shell.nim
```

The resulting binary depends only on macOS system frameworks (always
present) and runs on any macOS ≥ 11 arm64 host with nothing installed.

### Option B — `osxcross` inside the Docker image

For fully reproducible CI, extend `Dockerfile` with
[osxcross](https://github.com/tpoechtrager/osxcross) and a manually
downloaded Xcode `MacOSX*.sdk.tar.xz` (Apple license forbids us from
distributing it). Once `o64-clang` is in PATH, the static build line
above works inside the container too. This is left out of the default
image deliberately — each developer must accept Apple's SDK license
themselves.

Native compilation per platform is otherwise preferred. Cross-compilation
works but each target needs the corresponding `hidapi` static library
available to the linker.

## Run manually

```sh
./hid_shell                # auto-detect device, headless
./hid_shell --debug        # log to stderr for development
```

In the standard deployment the binary is **not** invoked by hand: the
Vandal universal launcher
(`vandal-react/server/scripts/badusb/library/extensions/shell_launcher.txt`)
is injected as HID keystrokes by the agent, which then exec's the
matching `/payloads/sl|sm|sw.exe` silently (no terminal window on any
OS).

## Headless contract

- Windows: built with `--app:gui` so no console window is allocated.
- POSIX: the launcher uses `nohup` + `setsid`, and the payload itself
  does not write to stdout/stderr unless `--debug` is passed.
- All shell I/O travels over HID; nothing is written to disk.
