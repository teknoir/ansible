#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # rc and has() are read through the ok() checks' eval, which shellcheck cannot see
# Proves that playbooks/files/desktop_bundle_check.py, the controller-side check that playbooks/desktop.yml runs
# before it installs the theme (and tests/desktop-vendor/run.sh runs on the bundle in this repository), reports every
# kind of problem with the right exit code. Each case builds a throwaway bundle directory from one template (SOURCE,
# the session script, the unit, the migration, the mark and one file in each of the three theme trees) with a
# SHA256SUMS over it, breaks one thing and reads the script's output: one problem per line, exit 1, and "ok <n> files"
# with exit 0 for a clean one. No device, no network, no root.
# Usage: tests/desktop-bundle-check/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script=$repo/playbooks/files/desktop_bundle_check.py
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

# SHA256SUMS the way `make host-bundle` writes it: one "<64 hex>  <path>" line per file, paths relative to the bundle,
# and SHA256SUMS itself left out (it cannot carry its own hash).
sums() {
  python3 -I - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
lines = []
for dirpath, dirnames, filenames in os.walk(root):
    for name in filenames:
        if name == "SHA256SUMS":
            continue
        path = os.path.join(dirpath, name)
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        lines.append("%s  %s" % (digest, os.path.relpath(path, root).replace(os.sep, "/")))
with open(os.path.join(root, "SHA256SUMS"), "w") as handle:
    handle.write("\n".join(sorted(lines)) + "\n")
PY
}

# A bundle with one file in each theme tree, SOURCE included in SHA256SUMS. Prints its path.
bundle() {
  dir=$tmp/$1
  mkdir -p "$dir/theme/themes/Teknoir/gtk-3.0" "$dir/theme/xdg/xfce4/panel" "$dir/theme/fonts"
  printf 'repo: teknoir/teknoir-desktop\ncommit: 0123456789abcdef0123456789abcdef01234567\n' >"$dir/SOURCE"
  printf '#!/bin/sh\nexit 78\n' >"$dir/teknoir-desktop-session"
  printf '[Unit]\nDescription=teknoir desktop\n' >"$dir/teknoir-desktop.service"
  printf '#!/bin/sh\nexit 0\n' >"$dir/theme/desktop-theme-migrate"
  printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$dir/theme/teknoir-mark.svg"
  printf 'GtkButton { color: #f2f1ee; }\n' >"$dir/theme/themes/Teknoir/gtk-3.0/gtk.css"
  printf '<?xml version="1.0"?>\n' >"$dir/theme/xdg/xfce4/panel/default.xml"
  printf 'font file\n' >"$dir/theme/fonts/Font.ttf"
  sums "$dir"
  printf '%s\n' "$dir"
}

out=""
rc=0
check() { out=$(python3 -I "$script" "$1" 2>&1); rc=$?; }
has() { printf '%s\n' "$out" | grep -qxF "$1"; }
H=$(printf '%064d' 0)

dir=$(bundle clean)
check "$dir"
ok "a clean bundle passes: $out" "[ \"\$rc\" -eq 0 ] && [ \"\$out\" = 'ok 8 files' ]"

dir=$(bundle changed)
printf 'another palette\n' >>"$dir/theme/themes/Teknoir/gtk-3.0/gtk.css"
check "$dir"
ok "a file with another hash is changed" "[ \"\$rc\" -eq 1 ] && has 'changed: theme/themes/Teknoir/gtk-3.0/gtk.css'"

dir=$(bundle extra)
printf 'stray\n' >"$dir/extra.txt"
printf 'stray\n' >"$dir/theme/xdg/xfce4/panel/extra.xml"
printf 'stray\n' >"$dir/.DS_Store"
check "$dir"
ok "a file at the top level, one in a theme tree and a hidden one are not in SHA256SUMS" \
  "[ \"\$rc\" -eq 1 ] && has 'not in SHA256SUMS: extra.txt' \
  && has 'not in SHA256SUMS: theme/xdg/xfce4/panel/extra.xml' && has 'not in SHA256SUMS: .DS_Store'"

dir=$(bundle missing)
printf '%s  theme/xdg/xfce4/panel/gone.xml\n' "$H" >>"$dir/SHA256SUMS"
check "$dir"
ok "a listed file that is not there is missing" "[ \"\$rc\" -eq 1 ] && has 'missing: theme/xdg/xfce4/panel/gone.xml'"

dir=$(bundle malformed)
printf 'deadbeef  theme/fonts/Font.ttf\n' >>"$dir/SHA256SUMS"
check "$dir"
ok "a line that is not a checksum is malformed" "[ \"\$rc\" -eq 1 ] && has 'malformed: deadbeef  theme/fonts/Font.ttf'"

dir=$(bundle unknown)
printf '%s  theme/icons/x.png\n' "$H" >>"$dir/SHA256SUMS"
check "$dir"
ok "a path the playbook never installs is an unknown path" "[ \"\$rc\" -eq 1 ] && has 'unknown path: theme/icons/x.png'"

dir=$(bundle outside)
printf '%s  ../x\n%s  /etc/passwd\n' "$H" "$H" >>"$dir/SHA256SUMS"
check "$dir"
ok "a path with .. and an absolute path are refused" \
  "[ \"\$rc\" -eq 1 ] && has 'unknown path: ../x' && has 'unknown path: /etc/passwd'"

dir=$(bundle crlf)
python3 -I -c 'import sys; p = sys.argv[1]; d = open(p, "rb").read(); open(p, "wb").write(d.replace(b"\n", b"\r\n"))' \
  "$dir/SHA256SUMS"
check "$dir"
ok "a CRLF SHA256SUMS still passes: $out" "[ \"\$rc\" -eq 0 ] && [ \"\$out\" = 'ok 8 files' ]"

dir=$(bundle nofonts)
rm -rf "$dir/theme/fonts"
sums "$dir"
check "$dir"
ok "a bundle without theme/fonts entries is refused" "[ \"\$rc\" -eq 1 ] && has 'no entries under: theme/fonts/'"

dir=$(bundle nosource)
grep -v '  SOURCE$' "$dir/SHA256SUMS" >"$dir/SHA256SUMS.new" && mv "$dir/SHA256SUMS.new" "$dir/SHA256SUMS"
check "$dir"
ok "SOURCE has to be listed too" "[ \"\$rc\" -eq 1 ] && has 'not in SHA256SUMS: SOURCE'"

dir=$(bundle nosums)
rm "$dir/SHA256SUMS"
check "$dir"
ok "a bundle without SHA256SUMS is refused" "[ \"\$rc\" -eq 1 ] && has 'missing: SHA256SUMS'"

dir=$(bundle nosourcedir)
rm "$dir/SOURCE"
sums "$dir"
check "$dir"
ok "a bundle without SOURCE is refused" "[ \"\$rc\" -eq 1 ] && has 'missing: SOURCE'"

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
