## Persistent OS shell child process. Stdin/stdout are byte streams
## the pump module marshals into HID frames.
##
## POSIX (Linux/macOS): the shell is spawned on a pseudo-terminal so
## bash/zsh consider stdout to be a TTY and switch to line-buffered
## mode. Without a PTY the child buffers output by 4-8 KiB blocks and
## the operator only sees results once enough bytes have accumulated
## (or on SIGINT). A PTY also unlocks colours, readline editing, and
## full-screen tools (`less`, `vi`, `top`).
##
## Windows: `cmd.exe` already line-buffers when its stdout is a pipe,
## so a plain `osproc` pipe is sufficient for v1. A future revision
## can swap to ConPTY for parity with POSIX (colours, native readline).

import std/os

when defined(windows):
  import std/[osproc, streams]
else:
  import std/[posix, strutils]

type
  ShellChild* = ref object
    when defined(windows):
      process*: Process
      stdinStream*: Stream
      stdoutStream*: Stream
    else:
      pid*: Pid
      master*: cint   ## PTY master fd (bidirectional)

# ---------------------------------------------------------------------------
# POSIX PTY implementation
# ---------------------------------------------------------------------------

when not defined(windows):
  # libc helpers not exposed by std/posix in older Nim releases.
  proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
  proc grantpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc unlockpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc ptsname(fd: cint): cstring {.importc, header: "<stdlib.h>".}
  proc setsid(): Pid {.importc, header: "<unistd.h>".}
  proc ioctl(fd: cint, request: culong): cint {.importc, header: "<sys/ioctl.h>", varargs.}
  proc c_setenv(name, value: cstring, overwrite: cint): cint {.importc: "setenv", header: "<stdlib.h>".}

  # TIOCSCTTY differs across kernels; on Linux it is 0x540E.
  when defined(linux):
    const TIOCSCTTY = 0x540E.culong
  elif defined(macosx):
    const TIOCSCTTY = 0x20007461.culong
  else:
    const TIOCSCTTY = 0x540E.culong

  proc setNonBlocking(fd: cint) =
    let flags = fcntl(fd, F_GETFL, 0)
    if flags != -1:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

  proc spawnShellPosix(): ShellChild =
    result = ShellChild()
    let master = posix_openpt(O_RDWR or O_NOCTTY)
    if master < 0:
      raise newException(OSError, "posix_openpt failed: " & $strerror(errno))
    if grantpt(master) != 0:
      discard close(master)
      raise newException(OSError, "grantpt failed: " & $strerror(errno))
    if unlockpt(master) != 0:
      discard close(master)
      raise newException(OSError, "unlockpt failed: " & $strerror(errno))
    let slaveName = $ptsname(master)

    let pid = fork()
    if pid < 0:
      discard close(master)
      raise newException(OSError, "fork failed: " & $strerror(errno))

    if pid == 0:
      # Child: detach from parent's controlling TTY, attach to the slave.
      discard setsid()
      let slave = open(slaveName.cstring, O_RDWR)
      if slave < 0:
        quit(127)
      discard ioctl(slave, TIOCSCTTY, 0)
      discard dup2(slave, 0)
      discard dup2(slave, 1)
      discard dup2(slave, 2)
      if slave > 2:
        discard close(slave)
      discard close(master)

      # Reasonable defaults so prompts render correctly.
      discard c_setenv(cstring"TERM", cstring"xterm-256color", 1)
      # Override PS1 so the visible prompt is short, deterministic and
      # does not leak the host's bash startup customisations (which may
      # include long git/conda decorators, ANSI heavy renderers like
      # starship, or multi-line prompts that fight with xterm.js
      # cursor tracking).
      discard c_setenv(cstring"PS1", cstring"\\u@vandal:\\w\\$ ", 1)

      let shell = getEnv("SHELL", "/bin/bash")
      # `-i` keeps the shell interactive (PS1, history, job control).
      # `--norc` (bash-only flag, ignored as harmless arg by sh) skips
      # ~/.bashrc so our PS1 env var is not overwritten by the user's
      # customisations and we get a deterministic prompt for xterm.js.
      let argv = allocCStringArray([shell, "--norc", "-i"])
      discard execv(shell.cstring, argv)
      # If execv returns, fall back to /bin/sh.
      let fallback = allocCStringArray(["/bin/sh", "-i"])
      discard execv("/bin/sh", fallback)
      quit(127)

    # Parent
    setNonBlocking(master)
    result.pid = pid
    result.master = master

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc spawnShell*(): ShellChild =
  when defined(windows):
    result = ShellChild()
    let cmd = getEnv("COMSPEC", "cmd.exe")
    result.process = startProcess(
      command = cmd,
      args = ["/Q", "/K", "@echo off"],
      options = {poUsePath, poStdErrToStdOut, poInteractive}
    )
    result.stdinStream = result.process.inputStream
    result.stdoutStream = result.process.outputStream
  else:
    return spawnShellPosix()

proc writeBytes*(c: ShellChild, data: openArray[uint8]) =
  if data.len == 0:
    return
  when defined(windows):
    c.stdinStream.writeData(unsafeAddr data[0], data.len)
    c.stdinStream.flush()
  else:
    var off = 0
    while off < data.len:
      let n = write(c.master, unsafeAddr data[off], (data.len - off).cint)
      if n > 0:
        off += n
      elif n < 0 and errno == EINTR:
        continue
      else:
        # EAGAIN on a saturated PTY: bail; caller will retry next loop.
        break

proc tryReadBytes*(c: ShellChild, buf: var seq[uint8], maxBytes: int): int =
  ## Non-blocking read. Returns 0 if no data is currently available.
  buf.setLen(maxBytes)
  when defined(windows):
    if c.stdoutStream.atEnd:
      buf.setLen(0)
      return 0
    let got = c.stdoutStream.readData(addr buf[0], maxBytes)
    buf.setLen(got)
    return got
  else:
    let n = read(c.master, addr buf[0], maxBytes.cint)
    if n > 0:
      buf.setLen(n)
      return n
    if n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR):
      buf.setLen(0)
      return 0
    # n == 0 (EOF) or hard error: treat as no data; isAlive() will flip.
    buf.setLen(0)
    return 0

proc isAlive*(c: ShellChild): bool =
  when defined(windows):
    c.process.running
  else:
    if c.pid <= 0:
      return false
    # waitpid(WNOHANG) — returns 0 if still running.
    var status: cint
    let r = waitpid(c.pid, status, WNOHANG)
    return r == 0

proc terminate*(c: ShellChild) =
  when defined(windows):
    try:
      if c.process.running:
        c.process.terminate()
        discard c.process.waitForExit(timeout = 500)
    except CatchableError: discard
    try: c.process.close()
    except CatchableError: discard
  else:
    if c.pid > 0:
      discard kill(c.pid, SIGTERM)
      var status: cint
      # Give it 500 ms to exit cleanly, then SIGKILL.
      for _ in 0 ..< 50:
        if waitpid(c.pid, status, WNOHANG) != 0:
          break
        os.sleep(10)
      if waitpid(c.pid, status, WNOHANG) == 0:
        discard kill(c.pid, SIGKILL)
        discard waitpid(c.pid, status, 0)
      c.pid = -1
    if c.master >= 0:
      discard close(c.master)
      c.master = -1
