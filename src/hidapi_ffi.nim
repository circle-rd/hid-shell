## Minimal FFI bindings for the system `hidapi` C library.
##
## We avoid pulling a third-party Nim wrapper because (a) the existing
## `hidapi` nimble package is unmaintained / unpublished and (b) the C
## surface we actually need is tiny: enumerate, open_path, read_timeout,
## write, close.
##
## Two linking modes (switched by `-d:hidapiStatic`):
##
##   * default (dev): dynlib — dlopen the system hidapi at runtime.
##     Convenient for `nim r` iteration on a dev box that already has
##     `libhidapi-hidraw0` / `brew install hidapi` / a bundled DLL.
##
##   * `-d:hidapiStatic` (release): plain importc — the linker resolves
##     the symbols against a static `libhidapi.a` provided via --passL.
##     This is what `./scripts/build_all.sh` uses so the shipped
##     binaries have no hidapi runtime dependency on the target host.
##
## Static-mode runtime dependencies per target:
##   - Linux:   libudev (part of systemd — universal on modern desktops)
##   - macOS:   IOKit + CoreFoundation (system frameworks, always present)
##   - Windows: setupapi.dll + hid.dll (system DLLs, always present)

when not defined(hidapiStatic):
  when defined(linux):
    const libHidapi = "(libhidapi-hidraw.so.0|libhidapi-libusb.so.0|libhidapi.so.0)"
  elif defined(macosx):
    const libHidapi = "libhidapi.dylib"
  elif defined(windows):
    const libHidapi = "hidapi.dll"
  else:
    {.error: "Unsupported OS for hidapi FFI bindings".}

type
  HidDevice* = pointer  ## opaque handle returned by hid_open*

  HidDeviceInfo* {.bycopy.} = object
    path*: cstring
    vendorId*: cushort
    productId*: cushort
    serialNumber*: ptr WideCString
    releaseNumber*: cushort
    manufacturerString*: ptr WideCString
    productString*: ptr WideCString
    usagePage*: cushort
    usage*: cushort
    interfaceNumber*: cint
    next*: ptr HidDeviceInfo

# ---- C symbols ---------------------------------------------------------------
# Pragmas differ between linking modes; everything else is identical.
when defined(hidapiStatic):
  {.pragma: hidProc, cdecl, importc.}
else:
  {.pragma: hidProc, cdecl, importc, dynlib: libHidapi.}

proc hid_init*(): cint {.hidProc.}
proc hid_exit*(): cint {.hidProc.}

proc hid_enumerate*(vendorId, productId: cushort): ptr HidDeviceInfo {.hidProc.}

proc hid_free_enumeration*(devs: ptr HidDeviceInfo) {.hidProc.}

proc hid_open_path*(path: cstring): HidDevice {.hidProc.}

proc hid_close*(dev: HidDevice) {.hidProc.}

proc hid_write*(dev: HidDevice, data: ptr uint8, length: csize_t): cint {.hidProc.}

proc hid_read_timeout*(dev: HidDevice, data: ptr uint8,
                       length: csize_t, milliseconds: cint): cint {.hidProc.}

proc hid_error*(dev: HidDevice): WideCString {.hidProc.}
  ## Last error for the given device handle (NULL-safe — pass nil for
  ## global errors). Returns a wide string owned by hidapi; do not free.
