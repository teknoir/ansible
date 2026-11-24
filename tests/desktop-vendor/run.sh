#!/usr/bin/env bash
# shellcheck disable=SC2034 # the ok() checks read these through eval, which shellcheck cannot see
# Local test of the vendored bundle in playbooks/files/teknoir-desktop/, the files playbooks/desktop.yml installs (the
# session script, the unit and the theme). The bundle comes from teknoir/teknoir-desktop (`make host-bundle OUT=...`)
# and is never edited here, so this suite checks that it is complete and that the playbook and the bundle agree: every
# file is in SHA256SUMS and nothing else is, every `src:` of the playbook exists, the panel references the mark path the
# playbook installs it to, and both sides know the theme switch. No device, no network, no root.
# Usage: tests/desktop-vendor/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$repo" || exit 1
bundle=playbooks/files/teknoir-desktop
playbook=playbooks/desktop.yml
dropin=playbooks/templates/teknoir-desktop-dropin.conf.j2
fail=0
ok() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

# SOURCE records where the bundle came from, so a reader can vendor the same commit again.
source_repo=$(sed -n 's/^repo: *//p' "$bundle/SOURCE" 2>/dev/null)
source_commit=$(sed -n 's/^commit: *//p' "$bundle/SOURCE" 2>/dev/null)
ok "SOURCE exists" "[ -f '$bundle/SOURCE' ]"
ok "SOURCE names the repo" "[ \"\$source_repo\" = teknoir/teknoir-desktop ]"
ok "SOURCE has a full commit sha" "printf '%s' \"\$source_commit\" | grep -qxE '[0-9a-f]{40}'"
ok "SOURCE was not vendored from a dirty checkout" "! grep -qE '^dirty: *true' '$bundle/SOURCE' 2>/dev/null"

# SHA256SUMS covers every file in the bundle, and every file it lists is there with that hash. SHA256SUMS cannot list
# itself, and SOURCE is optional in it (it records the commit, not the content), so both sides leave SOURCE out.
ok "SHA256SUMS exists" "[ -f '$bundle/SHA256SUMS' ]"
ok "every file matches SHA256SUMS" "(cd '$bundle' && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1)"
files=$(cd "$bundle" && find . -type f ! -name SHA256SUMS ! -name SOURCE | sed -E 's|^\./||' | sort)
listed=$(sed -nE 's/^[0-9a-f]{64} [ *]//p' "$bundle/SHA256SUMS" 2>/dev/null | sed -E 's|^\./||' \
  | grep -vxE 'SOURCE|SHA256SUMS' | sort)
ok "SHA256SUMS lists every file of the bundle" "[ -z \"\$(comm -23 <(printf '%s\n' \"\$files\") <(printf '%s\n' \"\$listed\"))\" ]"
ok "every file SHA256SUMS lists is in the bundle" "[ -z \"\$(comm -13 <(printf '%s\n' \"\$files\") <(printf '%s\n' \"\$listed\"))\" ]"

# Every src: under files/teknoir-desktop that the playbook copies (a plain path, or {{ desktop_files }}) exists in the
# bundle: the playbook can only install what was vendored.
bundle_var=$(sed -nE 's/^ *desktop_files: *//p' "$playbook" | head -n1)
ok "the playbook names the bundle it copies from" "[ \"\$bundle_var\" = files/teknoir-desktop ]"
srcs=$(grep -oE 'src: *"?(\{\{ *desktop_files *\}\}|files/teknoir-desktop)/[^"]*' "$playbook" \
  | sed -E "s|^src: *\"?||; s|\{\{ *desktop_files *\}\}|$bundle_var|")
ok "the playbook copies files from the bundle" "[ -n \"\$srcs\" ]"
for src in $srcs; do ok "the playbook's src $src exists" "[ -e 'playbooks/$src' ]"; done

# The panel's default.xml references the mark by an absolute path; the playbook has to install the mark exactly there.
panel=$bundle/theme/xdg/xfce4/panel/default.xml
mark=$(grep -ohE '/usr/share/teknoir/[A-Za-z0-9._-]+\.svg' "$panel" 2>/dev/null | sort -u | head -n1)
mark_install=$(sed -nE 's/^ *desktop_theme_mark: *//p' "$playbook" | head -n1)
ok "the panel references the Teknoir mark" "[ \"\$mark\" = /usr/share/teknoir/teknoir-mark.svg ]"
ok "the playbook installs the mark to the path the panel references" "[ \"\$mark_install\" = \"\$mark\" ]"
ok "the bundle has the mark the playbook copies" "[ -f '$bundle/theme/teknoir-mark.svg' ]"

# The theme switch: the session script reads TEKNOIR_DESKTOP_THEME, the drop-in sets it and the playbook defaults it to
# the theme the bundle carries.
theme_var=$(sed -nE 's/^ *desktop_theme: *//p' "$playbook" | head -n1)
ok "the playbook defaults desktop_theme to teknoir" "[ \"\$theme_var\" = teknoir ]"
ok "the session script reads TEKNOIR_DESKTOP_THEME" "grep -q 'TEKNOIR_DESKTOP_THEME' '$bundle/teknoir-desktop-session'"
ok "the drop-in sets TEKNOIR_DESKTOP_THEME" "grep -qxF 'Environment=TEKNOIR_DESKTOP_THEME={{ desktop_theme }}' '$dropin'"

# The two theme locations that may be overridden: the session script reads them from the environment (with the same
# defaults), so the drop-in has to hand the playbook's variables on or an override would be ignored.
ok "the session script reads TEKNOIR_DESKTOP_THEME_XDG" "grep -q 'TEKNOIR_DESKTOP_THEME_XDG' '$bundle/teknoir-desktop-session'"
ok "the session script reads TEKNOIR_DESKTOP_THEME_MIGRATE" "grep -q 'TEKNOIR_DESKTOP_THEME_MIGRATE' '$bundle/teknoir-desktop-session'"
ok "the drop-in sets TEKNOIR_DESKTOP_THEME_XDG" "grep -qxF 'Environment=TEKNOIR_DESKTOP_THEME_XDG={{ desktop_theme_xdg_dir }}' '$dropin'"
ok "the drop-in sets TEKNOIR_DESKTOP_THEME_MIGRATE" "grep -qxF 'Environment=TEKNOIR_DESKTOP_THEME_MIGRATE={{ desktop_theme_migrate }}' '$dropin'"

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
