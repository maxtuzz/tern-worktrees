#!/usr/bin/env python3
"""Bundle the plugin's Luau modules and tests into one chunk for plain `luau`.

The luau CLI gives every required module its own globals, but the plugin
reads the `tern` global the way Tern installs it. Inlining every module into
one chunk, behind a small require-by-relative-path, lets tests/stub.luau's
`tern` be the global every module sees.

Usage: python3 tests/bundle.py [entry] > /tmp/bundle.luau && luau /tmp/bundle.luau
(entry defaults to "run", a module under tests/)
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = ["lib", "tests"]
TOP = ["host.luau", "window.luau"]


def modules():
    found = [os.path.join(ROOT, f) for f in TOP]
    for d in DIRS:
        for base, _dirs, files in os.walk(os.path.join(ROOT, d)):
            found += [os.path.join(base, f) for f in files if f.endswith(".luau")]
    return sorted(found)


def key(path):
    return os.path.relpath(path, ROOT)[: -len(".luau")]


def body(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    # Types can't be exported from inside a function; at run time they're erased.
    return re.sub(r"^export type ", "type ", src, flags=re.M)


def main():
    out = [
        "local __defs = {}",
        "local __cache = {}",
        "local function __resolve(from, rel)",
        "\tlocal parts = {}",
        "\tfor p in string.gmatch(from, '[^/]+') do table.insert(parts, p) end",
        "\ttable.remove(parts)",
        "\tfor p in string.gmatch(rel, '[^/]+') do",
        "\t\tif p == '..' then table.remove(parts) elseif p ~= '.' then table.insert(parts, p) end",
        "\tend",
        "\tlocal k = table.concat(parts, '/')",
        "\tif __defs[k] == nil and __defs[k .. '/init'] then k = k .. '/init' end",
        "\treturn k",
        "end",
        "local __require",
        "__require = function(from, rel)",
        "\tlocal k = __resolve(from, rel)",
        "\tif __cache[k] == nil then",
        "\t\tlocal def = __defs[k] or error('module not found: ' .. k)",
        "\t\t__cache[k] = def(function(r) return __require(k, r) end) or true",
        "\tend",
        "\treturn __cache[k]",
        "end",
    ]
    for path in modules():
        out.append(f"__defs[{key(path)!r}] = function(require)")
        out.append(body(path))
        out.append("end")
    entry = sys.argv[1] if len(sys.argv) > 1 else "run"
    out.append(f"__require('tests/x', {('./' + entry)!r})")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
