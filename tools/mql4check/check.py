#!/usr/bin/env python3
"""Translate an .mq4 file into C++ that the shim header can compile.

Only the syntactic differences between MQL4 and C++ are rewritten; all
identifiers, expressions and control flow are left untouched so that g++
reports real problems (typos, arity errors, undeclared names, bad types)
at the original line numbers.
"""
import calendar, re, subprocess, sys, datetime as dt

SRC = sys.argv[1]
OUT = sys.argv[2]

src = open(SRC, encoding="utf-8").read()
lines = src.split("\n")


def datetime_literal(text):
    text = text.strip()
    for fmt in ("%Y.%m.%d %H:%M:%S", "%Y.%m.%d %H:%M", "%Y.%m.%d", "%H:%M:%S", "%H:%M"):
        try:
            d = dt.datetime.strptime(text, fmt)
            if "%Y" not in fmt:
                d = d.replace(year=1970, month=1, day=1)
            return str(calendar.timegm(d.timetuple())) + "LL"
        except ValueError:
            continue
    raise SystemExit("unparsable datetime literal: " + text)


out = []
for i, line in enumerate(lines, 1):
    # #property lines have no C++ equivalent
    if re.match(r"\s*#property\b", line):
        out.append("//" + line)
        continue

    # C'r,g,b' colour literals -> 0xBBGGRR
    def col(m):
        r, g, b = int(m.group(1)), int(m.group(2)), int(m.group(3))
        return "0x%06Xu" % ((b << 16) | (g << 8) | r)

    line = re.sub(r"C'(\d+)\s*,\s*(\d+)\s*,\s*(\d+)'", col, line)

    # D'...' datetime literals -> epoch seconds
    line = re.sub(r"D'([^']*)'", lambda m: datetime_literal(m.group(1)), line)

    # dynamic string arrays: "string parts[];" -> MqlStrArray
    line = re.sub(r"^(\s*)string\s+(\w+)\s*\[\s*\]\s*;", r"\1MqlStrArray \2;", line)

    # "input" has no C++ equivalent; leave them as plain globals so a test
    # harness can drive the EA with different settings.
    line = re.sub(r"^(\s*)input\s+", r"\1", line)

    out.append(line)

body = "\n".join(out)

# MQL4 resolves calls regardless of definition order; C++ needs prototypes.
proto_re = re.compile(
    r"^(?P<ret>void|int|bool|double|string|color|datetime|long|uint|ushort)\s+"
    r"(?P<name>\w+)\s*\((?P<args>[^;{)]*)\)\s*$",
    re.MULTILINE,
)
protos = [
    "%s %s(%s);" % (m.group("ret"), m.group("name"), m.group("args"))
    for m in proto_re.finditer(body)
]

APPEND = sys.argv[3] if len(sys.argv) > 3 else None
tail = '\n#line 1 "%s"\n' % APPEND + open(APPEND, encoding="utf-8").read() if APPEND else ""

open(OUT, "w", encoding="utf-8").write(
    '#include "mql4shim.h"\n'
    + "\n".join(protos)
    + '\n#line 1 "%s"\n' % SRC
    + body
    + tail
)

warn = [
    "-Wall", "-Wextra",
    "-Wno-unused-parameter", "-Wno-unused-variable",
    "-Wno-unused-but-set-variable", "-Wno-type-limits",
]
if APPEND:
    cmd = ["g++", "-std=c++17"] + warn + ["-I", ".", OUT, "mql4shim.cpp", "-o", "eatest"]
else:
    cmd = ["g++", "-fsyntax-only", "-std=c++17"] + warn + ["-I", ".", OUT]
sys.exit(subprocess.call(cmd))
