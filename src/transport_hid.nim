## High-level transport over the Vandal vendor HID interface.
## Uses our minimal FFI binding (`hidapi_ffi`) to the system hidapi
## library. Filters HID devices by usage page 0xFF00 rather than VID/PID
## because Vandal allows those to be reconfigured at runtime.

import std/[options, os]
import ./hidapi_ffi, ./protocol

type
  HidLink* = object
    dev*: HidDevice
    path*: string
    vid*: uint16
    pid*: uint16

var ffiInitialised = false

proc ensureInit() =
  if not ffiInitialised:
    if hid_init() != 0:
      raise newException(IOError, "hid_init() failed")
    ffiInitialised = true

proc findVandalShell*(): Option[HidLink] =
  ## Walk every HID device on the host and return the first one that
  ## exposes the Vandal Shell vendor usage. Returns `none` if the
  ## device is not currently enumerated.
  ensureInit()
  let head = hid_enumerate(0, 0)
  if head == nil:
    return none(HidLink)
  defer: hid_free_enumeration(head)

  var cur = head
  while cur != nil:
    if uint16(cur.usagePage) == VendorUsagePage and
       uint16(cur.usage) == VendorUsage:
      let pathStr = $cur.path
      let dev = hid_open_path(cur.path)
      if dev != nil:
        return some(HidLink(
          dev: dev,
          path: pathStr,
          vid: uint16(cur.vendorId),
          pid: uint16(cur.productId),
        ))
      # Could not open (busy / EACCES): try the next entry.
    cur = cur.next
  return none(HidLink)

proc waitForDevice*(maxAttempts = 50, intervalMs = 200): Option[HidLink] =
  ## Poll until either the Vandal shell vendor HID is found or we time
  ## out. Used at startup so the launcher can fire the payload before
  ## the agent finishes enumerating.
  for _ in 0 ..< maxAttempts:
    let r = findVandalShell()
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
  var buf = newSeq[uint8](FrameSize)
  let n = hid_read_timeout(link.dev, addr buf[0],
                           csize_t(buf.len), cint(timeoutMs))
  if n < 0:
    raise newException(IOError, "hid_read_timeout failed")
  if n == 0:
    return none(Frame)
  return some(decodeFrame(buf))

proc close*(link: HidLink) =
  if link.dev != nil:
    hid_close(link.dev)
