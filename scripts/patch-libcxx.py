#!/usr/bin/env python3
"""Neutralise libc++ "explicit ABI annotations" in every vendored Frida SDK.

Why
---
Frida ships prebuilt libc++ headers whose ``__configuration/namespace.h``
wraps large parts of the standard library in::

    #pragma clang attribute push (__attribute__((__visibility__("hidden"), ...)), ...)

Apple clang on GitHub's macOS runners (Xcode 16.4 / 26.3 -> Apple clang 17)
rejects ``__visibility__`` inside ``#pragma clang attribute``::

    error: attribute '__visibility__' is not supported by '#pragma clang attribute'
    error: '#pragma clang attribute pop' with no matching '#pragma clang attribute push'

The vendored ``compiler.h`` even warns "Libc++ only supports AppleClang 26.4
and later", and no Xcode 26.4 image exists on ``macos-15-intel`` (highest is
26.3), so switching Xcode cannot fix this. Replacing the two macros with empty
definitions removes only a symbol-visibility hint, not any runtime behaviour.

Timing
------
``--host=ios-arm64e`` produces a fat arm64 + arm64e binary. ``./configure``
only downloads ``sdk-ios-arm64e`` and ``sdk-macos-x86_64``;
``deps/sdk-ios-arm64`` is materialised later, while a nested ninja invocation
builds the arm64 slice (its own ``[1/313]`` job list). A single patch right
after configure therefore misses it. This script is:

  * idempotent    - a header is rewritten only while it still has the pragma
  * race-safe     - an exclusive flock serialises concurrent compiler calls
  * watch-capable - ``--watch`` keeps patching SDKs that appear mid-build

Usage::

    patch-libcxx.py DEPS_DIR                  # one shot, verbose
    patch-libcxx.py DEPS_DIR --quiet          # one shot, silent
    patch-libcxx.py DEPS_DIR --watch --quiet  # resident watcher (0.25 s)
"""

import re
import sys
import time
from pathlib import Path

try:
    import fcntl
except ImportError:  # Windows / local dry-runs only; CI is macOS
    fcntl = None

NEEDLE = "clang attribute _LibcxxExplicitABIAnnotations"
MACROS = (
    "_LIBCPP_END_EXPLICIT_ABI_ANNOTATIONS",
    "_LIBCPP_BEGIN_EXPLICIT_ABI_ANNOTATIONS",
)
# Accept "#define X", "# define X", "#  define X" and tab-separated variants.
DEFINE_RE = re.compile(
    r"^#\s*define\s+(" + "|".join(re.escape(m) for m in MACROS) + r")\b"
)


def neutralise(path: Path) -> bool:
    """Return True when *path* was rewritten. Idempotent.

    Only the two ``#define`` blocks (including backslash continuations) are
    replaced. A plain "the pragma string is gone" check is NOT usable here:
    libc++ headers also mention the pragma in comments, which must survive.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    if "clang attribute" not in text:
        return False
    lines = text.splitlines(keepends=True)
    out = []
    changed = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        m = DEFINE_RE.match(stripped)
        hit = m.group(1) if m else ""
        if not hit:
            out.append(line)
            i += 1
            continue
        # Collect the complete logical line (backslash continuations).
        block = [line]
        j = i
        while block[-1].rstrip().endswith(chr(92)) and j + 1 < len(lines):
            j += 1
            block.append(lines[j])
        if "clang attribute" in "".join(block):
            out.append("#define " + hit + chr(10))
            changed += 1
        else:
            out.extend(block)
        i = j + 1

    if changed == 0:
        return False
    replaced = "".join(out)
    # Sanity check: no ACTIVE macro definition may still carry the pragma.
    for line in replaced.splitlines():
        s = line.lstrip()
        if s.startswith("#define") and "clang attribute" in s:
            raise RuntimeError("could not neutralise libc++ macros in " + str(path))
    # write_bytes keeps LF exactly (Path.write_text would translate on Windows)
    path.write_bytes(replaced.encode("utf-8"))
    return True


def candidates(deps: Path):
    """All small headers that could define the pragma, across every SDK.

    Keep this cheap: the watcher runs ~4x/second. We only look at namespace.h
    (where libc++ defines these macros) plus the handful of files in
    __configuration/, so a layout change upstream is still covered.
    """
    seen = set()
    for sdk in sorted(deps.iterdir()):
        if not sdk.name.startswith("sdk-"):
            continue
        inc = sdk / "include" / "c++"
        if not inc.is_dir():
            continue
        cfg = inc / "__configuration"
        if cfg.is_dir():
            for p in cfg.glob("*.h"):
                seen.add(p)
        # Cover a layout change without walking the whole libc++ tree (which
        # has thousands of headers and would make the watcher expensive).
        for p in inc.glob("namespace.h"):
            seen.add(p)
        for p in inc.glob("*/namespace.h"):
            seen.add(p)
    return sorted(seen)


def run_once(deps: Path, quiet: bool):
    lock = deps / ".patch-libcxx.lock"
    changed = []
    errors = 0
    with open(lock, "a+") as fh:
        if fcntl is not None:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        for p in candidates(deps):
            try:
                if neutralise(p):
                    changed.append(str(p.relative_to(deps)))
            except Exception as exc:
                # One unreadable/exotic header must not block the other SDKs.
                print("[patch-libcxx] ERROR: " + str(exc), file=sys.stderr)
                errors += 1
        if fcntl is not None:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    if not quiet:
        for name in changed:
            print("[patch-libcxx] patched " + name)
        print("[patch-libcxx] libc++ explicit ABI pragma disabled in %d SDK header(s)" % len(changed))
    return 1 if errors else 0


def main(argv):
    if len(argv) < 2:
        print("usage: patch-libcxx.py DEPS_DIR [--quiet] [--watch]", file=sys.stderr)
        return 2
    deps = Path(argv[1]).resolve()
    quiet = "--quiet" in argv[2:]
    watch = "--watch" in argv[2:]
    if not deps.is_dir():
        print("[patch-libcxx] ERROR: no such deps dir: " + str(deps), file=sys.stderr)
        return 1
    if not watch:
        return run_once(deps, quiet)
    while True:
        try:
            run_once(deps, True)
        except Exception as exc:
            print("[patch-libcxx] watcher error: " + str(exc), file=sys.stderr)
        time.sleep(0.25)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
