## Wire protocol constants and frame helpers for HID-Shell v1.
## Mirror of `Vandal/main/modules/attacks/shell_session.c`.

import std/endians

const
  FrameSize*        : int    = 64
  FrameHeaderSize*  : int    = 4
  FramePayloadSize* : int    = FrameSize - FrameHeaderSize

  # Frame types
  TypeCmd*  : uint8 = 0x10  ## agent -> host: command bytes
  TypeOut*  : uint8 = 0x11  ## host -> agent: shell output bytes
  TypeCtrl* : uint8 = 0x12  ## bidirectional control message

  # Flags
  FlagFin*  : uint8 = 0x01

  # CTRL subtypes
  CtrlHello*    : uint8 = 0x01
  CtrlHelloAck* : uint8 = 0x02
  CtrlPing*     : uint8 = 0x03
  CtrlPong*     : uint8 = 0x04
  CtrlCmdId*    : uint8 = 0x05
  CtrlBye*      : uint8 = 0x06
  CtrlError*    : uint8 = 0x07

  # OS identifiers (HELLO payload)
  OsWindows* : uint8 = 0x01
  OsLinux*   : uint8 = 0x02
  OsMacOS*   : uint8 = 0x03

  ProtoVersion* : uint16 = 0x0001

  # Vendor HID identifier used to filter Vandal's vendor interface from
  # the (potentially many) HID devices enumerated on the host.
  VendorUsagePage* : uint16 = 0xFF00
  VendorUsage*     : uint16 = 0x0001

type
  Frame* = object
    typ*: uint8
    flags*: uint8
    seq*: uint16
    payload*: array[FramePayloadSize, uint8]
    payloadLen*: int  ## significant bytes in `payload`

proc encodeFrame*(f: Frame): array[FrameSize, uint8] =
  ## Serialise `f` into a 64-byte wire frame, zero-padded.
  result[0] = f.typ
  result[1] = f.flags
  var seqLE: array[2, uint8]
  var s = f.seq
  littleEndian16(addr seqLE, addr s)
  result[2] = seqLE[0]
  result[3] = seqLE[1]
  let n = min(f.payloadLen, FramePayloadSize)
  if n > 0:
    copyMem(addr result[FrameHeaderSize], unsafeAddr f.payload[0], n)

proc decodeFrame*(buf: openArray[uint8]): Frame =
  ## Parse a 64-byte wire frame. Returns a Frame with payloadLen = 60
  ## (the receiver figures out real length via FIN + reassembly).
  assert buf.len >= FrameHeaderSize
  result.typ = buf[0]
  result.flags = buf[1]
  var seqLE: array[2, uint8] = [buf[2], buf[3]]
  littleEndian16(addr result.seq, addr seqLE)
  let n = min(buf.len - FrameHeaderSize, FramePayloadSize)
  if n > 0:
    copyMem(addr result.payload[0], unsafeAddr buf[FrameHeaderSize], n)
  result.payloadLen = n

proc isFin*(f: Frame): bool {.inline.} =
  (f.flags and FlagFin) != 0
