#!/usr/bin/env python3
"""QEMU regression harness for PlanetOS.

Builds the system once (through run-qemu.sh or run-qemu.ps1 -BuildOnly), then
boots the kernel headless for every case under tests/cases, types the case
script into the guest shell over the serial console and checks the output
against the companion .expect file.

Usage:
    python tests/qemu.py                # build + run every case
    python tests/qemu.py --no-build     # reuse the last build
    python tests/qemu.py --case exec    # one case
    python tests/qemu.py --list         # list cases
    python tests/qemu.py --verbose      # always print the serial output

.expect syntax (one assertion per line, '#' starts a comment):
    text      substring that must appear, after the previous match
    =text     a whole output line must equal text
    !text     text must not appear anywhere
    ~regex    Python regex that must match, after the previous match
"""

import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CASES_DIR = os.path.join(HERE, "cases")

PROMPT = "🪐 : "

# Cases whose guest-side frame/timing budget assumes TCG speed when --accel=auto.
TCG_AUTO_CASES = {"compositor-ext"}
# Cases whose guest needs the whole machine: they run a server thread and talk
# to it over the SLIRP network, and with several QEMU instances competing for
# host cores their deadlines expire. They run alone, after the parallel batch.
SERIAL_CASES = {"curl", "mercury"}


def die(message):
    sys.stderr.write("qemu-tests: %s\n" % message)
    sys.exit(1)


def read_text(path):
    with open(path, "r", encoding="utf-8-sig") as handle:
        return handle.read()


def default_out_dir():
    env = os.environ.get("PLANETOS_OUT")
    if env:
        return env
    if os.name == "nt":
        candidates = [
            os.environ.get("MSYS2_ROOT"),
            r"C:\msys64",
            os.path.join(os.environ.get("USERPROFILE", ""), "msys64"),
            os.path.join(os.environ.get("LOCALAPPDATA", ""), "msys64"),
        ]
        for base in candidates:
            if base and os.path.isdir(os.path.join(base, "usr", "bin")):
                return os.path.join(base, "tmp", "planetos-qemu")
    return "/tmp/planetos-qemu"


def default_qemu():
    env = os.environ.get("PLANETOS_QEMU")
    if env:
        return env
    if os.name == "nt":
        candidate = os.path.normpath(
            os.path.join(default_out_dir(), "..", "..", "ucrt64", "bin",
                         "qemu-system-x86_64.exe"))
        if os.path.isfile(candidate):
            return candidate
    return "qemu-system-x86_64"


def build_system():
    if os.name == "nt":
        launcher = [
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", os.path.join(ROOT, "run-qemu.ps1"), "-BuildOnly",
        ]
    else:
        launcher = ["bash", os.path.join(ROOT, "run-qemu.sh"), "--build-only"]

    print("== build ==")
    proc = subprocess.run(launcher, cwd=ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != 0:
        sys.stdout.write(text)
        die("build failed (exit %d)" % proc.returncode)

    out_dir = None
    qemu = None
    for line in text.splitlines():
        if line.startswith("PLANETOS_OUT="):
            out_dir = line.split("=", 1)[1].strip()
        elif line.startswith("PLANETOS_QEMU="):
            qemu = line.split("=", 1)[1].strip()
    if not out_dir or not qemu:
        sys.stdout.write(text)
        die("the launcher did not report PLANETOS_OUT/PLANETOS_QEMU")
    print("   build dir: %s" % out_dir)
    print("   qemu:      %s" % qemu)
    return out_dir, qemu


def list_cases():
    names = []
    for entry in sorted(os.listdir(CASES_DIR)):
        if entry.endswith(".sh"):
            names.append(entry[:-3])
    return names


def parse_expect(path):
    checks = []
    if not os.path.isfile(path):
        return checks
    for raw in read_text(path).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("!"):
            checks.append(("not", line[1:]))
        elif line.startswith("="):
            checks.append(("line", line[1:]))
        elif line.startswith("~"):
            checks.append(("re", line[1:]))
        else:
            checks.append(("text", line))
    return checks


def qemu_path(path):
    return path.replace("\\", "/")


def default_accel():
    if os.name != "nt" and os.access("/dev/kvm", os.R_OK | os.W_OK):
        return "kvm"
    return "tcg"


def run_guest(qemu, out_dir, commands, delay, boot_timeout, command_timeout,
              accel="auto"):
    kernel = os.path.join(out_dir, "planet-kernel")
    disk = os.path.join(out_dir, "disk.img")
    if not os.path.isfile(kernel) or not os.path.isfile(disk):
        die("missing kernel or disk image in %s (run without --no-build)" % out_dir)

    resolved_accel = default_accel() if accel == "auto" else accel
    argv = [
        qemu,
        "-accel", resolved_accel,
        "-cpu", "max",
        "-kernel", qemu_path(kernel),
        "-drive", "file=%s,format=raw,if=ide,file.locking=off" % qemu_path(disk),
        "-snapshot",
        # C2: the same image is exposed again as a read-only virtio-blk device,
        # so the IRQ-driven block path is exercised alongside ATA.
        "-drive", "file=%s,format=raw,if=none,id=vd0,readonly=on,file.locking=off" % qemu_path(disk),
        "-device", "virtio-blk-pci,drive=vd0",
        "-netdev", "user,id=net0",
        "-device", "virtio-net-pci,netdev=net0",
        "-vga", "std",
        "-display", "none",
        "-serial", "mon:stdio",
        "-no-reboot",
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
    ]
    env = os.environ.copy()
    qemu_dir = os.path.dirname(qemu)
    if qemu_dir:
        env["PATH"] = qemu_dir + os.pathsep + env.get("PATH", "")

    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, bufsize=0, env=env)

    output = bytearray()
    cond = threading.Condition()
    finished = False

    def reader():
        nonlocal finished
        fd = proc.stdout.fileno()
        while True:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            with cond:
                output.extend(chunk)
                cond.notify_all()
        with cond:
            finished = True
            cond.notify_all()

    reader_thread = threading.Thread(target=reader, daemon=True)
    reader_thread.start()

    def text_unlocked():
        return output.decode("utf-8", "replace")

    def text():
        with cond:
            return text_unlocked()

    def wait_prompts(count, timeout):
        deadline = time.monotonic() + timeout
        with cond:
            while True:
                if text_unlocked().count(PROMPT) >= count:
                    return True
                if finished:
                    return False
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                cond.wait(timeout=remaining)

    def send_line(line):
        for char in line:
            try:
                proc.stdin.write(char.encode("utf-8"))
                proc.stdin.flush()
            except OSError:
                return
            time.sleep(delay)
        try:
            proc.stdin.write(b"\n")
            proc.stdin.flush()
        except OSError:
            pass

    error = None
    try:
        if not wait_prompts(1, boot_timeout):
            error = "the guest shell did not reach the prompt"
        else:
            prompts = 1
            for command in commands:
                send_line(command)
                prompts = prompts + 1
                if not wait_prompts(prompts, command_timeout):
                    error = "no prompt after %r" % command
                    break
            if error is None:
                send_line("exit")
                try:
                    proc.wait(timeout=command_timeout)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    error = "the guest did not exit"
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        reader_thread.join(timeout=5)

    return text(), error


def check_output(output, checks):
    failures = []
    position = 0
    for kind, value in checks:
        if kind == "not":
            if value in output:
                failures.append("unexpected text: %r" % value)
            continue
        if kind == "re":
            match = re.compile(value).search(output, position)
            if match is None:
                failures.append("missing regex: %s" % value)
            else:
                position = match.end()
            continue
        if kind == "line":
            found = False
            for line in output.splitlines():
                if line.rstrip("\r") == value:
                    found = True
                    break
            if not found:
                failures.append("missing line: %r" % value)
            continue
        index = output.find(value, position)
        if index < 0:
            failures.append("missing text: %r" % value)
        else:
            position = index + len(value)
    return failures


def load_case(name):
    script_path = os.path.join(CASES_DIR, name + ".sh")
    commands = []
    for raw in read_text(script_path).splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        commands.append(line)
    checks = parse_expect(os.path.join(CASES_DIR, name + ".expect"))
    return commands, checks


def run_case(name, qemu, out_dir, args):
    commands, checks = load_case(name)
    case_accel = "tcg" if (args.accel == "auto" and name in TCG_AUTO_CASES) else args.accel
    output, error = run_guest(qemu, out_dir, commands, args.delay,
                              args.boot_timeout, args.command_timeout,
                              accel=case_accel)
    problems = [error] if error else check_output(output, checks)
    return name, len(commands), len(checks), output, problems


def main():
    parser = argparse.ArgumentParser(description="PlanetOS QEMU regression tests")
    parser.add_argument("--case", action="append", help="run only this case (repeatable)")
    parser.add_argument("--list", action="store_true", help="list available cases")
    parser.add_argument("--no-build", action="store_true", help="reuse the last build")
    parser.add_argument("--keep-going", action="store_true", help="run every case after a failure")
    parser.add_argument("--verbose", action="store_true", help="print the serial output")
    parser.add_argument("--delay", type=float, default=0.005,
                        help="seconds between typed characters (default: 0.005)")
    parser.add_argument("--jobs", "-j", type=int, default=0,
                        help="parallel QEMU workers (default: 0 = auto, up to CPU count)")
    parser.add_argument("--accel", choices=("auto", "kvm", "tcg"), default="auto",
                        help="QEMU accelerator (default: auto, uses kvm when /dev/kvm is accessible)")
    parser.add_argument("--boot-timeout", type=float, default=180.0)
    parser.add_argument("--command-timeout", type=float, default=120.0)
    args = parser.parse_args()

    available = list_cases()
    if args.list:
        for name in available:
            print(name)
        return 0
    if not available:
        die("no cases in %s" % CASES_DIR)

    selected = args.case if args.case else available
    for name in selected:
        if name not in available:
            die("unknown case %r (available: %s)" % (name, ", ".join(available)))

    if args.no_build:
        out_dir = default_out_dir()
        qemu = default_qemu()
        print("== reuse build ==")
        print("   build dir: %s" % out_dir)
        print("   qemu:      %s" % qemu)
    else:
        out_dir, qemu = build_system()

    jobs = args.jobs if args.jobs > 0 else min(len(selected), os.cpu_count() or 4)
    resolved_accel = default_accel() if args.accel == "auto" else args.accel
    print("   accel:     %s" % resolved_accel)
    print("   jobs:      %d" % jobs)

    serial = [name for name in selected if name in SERIAL_CASES]
    parallel = [name for name in selected if name not in SERIAL_CASES]
    if not parallel:
        jobs = 1

    failures = 0
    abort = threading.Event()

    def report(name, n_cmds, n_checks, output, problems):
        nonlocal failures
        print("== case %s (%d commands, %d checks) ==" % (name, n_cmds, n_checks),
              flush=True)
        if problems:
            failures += 1
            print("FAIL %s" % name, flush=True)
            for problem in problems:
                print("   - %s" % problem, flush=True)
            print("--- serial ---", flush=True)
            sys.stdout.write(output)
            print("--------------", flush=True)
            if not args.keep_going:
                abort.set()
        else:
            print("PASS %s" % name, flush=True)
            if args.verbose:
                sys.stdout.write(output)

    if jobs == 1:
        for name in parallel + serial:
            if abort.is_set() and not args.keep_going:
                break
            report(*run_case(name, qemu, out_dir, args))
    else:
        def worker(case_name):
            if abort.is_set():
                return None
            return run_case(case_name, qemu, out_dir, args)

        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = [executor.submit(worker, name) for name in parallel]
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                if result is not None:
                    report(*result)
                if abort.is_set():
                    for pending in futures:
                        pending.cancel()
                    break
        if args.keep_going or not abort.is_set():
            for name in serial:
                report(*run_case(name, qemu, out_dir, args))

    total = len(selected)
    print("\n%d/%d cases passed" % (total - failures, total))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(errors="replace")
    except AttributeError:
        pass
    sys.exit(main())
