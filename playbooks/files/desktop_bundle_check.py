#!/usr/bin/env python3
"""Checks a vendored teknoir-desktop bundle against its own SHA256SUMS.

playbooks/desktop.yml runs this on the controller (delegate_to: localhost) before it installs the theme, and
tests/desktop-vendor/run.sh runs it on the bundle in this repository. It is Python and not `sha256sum -c` plus `find
-printf` because the controller may be macOS, which has neither; stdlib only, and Python 3.8 (the interpreter behind an
operator's ansible varies).

The bundle is the files/teknoir-desktop directory: SOURCE, SHA256SUMS, the session script, the unit and theme/. Every
file in the directory is in SHA256SUMS with that hash, everything SHA256SUMS lists is there, and every listed path is
one the playbook installs. That matters because the directory copies never delete: a file the playbook does not install
is not copied, so a stray file in the directory is harmless, but the stale-file removal deletes whatever under the
three theme trees the list does not have - so an extra listed path, or an empty or foreign SHA256SUMS, would have the
removal delete theme files right after the copy put them there, on every run (a change and a restart each time, which
drops the live remote session).

One problem per line on stdout, exit 1; otherwise "ok <n> files" and exit 0.
"""

import hashlib
import os
import re
import sys

# The paths a bundle may carry: what the playbook copies (SOURCE and SHA256SUMS themselves, the session script, the
# unit, the migration, the mark and the three theme trees). A new prefix would never be installed by any copy task.
PATH_RE = re.compile(
    r"^(SOURCE|teknoir-desktop-session|teknoir-desktop\.service|"
    r"theme/(desktop-theme-migrate|teknoir-mark\.svg|(themes/Teknoir|xdg|fonts)/.+))$"
)
SUMS_RE = re.compile(r"^([0-9a-f]{64}) [ *](.+)$")
TREES = ("theme/themes/Teknoir/", "theme/xdg/", "theme/fonts/")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def problems_of(root):
    problems = []
    if not os.path.isfile(os.path.join(root, "SOURCE")):
        problems.append("missing: SOURCE")

    lines = []
    sums = os.path.join(root, "SHA256SUMS")
    if not os.path.isfile(sums):
        problems.append("missing: SHA256SUMS")
    else:
        with open(sums, "rb") as handle:
            text = handle.read().decode("utf-8", "surrogateescape")
        # CRLF: a SHA256SUMS that went through a Windows or macOS checkout still describes the same files.
        lines = [line.rstrip("\r") for line in text.split("\n")]
        if lines and lines[-1] == "":
            lines.pop()

    listed = {}
    seen = set()
    for line in lines:
        match = SUMS_RE.match(line)
        if not match:
            problems.append("malformed: %s" % line)
            continue
        digest, path = match.groups()
        if path.startswith("./"):
            path = path[2:]
        seen.add(path)
        # An absolute path or a .. component never belongs to a bundle, and the removal must never be handed one.
        if path.startswith("/") or ".." in path.split("/") or not PATH_RE.match(path):
            problems.append("unknown path: %s" % path)
            continue
        listed[path] = digest

    for path in sorted(listed):
        digest = listed[path]
        full = os.path.join(root, path)
        if not os.path.isfile(full):
            problems.append("missing: %s" % path)
        elif sha256(full) != digest:
            problems.append("changed: %s" % path)

    for tree in TREES:
        if not any(path.startswith(tree) for path in listed):
            problems.append("no entries under: %s" % tree)

    # Everything in the directory is listed, except SHA256SUMS itself (it cannot list its own hash). SOURCE is listed:
    # it is a file of the bundle, and the copy installs nothing of it, but an unlisted file next to the vendored ones is
    # what a stray editor backup or .DS_Store looks like, and the next vendor run should start from a clean tree.
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
            if rel != "SHA256SUMS" and rel not in seen:
                problems.append("not in SHA256SUMS: %s" % rel)

    return problems, len(listed)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: %s <bundle directory>\n" % os.path.basename(argv[0]))
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        print("missing: %s" % root)
        return 1
    problems, count = problems_of(root)
    if problems:
        for problem in problems:
            print(problem)
        return 1
    print("ok %d files" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
