## Persistent OS shell child process. Stdin/stdout are byte streams
## the pump module marshals into HID frames. We force an interactive
## shell so users can run multi-step commands sharing environment
## (`cd /tmp && pwd`).
##
## Windows: `cmd.exe`
## Linux/macOS: `/bin/sh -i` (a real PTY would be better; out of scope
## for v1 since the agent and UI both treat the channel as a dumb byte
## stream. Future Phase G can swap this for `winpty` / `pty.openpty`).

import std/[osproc, streams, os]

type
  ShellChild* = ref object
    process*: Process
    stdinStream*: Stream
    stdoutStream*: Stream

proc spawnShell*(): ShellChild =
  result = ShellChild()
  when defined(windows):
    let cmd = getEnv("COMSPEC", "cmd.exe")
    result.process = startProcess(
      command = cmd,
      args = ["/Q", "/K", "@echo off"],
      options = {poUsePath, poStdErrToStdOut, poInteractive}
    )
  else:
    let shell = getEnv("SHELL", "/bin/sh")
    result.process = startProcess(
      command = shell,
      args = ["-i"],
      options = {poUsePath, poStdErrToStdOut, poInteractive}
    )
  result.stdinStream = result.process.inputStream
  result.stdoutStream = result.process.outputStream

proc writeBytes*(c: ShellChild, data: openArray[uint8]) =
  if data.len == 0:
    return
  c.stdinStream.writeData(unsafeAddr data[0], data.len)
  c.stdinStream.flush()

proc tryReadBytes*(c: ShellChild, buf: var seq[uint8], maxBytes: int): int =
  ## Non-blocking read attempt. Returns number of bytes copied into
  ## `buf` (which is resized). Returns 0 if no data is currently
  ## available without consuming the stream.
  buf.setLen(maxBytes)
  # `Stream.readData` blocks; check first.
  let available = c.stdoutStream.atEnd
  if available:
    buf.setLen(0)
    return 0
  let got = c.stdoutStream.readData(addr buf[0], maxBytes)
  buf.setLen(got)
  return got

proc isAlive*(c: ShellChild): bool =
  c.process.running

proc terminate*(c: ShellChild) =
  try:
    if c.process.running:
      c.process.terminate()
      discard c.process.waitForExit(timeout = 500)
  except CatchableError:
    discard
  try:
    c.process.close()
  except CatchableError:
    discard
