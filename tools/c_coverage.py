#!/usr/bin/env python3
"""Measures how much C code a C -> Vala translation could actually handle.

Every translation unit is run through a real preprocessor (gcc -E) and then
through pycparser, and the AST is classified in three tiers:

  tier 0  translates directly          functions, scalars, arrays, arithmetic,
                                       if/while/for/do, calls, casts, sizeof
  tier 1  needs a mechanical rewrite   pointers, structs, enums, typedefs,
                                       switch, initializer lists
  tier 2  blocks a faithful translation
                                       unions, bitfields, varargs, function
                                       pointers, goto/labels, VLAs, _Atomic,
                                       setjmp/longjmp, inline asm

The interesting number is not "how many lines" but:

  * clean functions  -> functions whose body has no tier-2 construct
  * libc histogram   -> the shopping list for a runtime shim

Usage:
    python tools/c_coverage.py tools/corpus
    python tools/c_coverage.py /tmp/corpus --json /tmp/cov.json
    python tools/c_coverage.py foo.c -I include -I third_party

Requires: pycparser (pure Python) and any preprocessor, gcc by default.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

try:
    import pycparser
    from pycparser import c_ast, c_parser
except ImportError:  # pragma: no cover
    sys.stderr.write("c_coverage: pycparser is required (pip install pycparser)\n")
    sys.exit(2)

# Minimal fake libc: enough declarations to parse code whose logic we want to
# measure, without dragging in real system headers (which use GCC extensions).
FAKE_HEADERS = {
    "stddef.h": """#ifndef PLANETOS_STDDEF_H
#define PLANETOS_STDDEF_H
typedef unsigned long size_t;
typedef long ptrdiff_t;
typedef int wchar_t;
#define NULL ((void*)0)
#define offsetof(t, m) 0
#endif
""",
    "stdint.h": """#include <stddef.h>
#ifndef PLANETOS_STDINT_H
#define PLANETOS_STDINT_H
typedef signed char int8_t;
typedef unsigned char uint8_t;
typedef short int16_t;
typedef unsigned short uint16_t;
typedef int int32_t;
typedef unsigned int uint32_t;
typedef long int64_t;
typedef unsigned long uint64_t;
typedef long intptr_t;
typedef unsigned long uintptr_t;
#define INT8_MAX 127
#define UINT8_MAX 255
#define INT32_MAX 2147483647
#define UINT32_MAX 4294967295U
#endif
""",
    "stdbool.h": """#ifndef PLANETOS_STDBOOL_H
#define PLANETOS_STDBOOL_H
#define bool _Bool
#define true 1
#define false 0
#endif
""",
    "stdarg.h": """#ifndef PLANETOS_STDARG_H
#define PLANETOS_STDARG_H
typedef struct { int x; } va_list;
#define va_start(a, b)
#define va_end(a)
#define va_arg(a, t) ((t)0)
#define va_copy(a, b)
#endif
""",
    "stdio.h": """#include <stddef.h>
#ifndef PLANETOS_STDIO_H
#define PLANETOS_STDIO_H
typedef struct _FILE FILE;
int printf(const char*, ...);
int fprintf(FILE*, const char*, ...);
int sprintf(char*, const char*, ...);
int snprintf(char*, size_t, const char*, ...);
int puts(const char*);
int fputs(const char*, FILE*);
int putchar(int);
int scanf(const char*, ...);
int sscanf(const char*, const char*, ...);
FILE* fopen(const char*, const char*);
int fclose(FILE*);
size_t fread(void*, size_t, size_t, FILE*);
size_t fwrite(const void*, size_t, size_t, FILE*);
int fgetc(FILE*);
int fputc(int, FILE*);
char* fgets(char*, int, FILE*);
int fseek(FILE*, long, int);
long ftell(FILE*);
int feof(FILE*);
int fflush(FILE*);
extern FILE* stdin;
extern FILE* stdout;
extern FILE* stderr;
#define EOF -1
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif
""",
    "stdlib.h": """#include <stddef.h>
#ifndef PLANETOS_STDLIB_H
#define PLANETOS_STDLIB_H
void* malloc(size_t);
void* calloc(size_t, size_t);
void* realloc(void*, size_t);
void free(void*);
void exit(int);
void abort(void);
int atoi(const char*);
long atol(const char*);
double atof(const char*);
long strtol(const char*, char**, int);
unsigned long strtoul(const char*, char**, int);
int abs(int);
long labs(long);
void qsort(void*, size_t, size_t, void*);
void* bsearch(const void*, const void*, size_t, size_t, void*);
char* getenv(const char*);
int rand(void);
void srand(unsigned int);
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#endif
""",
    "string.h": """#include <stddef.h>
#ifndef PLANETOS_STRING_H
#define PLANETOS_STRING_H
size_t strlen(const char*);
int strcmp(const char*, const char*);
int strncmp(const char*, const char*, size_t);
char* strcpy(char*, const char*);
char* strncpy(char*, const char*, size_t);
char* strcat(char*, const char*);
char* strchr(const char*, int);
char* strrchr(const char*, int);
char* strstr(const char*, const char*);
void* memcpy(void*, const void*, size_t);
void* memmove(void*, const void*, size_t);
void* memset(void*, int, size_t);
int memcmp(const void*, const void*, size_t);
char* strdup(const char*);
char* strerror(int);
char* strtok(char*, const char*);
#endif
""",
    "math.h": """#include <stddef.h>
#ifndef PLANETOS_MATH_H
#define PLANETOS_MATH_H
double sin(double);
double cos(double);
double tan(double);
double sqrt(double);
double pow(double, double);
double fabs(double);
double floor(double);
double ceil(double);
double fmod(double, double);
double log(double);
double exp(double);
double atan2(double, double);
float sqrtf(float);
float fabsf(float);
float powf(float, float);
#define M_PI 3.14159265358979323846
#endif
""",
    "ctype.h": """#include <stddef.h>
#ifndef PLANETOS_CTYPE_H
#define PLANETOS_CTYPE_H
int isalpha(int);
int isdigit(int);
int isspace(int);
int isupper(int);
int islower(int);
int isalnum(int);
int isprint(int);
int tolower(int);
int toupper(int);
#endif
""",
    "time.h": """#include <stddef.h>
#ifndef PLANETOS_TIME_H
#define PLANETOS_TIME_H
typedef long time_t;
typedef long clock_t;
time_t time(time_t*);
clock_t clock(void);
struct tm { int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst; };
struct tm* localtime(const time_t*);
size_t strftime(char*, size_t, const char*, const struct tm*);
#define CLOCKS_PER_SEC 1000000
#endif
""",
    "limits.h": """#ifndef PLANETOS_LIMITS_H
#define PLANETOS_LIMITS_H
#define CHAR_BIT 8
#define INT_MAX 2147483647
#define INT_MIN (-2147483647-1)
#define UINT_MAX 4294967295U
#define SCHAR_MAX 127
#define UCHAR_MAX 255
#define SHRT_MAX 32767
#define USHRT_MAX 65535
#define LONG_MAX 9223372036854775807L
#endif
""",
    "assert.h": """#ifndef PLANETOS_ASSERT_H
#define PLANETOS_ASSERT_H
#define assert(x) ((void)0)
#endif
""",
    "errno.h": """#ifndef PLANETOS_ERRNO_H
#define PLANETOS_ERRNO_H
extern int errno;
#define EINVAL 22
#define ENOMEM 12
#define ENOENT 2
#endif
""",
    "float.h": """#ifndef PLANETOS_FLOAT_H
#define PLANETOS_FLOAT_H
#define FLT_MAX 3.40282347e+38F
#define DBL_MAX 1.7976931348623157e+308
#endif
""",
    "xmmintrin.h": """#include <stddef.h>
#ifndef PLANETOS_XMMINTRIN_H
#define PLANETOS_XMMINTRIN_H
typedef union { float f[4]; int i[4]; } __m128;
#endif
""",
    "emmintrin.h": """#include <stddef.h>
#ifndef PLANETOS_EMMINTRIN_H
#define PLANETOS_EMMINTRIN_H
#include <xmmintrin.h>
typedef union { double d[2]; long long q[2]; int i[4]; } __m128d;
typedef union { long long q[2]; int i[4]; short s[8]; } __m128i;
#endif
""",
    "immintrin.h": """#include <stddef.h>
#ifndef PLANETOS_IMMINTRIN_H
#define PLANETOS_IMMINTRIN_H
#include <emmintrin.h>
typedef union { float f[8]; } __m256;
typedef union { double d[4]; } __m256d;
typedef union { long long q[4]; int i[8]; } __m256i;
#endif
""",}

# GCC-isms that are not C and that pycparser refuses. Stripping them does not
# change the constructs we measure (they are attributes, not control flow).
SIMPLE_SUBS = [
    ("__extension__", ""),
    ("__inline__", "inline"),
    ("__inline", "inline"),
    ("__restrict__", ""),
    ("__restrict", ""),
    ("__const", "const"),
    ("__volatile__", "volatile"),
    ("__signed__", "signed"),
    ("__builtin_va_list", "va_list"),
    ("__BEGIN_DECLS", ""),
    ("__END_DECLS", ""),
]

BLOCKER_NAMES = {
    "union": "unions",
    "bitfield": "bitfields",
    "varargs": "varargs",
    "funcptr": "function pointers",
    "goto": "goto",
    "label": "labels",
    "vla": "variable-length arrays",
    "atomic": "_Atomic",
    "setjmp": "setjmp/longjmp",
    "asm": "inline asm",
    "simd": "SIMD intrinsics (SSE/AVX)",
}


def strip_balanced(src, token):
    """Removes `token (...)` with balanced parentheses."""
    out = []
    i, n, changed = 0, len(src), 0
    while True:
        j = src.find(token, i)
        if j < 0:
            out.append(src[i:])
            break
        out.append(src[i:j])
        k = src.find("(", j)
        if k < 0:
            i = j + len(token)
            continue
        depth, m = 0, k
        while m < n:
            if src[m] == "(":
                depth += 1
            elif src[m] == ")":
                depth -= 1
                if depth == 0:
                    break
            m += 1
        i = m + 1
        changed += 1
    return "".join(out), changed


def sanitize(src):
    total = 0
    src, n = strip_balanced(src, "__attribute__")
    total += n
    src, n = strip_balanced(src, "__attribute")
    total += n
    src, n = strip_balanced(src, "__declspec")
    total += n
    for old, new in SIMPLE_SUBS:
        if old in src:
            src = src.replace(old, new)
            total += 1
    return src, total


def name_of(node):
    if isinstance(node, c_ast.ID):
        return node.name
    if isinstance(node, c_ast.StructRef):
        base = name_of(node.name)
        member = node.type.name if hasattr(node.type, "name") else str(node.type)
        return (base + "." + member) if base else member
    return "?"


class Scan(c_ast.NodeVisitor):
    """Counts blockers (tier 2) and transformable features (tier 1)."""

    def __init__(self, fp_names=None, func_names=None, allowed_lines=None):
        self.blockers = Counter()
        self.features = Counter()
        self.calls = Counter()
        self.fp_names = fp_names or set()
        self.func_names = func_names or set()
        self.allowed_lines = allowed_lines

    def visit(self, node):
        # Provenance filter: skip nodes emitted by the fake libc headers so the
        # numbers describe the project's own code, not our header stubs.
        if self.allowed_lines is not None:
            coord = getattr(node, "coord", None)
            if coord is not None and coord.line is not None and coord.line not in self.allowed_lines:
                return
        super().visit(node)

    def visit_Union(self, node):
        self.blockers["union"] += 1
        self.generic_visit(node)

    def visit_Decl(self, node):
        if getattr(node, "bitsize", None) is not None:
            self.blockers["bitfield"] += 1
        t = node.type
        if isinstance(t, c_ast.PtrDecl) and isinstance(t.type, c_ast.FuncDecl):
            self.blockers["funcptr"] += 1
        if isinstance(t, c_ast.TypeDecl) and t.quals and "_Atomic" in t.quals:
            self.blockers["atomic"] += 1
        if isinstance(t, c_ast.TypeDecl) and isinstance(t.type, c_ast.IdentifierType):
            if t.type.names and t.type.names[0].startswith(("__m128", "__m256", "__m512")):
                self.blockers["simd"] += 1
        self.generic_visit(node)

    def visit_Typedef(self, node):
        self.features["typedef"] += 1
        t = node.type
        if isinstance(t, c_ast.PtrDecl) and isinstance(t.type, c_ast.FuncDecl):
            self.blockers["funcptr"] += 1
        self.generic_visit(node)

    def visit_EllipsisParam(self, node):
        self.blockers["varargs"] += 1

    def visit_Goto(self, node):
        self.blockers["goto"] += 1
        self.generic_visit(node)

    def visit_Label(self, node):
        self.blockers["label"] += 1
        self.generic_visit(node)

    def visit_ArrayDecl(self, node):
        if node.dim is not None and not isinstance(node.dim, c_ast.Constant):
            self.blockers["vla"] += 1
        self.features["array"] += 1
        self.generic_visit(node)

    def visit_PtrDecl(self, node):
        self.features["pointer"] += 1
        self.generic_visit(node)

    def visit_Struct(self, node):
        self.features["struct"] += 1
        self.generic_visit(node)

    def visit_Enum(self, node):
        self.features["enum"] += 1
        self.generic_visit(node)

    def visit_Switch(self, node):
        self.features["switch"] += 1
        self.generic_visit(node)

    def visit_InitList(self, node):
        self.features["initializer"] += 1
        self.generic_visit(node)

    def visit_Cast(self, node):
        self.features["cast"] += 1
        self.generic_visit(node)

    def visit_UnaryOp(self, node):
        if node.op == "sizeof":
            self.features["sizeof"] += 1
        self.generic_visit(node)

    def visit_FuncCall(self, node):
        fn = name_of(node.name)
        self.features["call"] += 1
        self.calls[fn] += 1
        if fn in ("setjmp", "longjmp", "_setjmp", "sigsetjmp"):
            self.blockers["setjmp"] += 1
        if fn.startswith(("_mm_", "_mm256_", "_mm512_")):
            self.blockers["simd"] += 1
        if fn in self.fp_names:
            self.blockers["funcptr"] += 1
        if isinstance(node.name, c_ast.ID):
            # do not treat the callee as an address-taken function
            for arg in node.args or []:
                self.visit(arg)
            return
        self.generic_visit(node)

    def visit_ID(self, node):
        if node.name in self.func_names:
            self.blockers["funcptr"] += 1


def collect_units(paths):
    units = []
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in sorted(files):
                    if f.endswith((".c", ".h")):
                        units.append(os.path.join(root, f))
        elif os.path.isfile(p):
            units.append(p)
        else:
            sys.stderr.write("c_coverage: skipping missing path %s\n" % p)
    return units


def prepare_includes(workdir):
    fake = os.path.join(workdir, "fake_libc")
    os.makedirs(fake, exist_ok=True)
    for name, body in FAKE_HEADERS.items():
        with open(os.path.join(fake, name), "w", encoding="utf-8") as fh:
            fh.write(body)
    stubs = os.path.join(workdir, "stubs")
    os.makedirs(stubs, exist_ok=True)
    return fake, stubs


INCLUDE_RE = re.compile(r"fatal error: ([^\s:]+): No such file or directory")
MARKER_RE = re.compile(r'^#\s+\d+\s+"([^"]*)"')


def is_stub_file(path, excluded_dirs):
    ap = os.path.abspath(path).replace("\\", "/")
    for d in excluded_dirs:
        dp = os.path.abspath(d).replace("\\", "/")
        if ap == dp or ap.startswith(dp + "/"):
            return True
    return False


def preprocess(path, cc, fake, stubs, includes, defines=None, autostub=True, attempts=40):
    """Preprocesses with the fake libc, auto-stubbing unknown headers.

    Returns (parse_text, allowed_lines, error). `allowed_lines` holds the line
    numbers of the preprocessed text that come from project code, so the
    analysis can ignore everything our fake headers contributed.
    """
    src_dir = os.path.dirname(os.path.abspath(path))
    stubbed = []
    for _ in range(attempts):
        cmd = [cc, "-E", "-nostdinc", "-I", fake, "-I", stubs, "-I", src_dir]
        for inc in includes:
            cmd += ["-I", inc]
        for d in (defines or []):
            cmd += ["-D", d]
        cmd.append(path)
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return None, None, "preprocessor failed: %s" % exc, stubbed
        if proc.returncode == 0:
            text, allowed = split_by_provenance(proc.stdout, [fake, stubs])
            return text, allowed, None, stubbed
        match = INCLUDE_RE.search(proc.stderr)
        if not (autostub and match):
            first = proc.stderr.strip().splitlines()
            return None, None, "preprocess error: %s" % (first[0] if first else "unknown"), stubbed
        missing = match.group(1)
        target = os.path.join(stubs, missing)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.exists(target):
            first = proc.stderr.strip().splitlines()
            return None, None, "preprocess error: %s" % (first[0] if first else "unknown"), stubbed
        stubbed.append(missing)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("/* auto-generated stub for %s */\n" % missing)
    return None, None, "too many missing headers", stubbed


def split_by_provenance(text, excluded_dirs):
    """Blanks out #line markers (keeping line numbers) and records which lines
    belong to project code rather than to the fake/stub headers."""
    lines = []
    allowed = set()
    keep = True
    for raw in text.splitlines():
        m = MARKER_RE.match(raw)
        if m:
            keep = not is_stub_file(m.group(1), excluded_dirs)
            lines.append("")
            continue
        if keep:
            allowed.add(len(lines) + 1)
        lines.append(raw)
    return "\n".join(lines), allowed


def analyze(path, cc, fake, stubs, includes, max_lines, autostub, defines=None):
    result = {
        "path": path,
        "bytes": os.path.getsize(path) if os.path.isfile(path) else 0,
        "status": "ok",
        "error": "",
        "functions": 0,
        "clean_functions": 0,
        "blockers": {},
        "features": {},
        "calls": {},
        "sanitized": 0,
        "stubbed_headers": [],
    }
    text, allowed, err, stubbed = preprocess(path, cc, fake, stubs, includes, defines=defines, autostub=autostub)
    result["stubbed_headers"] = stubbed
    if text is None:
        result["status"] = "preprocess-failed"
        result["error"] = err
        return result
    lines = text.count("\n") + 1
    if lines > max_lines:
        result["status"] = "skipped"
        result["error"] = "preprocessed to %d lines (limit %d)" % (lines, max_lines)
        return result
    text, subs = sanitize(text)
    result["sanitized"] = subs

    parser = c_parser.CParser()
    try:
        ast = parser.parse(text, filename=os.path.basename(path))
    except Exception as exc:  # pycparser raises ParseError with a message
        result["status"] = "parse-failed"
        result["error"] = str(exc).strip().splitlines()[0][:200]
        return result

    global_scan = Scan(allowed_lines=allowed)
    for ext in ast.ext:
        if isinstance(ext, c_ast.FuncDef):
            continue
        global_scan.visit(ext)

    # Function pointers need name tracking: a typedef'd callback type, a
    # parameter declared with it, and any address-taken function name.
    fp_typedefs = set()
    for ext in ast.ext:
        if isinstance(ext, c_ast.Typedef) and isinstance(ext.type, c_ast.PtrDecl) \
                and isinstance(ext.type.type, c_ast.FuncDecl):
            fp_typedefs.add(ext.name)

    fp_globals = set()

    def note_fp_decl(decl):
        t = decl.type
        if isinstance(t, c_ast.PtrDecl) and isinstance(t.type, c_ast.FuncDecl):
            fp_globals.add(decl.name)
        elif isinstance(t, c_ast.TypeDecl) and isinstance(t.type, c_ast.IdentifierType):
            if t.type.names and t.type.names[0] in fp_typedefs:
                fp_globals.add(decl.name)

    for ext in ast.ext:
        if isinstance(ext, c_ast.Decl):
            note_fp_decl(ext)

    func_names = set()
    for ext in ast.ext:
        if isinstance(ext, c_ast.FuncDef):
            func_names.add(ext.decl.name)

    blockers = Counter(global_scan.blockers)
    features = Counter(global_scan.features)
    calls = Counter(global_scan.calls)
    functions = 0
    clean = 0
    for ext in ast.ext:
        if not isinstance(ext, c_ast.FuncDef):
            continue
        functions += 1
        fp_names = set(fp_globals)
        params = ext.decl.type.args
        if params is not None:
            for p in params.params:
                note_param = p
                t = getattr(note_param, "type", None)
                if isinstance(t, c_ast.PtrDecl) and isinstance(t.type, c_ast.FuncDecl):
                    fp_names.add(p.name)
                elif isinstance(t, c_ast.TypeDecl) and isinstance(t.type, c_ast.IdentifierType):
                    if t.type.names and t.type.names[0] in fp_typedefs:
                        fp_names.add(p.name)
        scan = Scan(fp_names=fp_names, func_names=func_names, allowed_lines=allowed)
        scan.visit(ext)
        blockers.update(scan.blockers)
        features.update(scan.features)
        calls.update(scan.calls)
        if not scan.blockers:
            clean += 1

    result["functions"] = functions
    result["clean_functions"] = clean
    result["blockers"] = dict(blockers)
    result["features"] = dict(features)
    result["calls"] = dict(calls)
    return result


def main(argv):
    ap = argparse.ArgumentParser(description="C -> Vala feasibility probe")
    ap.add_argument("paths", nargs="+", help="files or directories of C sources")
    ap.add_argument("-I", "--include", action="append", default=[], help="extra include dir")
    ap.add_argument("-D", "--define", action="append", default=[], help="preprocessor define")
    ap.add_argument("--cc", default="gcc", help="preprocessor driver (default: gcc)")
    ap.add_argument("--json", help="write the full report as JSON to this file")
    ap.add_argument("--max-lines", type=int, default=400000,
                    help="skip units that preprocess to more lines than this")
    ap.add_argument("--no-autostub", action="store_true",
                    help="do not create empty headers for missing includes")
    ap.add_argument("--top", type=int, default=15, help="rows in the histograms")
    ap.add_argument("--quiet", action="store_true", help="only the summary")
    args = ap.parse_args(argv)

    units = collect_units(args.paths)
    if not units:
        sys.stderr.write("c_coverage: no C files found\n")
        return 2

    workdir = tempfile.mkdtemp(prefix="c-coverage-")
    try:
        fake, stubs = prepare_includes(workdir)
        reports = []
        for path in units:
            rep = analyze(path, args.cc, fake, stubs, args.include, args.max_lines,
                          autostub=not args.no_autostub, defines=args.define)
            reports.append(rep)
            if not args.quiet:
                if rep["status"] == "ok":
                    pct = (100 * rep["clean_functions"] // rep["functions"]) if rep["functions"] else 100
                    extra = ""
                    if rep["stubbed_headers"]:
                        extra = " stubs=%d" % len(rep["stubbed_headers"])
                    print("  ok    %-42s funcs=%-4d clean=%-4d (%3d%%) tier2=%d%s"
                          % (os.path.basename(rep["path"])[:42], rep["functions"],
                             rep["clean_functions"], pct, sum(rep["blockers"].values()), extra))
                else:
                    extra = ""
                    if rep["stubbed_headers"]:
                        extra = " stubs=%d" % len(rep["stubbed_headers"])
                    print("  %-5s %-42s %s%s" % (rep["status"].replace("-failed", ""),
                                               os.path.basename(rep["path"])[:42], rep["error"], extra))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    ok = [r for r in reports if r["status"] == "ok"]
    failed = [r for r in reports if r["status"] != "ok"]
    total_funcs = sum(r["functions"] for r in ok)
    clean_funcs = sum(r["clean_functions"] for r in ok)
    blockers = Counter()
    features = Counter()
    calls = Counter()
    for r in ok:
        blockers.update(r["blockers"])
        features.update(r["features"])
        calls.update(r["calls"])

    print()
    print("== summary ==")
    print("  units            : %d ok, %d unparsed" % (len(ok), len(failed)))
    print("  functions        : %d" % total_funcs)
    if total_funcs:
        print("  clean functions  : %d (%.1f%%)" % (clean_funcs, 100.0 * clean_funcs / total_funcs))
    files_clean = sum(1 for r in ok if not r["blockers"])
    print("  units with no tier-2 construct: %d/%d" % (files_clean, len(ok)))

    if blockers:
        print("\n  tier-2 blockers:")
        for key, count in blockers.most_common(args.top):
            print("    %-22s %d" % (BLOCKER_NAMES.get(key, key), count))
    if features:
        print("\n  tier-1 features (mechanical rewrite):")
        for key, count in features.most_common(args.top):
            print("    %-22s %d" % (key, count))
    if calls:
        print("\n  most called functions (runtime shim shopping list):")
        for key, count in calls.most_common(args.top):
            print("    %-22s %d" % (key, count))

    if args.json:
        payload = {
            "units": reports,
            "summary": {
                "units_ok": len(ok),
                "units_failed": len(failed),
                "functions": total_funcs,
                "clean_functions": clean_funcs,
                "units_without_blockers": files_clean,
                "blockers": dict(blockers),
                "features": dict(features),
                "calls": dict(calls),
            },
        }
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
        print("\n  json: %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
