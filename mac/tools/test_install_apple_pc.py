#!/usr/bin/env python3
"""install-apple.sh on a PC whose Tahoe runs its built-in graphics on Apple's driver: only the graphics drivers are
carried, the Mac-only helpers stay off, and a real Mac still gets the whole Mac. Runs the real script against
throwaway volumes and a stand-in kmutil; nothing outside a temporary folder is touched."""
import os
import plistlib
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "kit", "driver_apple", "install-apple.sh")
CFL = "com.apple.driver.AppleIntelCFLGraphicsFramebuffer"
CPUPM = "com.apple.driver.AppleIntelCPUPowerManagement"
FAILS = []


def arm(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)
        print("     " + detail.replace("\n", "\n     ")[:3000])


def kext(folder, name, bid):
    os.makedirs(os.path.join(folder, name, "Contents"), exist_ok=True)
    plistlib.dump({"CFBundleIdentifier": bid}, open(os.path.join(folder, name, "Contents", "Info.plist"), "wb"))


def touch(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)


def world(td):
    pay = os.path.join(td, "pkg")
    p = os.path.join(pay, "payload")
    kext(os.path.join(p, "Library", "Extensions"), "NMXAudio.kext", "com.nullmoth.NMXAudio")
    for f in ("usr/local/libexec/nullmoth/audsel", "usr/local/libexec/nullmoth/netup.sh",
              "Library/LaunchDaemons/com.nullmoth.netup.plist", "Library/LaunchDaemons/com.nullmoth.rbcpu.daemon.plist",
              "Library/LaunchAgents/com.nullmoth.audsel.plist", "Library/LaunchAgents/com.nullmoth.rbcpu.agent.plist"):
        touch(os.path.join(p, f))
    touch(os.path.join(pay, "MANIFEST"), "# no checked files in this stand-in\n")
    sysv, data = os.path.join(td, "sys"), os.path.join(td, "data")
    for f in ("System/Library/KernelCollections/BootKernelExtensions.kc", "System/Library/KernelCollections/SystemKernelExtensions.kc",
              "System/Library/Kernels/kernel"):
        touch(os.path.join(sysv, f))
    os.makedirs(data, exist_ok=True)
    ext = os.path.join(td, "tahoe-ext")
    kext(ext, "AppleIntelCFLGraphicsFramebuffer.kext", CFL)
    kext(ext, "AppleIntelCPUPowerManagement.kext", CPUPM)
    os.makedirs(os.path.join(ext, "AppleIntelKBLGraphicsMTLDriver.bundle", "Contents"), exist_ok=True)
    km = os.path.join(td, "kmutil")
    # create: the collection holds the IDs it was asked for; inspect -A: prints them back
    touch(km, '#!/bin/bash\nif [ "$1" = create ]; then out=""; ids=""; while [ $# -gt 0 ]; do case "$1" in -A) out=$2; shift;; -b) ids="$ids $2"; shift;; esac; shift; done\n'
              '  printf "%s\\n" $ids > "$out"; exit 0; fi\n'
              'if [ "$1" = inspect ]; then while [ $# -gt 0 ]; do [ "$1" = -A ] && cat "$2"; shift; done; exit 0; fi\nexit 0\n')
    os.chmod(km, 0o755)
    return pay, sysv, data, ext, km


def run(td, mode, kind=None, model=None):
    pay, sysv, data, ext, km = world(td)
    env = dict(os.environ)
    env.pop("GG_EFIKIND", None)
    if kind:
        env["GG_EFIKIND"] = kind
    a = ["/bin/bash", SCRIPT, "--payload", pay, "--system", sysv, "--data", data, mode,
         "--kmutil", km, "--tahoe-ext", ext, "--gfx-ids", f"{CFL} {CPUPM}"]
    if model:
        a += ["--model", model]
    r = subprocess.run(a, capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr, sysv, data


def main():
    with tempfile.TemporaryDirectory() as td:
        rc, out, _, _ = run(os.path.join(td, "a"), "--dry-run", kind="pc")
        arm("a PC is accepted and only its graphics driver is counted to carry (not its processor power driver)",
            rc == 0 and "a PC: only the graphics drivers" in out and "1 drivers that macOS 27 lacks" in out, out)
        rc, out, _, _ = run(os.path.join(td, "b"), "--dry-run", kind="mac", model="iMac19,1")
        arm("control: a real Mac still carries every driver its Tahoe has that macOS 27 lacks", rc == 0 and "2 drivers that macOS 27 lacks" in out, out)
        rc, out, _, _ = run(os.path.join(td, "c"), "--dry-run")
        arm("with no machine kind from Golden Gate and no model given, nothing is changed", rc == 1 and "did not say which this is" in out, out)
        rc, out, sysv, data = run(os.path.join(td, "d"), "--apply", kind="pc")
        aux = os.path.join(data, "Library", "KernelCollections", "AuxiliaryKernelExtensions.kc")
        inside = open(aux).read() if os.path.exists(aux) else ""
        arm("on a PC the linked collection holds the graphics driver and the audio driver, not the processor driver",
            rc == 0 and CFL in inside and "com.nullmoth.NMXAudio" in inside and CPUPM not in inside, out + inside)
        arm("on a PC the Mac's speaker and wired-address helpers are not placed",
            not os.path.exists(os.path.join(data, "usr/local/libexec/nullmoth/audsel"))
            and not os.path.exists(os.path.join(data, "Library/LaunchDaemons/com.nullmoth.netup.plist"))
            and not os.path.exists(os.path.join(data, "Library/LaunchAgents/com.nullmoth.audsel.plist")), out)
        arm("on a PC the CPU-renderer helper and the graphics bundle are placed",
            os.path.exists(os.path.join(data, "Library/LaunchAgents/com.nullmoth.rbcpu.agent.plist"))
            and os.path.isdir(os.path.join(sysv, "System/Library/Extensions/AppleIntelKBLGraphicsMTLDriver.bundle")), out)
        rc, out, sysv, data = run(os.path.join(td, "e"), "--apply", kind="mac", model="iMac19,1")
        arm("control: on a real Mac the speaker helper is placed", rc == 0 and os.path.exists(os.path.join(data, "usr/local/libexec/nullmoth/audsel")), out)
    print("all passed" if not FAILS else f"{len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
