---
title: HID-Shell
description: Headless cross-platform raw-HID shell payload for the Vandal ESP32 agent.
---

:::u-page-hero
#title
HID-Shell

#description
A headless shell payload that rides the Vandal agent's vendor HID interface. It spawns a local OS shell and pumps stdin/stdout over 64-byte raw HID reports — no network path, no console window on the host, nothing written to disk.

#links
::::u-button{to="/hid-shell/docs/getting-started/1.introduction" trailing-icon="i-lucide-book-open"}
Getting started
::::

::::u-button{to="https://github.com/circle-rd/hid-shell" target="_blank" variant="outline" icon="i-simple-icons-github"}
GitHub
::::
:::

:::u-page-section
#title
Core concepts

#description
Everything you need to understand what HID-Shell does and how it moves bytes.

#features
::::u-page-feature{icon="i-lucide-plug" title="Raw-HID transport" description="Speaks the Vandal vendor HID interface (usage page 0xFF00) with 64-byte reports — no TCP, UDP, or any other network protocol on the host." to="/hid-shell/docs/protocol/1.wire-protocol"}
::::
::::u-page-feature{icon="i-lucide-terminal" title="Headless shell bridge" description="Spawns cmd.exe (Windows, hidden console) or an interactive /bin/sh on a PTY (POSIX) and streams bytes both ways until the agent sends BYE." to="/hid-shell/docs/architecture/2.shell-spawning"}
::::
::::u-page-feature{icon="i-lucide-crosshair" title="Device disambiguation" description="Probes every vendor-page HID device with a HELLO/HELLO_ACK exchange so it opens the real Vandal agent, not an RGB controller or gaming dongle." to="/hid-shell/docs/architecture/1.device-detection"}
::::
::::u-page-feature{icon="i-lucide-arrows-left-right" title="Single-threaded pump" description="An event loop that alternates short non-blocking reads from the HID link and the child shell, fragments output into frames, and pings for liveness." to="/hid-shell/docs/architecture/3.pump"}
::::
:::

:::u-page-section
#title
Reference

#description
Authoritative reference derived directly from the source tree.

#features
::::u-page-feature{icon="i-lucide-file-code" title="Wire protocol" description="Frame layout, CTRL subtypes, OS identifiers, versioning, lifecycle, flow control and sequence numbers." to="/hid-shell/docs/protocol/1.wire-protocol"}
::::
::::u-page-feature{icon="i-lucide-braces" title="API reference" description="Every exported procedure, type and constant across protocol, transport_hid, shell_child and pump." to="/hid-shell/docs/api-reference/1.protocol"}
::::
::::u-page-feature{icon="i-lucide-hammer" title="Building" description="Docker cross-toolchain, local Nim builds, and the opt-in fully-static macOS binary." to="/hid-shell/docs/guides/1.building"}
::::
::::u-page-feature{icon="i-lucide-rocket" title="Deploying to an agent" description="Download, verify and upload the three payloads to a Vandal agent's /payloads/ volume." to="/hid-shell/docs/guides/2.deploying"}
::::
:::
