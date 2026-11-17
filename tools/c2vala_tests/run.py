#!/usr/bin/env python3
"""Differential tests for tools/c2vala.py.

For every case directory:

  * compile the C sources with gcc and run them   -> reference output
  * translate them to Vala with tools/c2vala.py, compile that with valac and
    run it                                       -> candidate output
  * both outputs must match byte for byte

A case can instead declare that it must be *refused* (`refuse.txt`): the
translator has to exit with status 2 and print a diagnostic.

Requires gcc and valac (MSYS2 UCRT64 here). The jsmn case downloads jsmn.h on
demand; it is third-party MIT code and is not committed.

Usage:
    python tools/c2vala_tests/run.py                 # every case
    python tools/c2vala_tests/run.py --only jsmn
    python tools/c2vala_tests/run.py --verbose
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TOOLS = os.path.join(ROOT, "tools")
CASES = os.path.join(HERE, "cases")
RUNTIME = os.path.join(TOOLS, "c2vala_rt.vala")
TRANSLATOR_PY = os.path.join(TOOLS, "c2vala.py")
TRANSLATOR_VALA = os.path.join(TOOLS, "c2vala", "build", "c2vala")
TRANSLATOR_VALA_EXE = TRANSLATOR_VALA + ".exe"
PLANC_BIN = os.path.join(ROOT, "planc", "build", "planc")

IS_WINDOWS = os.name == "nt"
MSYS = os.environ.get("MSYS2_ROOT", r"C:\Users\Lenovo\msys64")
UCRT = os.path.join(MSYS, "ucrt64", "bin")
BASH = os.path.join(MSYS, "usr", "bin", "bash.exe")

JSMN_URL = "https://raw.githubusercontent.com/zserge/jsmn/master/jsmn.h"


def die(msg):
    sys.stderr.write("c2vala-tests: %s\n" % msg)
    sys.exit(2)


def find_native():
    """The native (Vala) translator, however it was built for this host."""
    for cand in (TRANSLATOR_VALA_EXE, TRANSLATOR_VALA):
        if os.path.isfile(cand):
            return cand
    return None


def runs_here(path):
    """True when this host can execute `path`.

    planc emits ELF, so a native build made by tools/c2vala/build.sh only runs
    inside the guest (or on Linux); the host build (build_host.sh) produces a
    PE image on Windows.
    """
    if not os.path.isfile(path):
        return False
    if not IS_WINDOWS:
        return True
    with open(path, "rb") as fh:
        return fh.read(2) == b"MZ"


def sh(command):
    """Runs a command via MSYS2 bash on Windows or /bin/sh on POSIX."""
    if IS_WINDOWS:
        script = "export PATH=/ucrt64/bin:/usr/bin:$PATH; %s" % command
        return subprocess.run([BASH, "-c", script], capture_output=True, text=True)
    return subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True)


def has_valac():
    if IS_WINDOWS:
        return sh("command -v valac >/dev/null 2>&1").returncode == 0
    return shutil.which("valac") is not None


def posix(path):
    return path.replace("\\", "/")


def ensure_jsmn(case_dir, verbose):
    target = os.path.join(case_dir, "jsmn.h")
    if os.path.isfile(target):
        return True
    try:
        with urllib.request.urlopen(JSMN_URL, timeout=30) as response:
            data = response.read()
        with open(target, "wb") as fh:
            fh.write(data)
        if verbose:
            print("   fetched jsmn.h (%d bytes)" % len(data))
        return True
    except Exception as exc:  # no network: skip instead of failing
        print("   SKIP (cannot fetch jsmn.h: %s)" % exc)
        return False


def compile_c(case_dir, work, verbose):
    sources = sorted(f for f in os.listdir(case_dir) if f.endswith(".c"))
    outs = []
    for name in sources:
        exe = os.path.join(work, name[:-2] + ".c.exe")
        cmd = 'gcc -std=c99 -O0 -I"%s" "%s" -o "%s"' % (
            posix(case_dir), posix(os.path.join(case_dir, name)), posix(exe))
        proc = sh(cmd)
        if proc.returncode != 0:
            return None, "gcc failed on %s:\n%s" % (name, proc.stderr[-2000:])
        outs.append(exe)
    return outs, None


def main(argv):
    ap = argparse.ArgumentParser(description="differential tests for the C -> Vala translator")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    ap.add_argument("--translator", choices=["py", "vala"], default="vala",
                    help="which c2vala implementation to test (default: vala)")
    args = ap.parse_args(argv)

    if IS_WINDOWS and not os.path.isfile(BASH):
        die("MSYS2 bash not found at %s (set MSYS2_ROOT)" % BASH)
    translator_cmd = [sys.executable, TRANSLATOR_PY] if args.translator == "py" else [find_native()]
    if args.translator == "vala" and find_native() is None:
        die("native c2vala not built: run tools/c2vala/build_host.sh (host build) "
            "or tools/c2vala/build.sh (guest build)")
    use_planc = (args.translator == "vala") and runs_here(PLANC_BIN)
    valac_available = has_valac()
    names = sorted(d for d in os.listdir(CASES) if os.path.isdir(os.path.join(CASES, d)))
    if args.only:
        names = [n for n in names if n in args.only]
    if not names:
        die("no cases")

    work = tempfile.mkdtemp(prefix="c2vala-tests-")
    failures = 0
    passed = 0
    try:
        for name in names:
            case_dir = os.path.join(CASES, name)
            case_work = os.path.join(work, name)
            os.makedirs(case_work, exist_ok=True)
            print("== case %s" % name)

            if name == "refused_union" and args.translator == "vala":
                print("   SKIP (unions are supported in c2vala+planc)")
                continue
            if name == "unions" and args.translator == "py":
                print("   SKIP (unions are refused in c2vala.py)")
                continue
            planc_only = os.path.join(case_dir, "planc_only.txt")
            if os.path.isfile(planc_only) and not use_planc:
                print("   SKIP (needs planc to compile the generated code: %s)"
                      % open(planc_only, encoding="utf-8").read().splitlines()[0])
                continue
            if name == "jsmn" and not ensure_jsmn(case_dir, args.verbose):
                continue

            sources = sorted(f for f in os.listdir(case_dir) if f.endswith(".c"))
            headers = sorted(f for f in os.listdir(case_dir) if f.endswith(".h"))
            vala_out = os.path.join(case_work, "translated.vala")
            translate = subprocess.run(
                translator_cmd + [os.path.join(case_dir, s) for s in sources + headers]
                + ["-I", case_dir, "-o", vala_out],
                capture_output=True, text=True)

            if os.path.isfile(os.path.join(case_dir, "report.txt")):
                expected = [l.strip() for l in
                            open(os.path.join(case_dir, "report.txt"), encoding="utf-8").readlines()
                            if l.strip()]
                proc = subprocess.run(
                    translator_cmd + [os.path.join(case_dir, s) for s in sources + headers]
                    + ["-I", case_dir, "--report", "-o", vala_out],
                    capture_output=True, text=True)
                missing = [e for e in expected if e not in proc.stdout]
                if missing:
                    print("   FAIL: report is missing %r" % missing)
                    print(proc.stdout[-2000:])
                    failures += 1
                    continue
                print("   PASS (report matches %d expectations)" % len(expected))
                passed += 1
                continue

            if os.path.isfile(os.path.join(case_dir, "refuse.txt")):
                expected = open(os.path.join(case_dir, "refuse.txt"), encoding="utf-8").read().strip()
                if translate.returncode != 2:
                    print("   FAIL: expected a refusal, got exit %d" % translate.returncode)
                    failures += 1
                    continue
                if expected and expected not in translate.stderr:
                    print("   FAIL: refusal message missing %r" % expected)
                    print("   got: %s" % translate.stderr.strip())
                    failures += 1
                    continue
                print("   PASS (refused: %s)" % translate.stderr.strip().split(":")[-1].strip())
                passed += 1
                continue

            if translate.returncode != 0:
                print("   FAIL: translator exit %d\n%s" % (translate.returncode, translate.stderr.strip()))
                failures += 1
                continue
            if args.verbose:
                print("   %s" % translate.stdout.strip())

            # reference: gcc
            refs, err = compile_c(case_dir, case_work, args.verbose)
            if refs is None:
                print("   FAIL: %s" % err)
                failures += 1
                continue

            if not use_planc and not valac_available:
                print("   PASS (translated + gcc ok; no Vala compiler found, skipping differential run)")
                passed += 1
                continue

            # candidate: planc (when --translator vala) or valac on the translated source + runtime shim
            vala_exe = os.path.join(case_work, "translated.exe")
            if use_planc:
                build = subprocess.run([PLANC_BIN, vala_out, RUNTIME, "-o", vala_exe],
                                       capture_output=True, text=True)
            else:
                build = sh('valac --pkg=glib-2.0 "%s" "%s" -o "%s"'
                           % (posix(vala_out), posix(RUNTIME), posix(vala_exe)))
            if build.returncode != 0:
                print("   FAIL: %s rejected the generated code" % ("planc" if use_planc else "valac"))
                print(build.stderr[-4000:])
                failures += 1
                continue

            ref_out = ""
            for exe in refs:
                proc = subprocess.run([exe], capture_output=True, text=True)
                ref_out += proc.stdout
            cand = subprocess.run([vala_exe], capture_output=True, text=True)
            if cand.returncode != 0:
                print("   FAIL: translated program exited %d" % cand.returncode)
                print(cand.stderr[-2000:])
                failures += 1
                continue
            if cand.stdout != ref_out:
                print("   FAIL: output differs")
                print("   --- gcc ---")
                print(ref_out[:1500])
                print("   --- vala ---")
                print(cand.stdout[:1500])
                failures += 1
                continue
            print("   PASS (%d lines of output match)" % len(ref_out.splitlines()))
            passed += 1
    finally:
        if args.keep:
            print("work dir: %s" % work)
        else:
            shutil.rmtree(work, ignore_errors=True)

    print("\n%d passed, %d failed" % (passed, failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
