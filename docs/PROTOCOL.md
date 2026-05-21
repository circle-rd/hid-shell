# HID-Shell wire protocol (v1)

This document is the authoritative reference for the raw-HID channel
between the Vandal agent (ESP32 firmware) and the HID-Shell payload
running on the USB host. Both sides MUST implement v1 exactly as
described; the agent rejects `HELLO` with a mismatched major version.

## Transport

- USB composite device: Keyboard (IF0) + MSC (IF1) + **Vendor HID (IF2)**.
- Vendor HID descriptor: `TUD_HID_REPORT_DESC_GENERIC_INOUT(64)`,
  usage page `0xFF00`, usage `0x01`. No report ID.
- Every report — both IN (agent → host) and OUT (host → agent) — is
  exactly **64 bytes**. Padding bytes MUST be zero.

## Frame format

```
offset 0  : type   u8       0x10 = CMD   (agent → host)
                            0x11 = OUT   (host → agent)
                            0x12 = CTRL  (bidirectional)
offset 1  : flags  u8       bit0 = FIN (last fragment of a logical message)
                            bit1..7 reserved, must be 0
offset 2-3: seq    u16 LE   per-sender, wraps; debug / dedupe only
offset 4-63       : 60 bytes of payload
```

`CMD` and `OUT` payloads are raw bytes (typically UTF-8). A logical
message may span several frames; only the frame with `FIN = 1` ends it.

## CTRL frames

`CTRL` frames always have `FIN = 1`. Layout of the 60-byte payload:

```
payload[0] : subtype
payload[1..] : subtype-specific
```

| Subtype | Direction       | Payload after subtype byte                                  |
| ------- | --------------- | ----------------------------------------------------------- |
| `0x01 HELLO`       | host → agent | `u16 LE proto_version`, `u8 os_id`, optional zero-padded version string |
| `0x02 HELLO_ACK`   | agent → host | `u16 LE agent_proto_version`                                |
| `0x03 PING`        | either       | empty                                                       |
| `0x04 PONG`        | either       | empty                                                       |
| `0x05 CMD_ID`      | agent → host | null-terminated UTF-8 (≤ 58 B). Tags subsequent OUT chunks. |
| `0x06 BYE`         | either       | empty                                                       |
| `0x07 ERROR`       | host → agent | `u8 code`, UTF-8 message                                    |

### OS IDs

`0x01 = windows`, `0x02 = linux`, `0x03 = macos`. Other values reserved.

### Versioning

Current version: `0x0001`. The agent rejects `HELLO` whose **high byte**
(major) differs from its own, replying with an `ERROR` and publishing an
MQTT shell error event.

## Lifecycle

```
host: open vendor HID interface
host -> agent: CTRL HELLO
agent -> host: CTRL HELLO_ACK
agent: publishes {topic:"shell", type:"connected"} on MQTT

# operator types a command in the web UI
agent -> host: CTRL CMD_ID  ("c-42")
agent -> host: CMD frames    ("uname -a\n", FIN on last)
host: writes the bytes to the child shell stdin

host -> agent: OUT frames    ("Linux …\n", FIN when flushed)
agent: publishes {topic:"shell", type:"output", cmd_id:"c-42", chunk, final}

…

agent -> host: CTRL BYE   (operator clicked Stop)
host: closes child shell, exits
```

## Flow control

- The host MUST honour HID polling intervals — it cannot send faster
  than the endpoint allows. The agent calls `tud_hid_n_ready(1)` before
  every TX and waits up to 1 s.
- The agent's RX is a `StreamBuffer` of 4 KB. If full, OUT frames are
  dropped and a warning is logged. The host SHOULD therefore flush on
  newlines or 60-byte boundaries, and SHOULD NOT spam empty output.

## Sequence numbers

Both sides maintain an independent `u16` counter, incremented per frame
and wrapping at `0xFFFF`. The receiver uses it only for diagnostic
logging; out-of-order frames are not expected on a USB endpoint and are
not handled.
