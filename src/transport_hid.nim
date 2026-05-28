## High-level transport over the Vandal vendor HID interface.
## Uses our minimal FFI binding (`hidapi_ffi`) to the system hidapi
## library. Filters HID devices by usage page 0xFF00 rather than VID/PID
## because Vandal allows those to be reconfigured at runtime.

import std/[options, os, strutils, widestrs]
import ./hidapi_ffi, ./protocol

type
  HidLink* = object
    dev*: HidDevice
    path*: string
    vid*: uint16
    pid*: uint16

# Forward decls: findVandalShell probes each candidate with a HELLO
# exchange; the helpers are defined below after the basic I/O primitives.
proc sendFrame*(link: HidLink, f: Frame): bool
proc readFrame*(link: HidLink, timeoutMs: int = 100): Option[Frame]
proc probeIsVandal(link: HidLink, debug: proc(msg: string)): bool

var ffiInitialised = false

proc ensureInit() =
  if not ffiInitialised:
    if hid_init() != 0:
      raise newException(IOError, "hid_init() failed")
    ffiInitialised = true

proc lastError(dev: HidDevice): string =
  ## Best-effort retrieval of hidapi's last error string for a device
  ## handle. hidapi returns a wide string we have to convert; on Windows
  ## this exposes the underlying GetLastError() text which is critical
  ## when ReadFile/WriteFile fail (ACCESS_DENIED, INVALID_USER_BUFFER,
  ## DEVICE_NOT_CONNECTED, ...).
  let w = hid_error(dev)
  if w.isNil:
    return "<no hidapi error>"
  try:
    return $w
  except CatchableError:
    return "<hid_error decode failed>"

proc findVandalShell*(debug: proc(msg: string) = nil): Option[HidLink] =
  ## Walk every HID device on the host, narrow to the ones exposing
  ## the Vandal vendor usage `(0xFF00, 0x01)`, then **probe** each
  ## candidate with a HELLO frame to confirm it's actually our agent.
  ##
  ## The vendor `(0xFF00, 0x01)` combo is extremely common (RGB
  ## controllers, gaming dongles, hobbyist Arduino boards, …) so the
  ## previous "take the first match" strategy regularly opened the
  ## wrong device, wrote our HELLO into the void, and crashed at the
  ## first read with ReadFile errors. Probing is the only reliable
  ## signature since Vandal lets users reconfigure VID/PID at runtime.
  ensureInit()
  let head = hid_enumerate(0, 0)
  if head == nil:
    return none(HidLink)
  defer: hid_free_enumeration(head)

  var cur = head
  var candidatesTried = 0
  while cur != nil:
    if uint16(cur.usagePage) == VendorUsagePage and
       uint16(cur.usage) == VendorUsage:
      let pathStr = $cur.path
      let vid = uint16(cur.vendorId)
      let pid = uint16(cur.productId)
      if debug != nil:
        debug("candidate VID:PID " & toHex(vid, 4) & ":" & toHex(pid, 4) &
              " path=" & pathStr)
      let dev = hid_open_path(cur.path)
      if dev == nil:
        if debug != nil: debug("  open failed, skipping")
      else:
        let link = HidLink(dev: dev, path: pathStr, vid: vid, pid: pid)
        candidatesTried.inc
        if probeIsVandal(link, debug):
          if debug != nil: debug("  -> Vandal agent confirmed")
          return some(link)
        if debug != nil: debug("  -> no HELLO_ACK, not Vandal")
        hid_close(dev)
    cur = cur.next
  if debug != nil:
    debug("no Vandal device among " & $candidatesTried & " HID candidate(s)")
  return none(HidLink)

proc waitForDevice*(maxAttempts = 50, intervalMs = 200,
                    debug: proc(msg: string) = nil): Option[HidLink] =
  ## Poll until either the Vandal shell vendor HID is found or we time
  ## out. Used at startup so the launcher can fire the payload before
  ## the agent finishes enumerating.
  for _ in 0 ..< maxAttempts:
    let r = findVandalShell(debug)
    if r.isSome:
      return r
    sleep(intervalMs)
  return none(HidLink)

proc sendFrame*(link: HidLink, f: Frame): bool =
  ## Write one 64-byte report. Returns true on success.
  ## The descriptor has no report ID, so we prepend a leading 0x00 byte
  ## as required by hidapi.
  let wire = encodeFrame(f)
  var buf = newSeq[uint8](FrameSize + 1)
  buf[0] = 0
  copyMem(addr buf[1], unsafeAddr wire[0], FrameSize)
  let n = hid_write(link.dev, addr buf[0], csize_t(buf.len))
  return int(n) == buf.len

proc readFrame*(link: HidLink, timeoutMs: int = 100): Option[Frame] =
  ## Block up to `timeoutMs` waiting for one report. Returns `none`
  ## on timeout, raises on fatal device error.
  ##
  ## Windows note: the HID class driver always prepends a report-ID
  ## byte (0x00 when the descriptor has no numbered reports), so the
  ## buffer must be sized `FrameSize + 1`. Passing only `FrameSize`
  ## makes ReadFile fail with ERROR_INVALID_USER_BUFFER and hidapi
  ## returns -1. Linux/macOS happen to tolerate the short buffer, but
  ## we always allocate the extra byte and strip it if present so the
  ## three platforms share one code path.
  var buf = newSeq[uint8](FrameSize + 1)
  let n = hid_read_timeout(link.dev, addr buf[0],
                           csize_t(buf.len), cint(timeoutMs))
  if n < 0:
    raise newException(IOError,
      "hid_read_timeout failed: " & lastError(link.dev))
  if n == 0:
    return none(Frame)
  # If the platform returned the leading report-ID byte, skip it.
  if n == FrameSize + 1:
    return some(decodeFrame(buf.toOpenArray(1, FrameSize)))
  return some(decodeFrame(buf.toOpenArray(0, n - 1)))

proc close*(link: HidLink) =
  if link.dev != nil:
    hid_close(link.dev)

# ---------------------------------------------------------------------------
# Internal: HELLO probe used during enumeration to discriminate the real
# Vandal agent from other vendor-page HID devices on the host.
# ---------------------------------------------------------------------------

const
  ProbeTimeoutMs   = 250  ## per-read budget while waiting for HELLO_ACK
  ProbeMaxReads    = 6    ## total budget ≈ 1.5 s before giving up

proc sendProbeHello(link: HidLink): bool =
  var f = Frame(typ: TypeCtrl, flags: FlagFin, seq: 0)
  f.payload[0] = CtrlHello
  f.payload[1] = uint8(ProtoVersion and 0xFF)
  f.payload[2] = uint8((ProtoVersion shr 8) and 0xFF)
  when defined(windows):   f.payload[3] = OsWindows
  elif defined(macosx):    f.payload[3] = OsMacOS
  else:                    f.payload[3] = OsLinux
  f.payloadLen = 4
  return link.sendFrame(f)

proc probeIsVandal(link: HidLink, debug: proc(msg: string)): bool =
  ## Send one HELLO and wait briefly for HELLO_ACK. Returns false on
  ## any error (write fail, read fail, timeout, unrelated frame) — the
  ## caller will close the device and try the next candidate.
  ##
  ## Writing a 4-byte vendor-page report into a foreign HID device is
  ## generally harmless: the receiver either ignores it (no matching
  ## report descriptor handler) or replies with garbage we discard.
  if not sendProbeHello(link):
    if debug != nil: debug("  HELLO write failed: " & lastError(link.dev))
    return false
  for _ in 0 ..< ProbeMaxReads:
    var fOpt: Option[Frame]
    try:
      fOpt = link.readFrame(ProbeTimeoutMs)
    except IOError as e:
      if debug != nil: debug("  probe read error: " & e.msg)
      return false
    if fOpt.isNone:
      continue  # timeout slice — keep waiting
    let f = fOpt.get
    if f.typ == TypeCtrl and f.payloadLen >= 1 and
       f.payload[0] == CtrlHelloAck:
      return true
    # Any other frame: not us, keep waiting in case ACK is still coming.
  return false
