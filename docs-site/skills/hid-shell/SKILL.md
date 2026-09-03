---
name: hid-shell
description: "Use when installing, building, deploying, or troubleshooting HID-Shell — the headless cross-platform raw-HID shell payload for the Vandal ESP32 agent."
---

# HID-Shell

HID-Shell is a single-binary Nim payload. When a Vandal agent is plugged into a USB host it connects to the agent's vendor HID interface (usage page `0xFF00`, usage `0x01`), spawns a local OS shell, and pumps stdin/stdout over 64-byte raw HID reports until the agent sends `BYE`, the device is unplugged, or the process is killed.

## Getting started

In production HID-Shell is **not** invoked by hand — the Vandal agent's universal BadUSB launcher execs the right binary for the host. The manual invocation (for development/testing) is:

```sh
./hid_shell              # auto-detect the device, headless
./hid_shell --debug      # log each stage to stderr
```

### Options

| Option        | Meaning                                                        |
| ------------- | -------------------------------------------------------------- |
| `--debug`     | Log each stage to stderr (silent by design without this).     |
| `--once`      | Exit after the first shell session ends.                       |
| `--wait-ms N` | Wait up to N ms for the device (default `20000`).             |
| `--help`      | Print usage.                                                   |

Exit codes: `3` = no Vandal vendor HID found within the wait window; `2` = unknown option or unexpected argument.

## Common tasks

### Download a pre-built binary

GitHub Releases ship `hid_shell-linux-x86_64`, `hid_shell-macos-arm64`, `hid_shell-windows-x86_64.exe`, plus `SHA256SUMS`. Verify and rename to the short names the launcher expects:

```sh
sha256sum -c SHA256SUMS
mv hid_shell-linux-x86_64        sl
mv hid_shell-macos-arm64         sm
mv hid_shell-windows-x86_64.exe  sw.exe
```

### Build the three release binaries

Recommended — Docker cross-toolchain, nothing but Docker required:

```sh
./scripts/docker-build.sh            # build all three
./scripts/docker-build.sh shell      # interactive shell in the toolchain
./scripts/build_all.sh [linux|windows|macos|all]
```

Local host-native build (requires Nim ≥ 2.0 + system hidapi):

```sh
nimble buildRelease
```

### Host runtime dependencies

| Platform | Host runtime dependencies |
| -------- | ------------------------- |
| Linux x86_64   | `libudev` (systemd, universal), libc |
| macOS arm64    | `libhidapi.dylib` — `brew install hidapi` |
| Windows x86_64 | `setupapi.dll`, `hid.dll` (Windows built-ins) |

## Troubleshooting

- **Exit code 3 (no device found):** agent not plugged in, or the host hasn't enumerated it yet. Retry with a longer wait: `./hid_shell --wait-ms 30000 --debug`.
- **`open failed, skipping`** in the `--debug` log: usually a Linux permissions issue on the HID device node (udev rule).
- **Candidate probed but not confirmed:** the `(0xFF00, 0x01)` usage page is shared by many devices (RGB controllers, gaming dongles). HID-Shell only opens a candidate that answers a `HELLO` with a `HELLO_ACK`.
- **Windows read failing with `ERROR_INVALID_USER_BUFFER`:** the read buffer must be `FrameSize + 1` (65 bytes) — the HID class driver prepends a report-ID byte.
- **Windows commands not running / no echo:** lone `CR` from xterm.js must be translated to `CRLF` for `cmd.exe` over a pipe; HID-Shell does this in `writeBytes` and in the pump's input echo.

## Wire protocol (v1)

Every report is exactly 64 bytes. Frame layout:

```text
offset 0   : type   u8   0x10=CMD  0x11=OUT  0x12=CTRL
offset 1   : flags  u8   bit0=FIN  bit1=reserved  bit2..7=payload length (0..60)
offset 2-3 : seq    u16 LE
offset 4-63: payload (60 bytes max)
```

CTRL subtypes: `0x01` HELLO, `0x02` HELLO_ACK, `0x03` PING, `0x04` PONG, `0x05` CMD_ID, `0x06` BYE, `0x07` ERROR. OS IDs: `0x01` windows, `0x02` linux, `0x03` macos. `ProtoVersion = 0x0001`.

## Reference

- Source: https://github.com/circle-rd/hid-shell
- Documentation: https://docs.circle-cyber.com/hid-shell/
