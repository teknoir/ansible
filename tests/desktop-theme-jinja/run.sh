#!/usr/bin/env bash
# Renders the theme list expressions of playbooks/desktop.yml with stub values (render.py, through ansible's Templar):
# no playbook runs, no device, no network, no root. The expressions have to agree with what the copies install, or the
# stale-file removal deletes theme files on every run.
#
# Needs a python that can import ansible: $PYTHON if set, else python3, else the python behind an ansible or
# ansible-playbook on the PATH (the uv tool, a pip install). Without one the suite skips: it has nothing to render with.
# Usage: tests/desktop-theme-jinja/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$repo" || exit 1

has_ansible() { "$1" -I -c 'import ansible' >/dev/null 2>&1; }

py=""
for candidate in ${PYTHON:-} python3; do
  if command -v "$candidate" >/dev/null 2>&1 && has_ansible "$(command -v "$candidate")"; then
    py=$(command -v "$candidate")
    break
  fi
done
if [ -z "$py" ]; then
  for tool in ansible ansible-playbook; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    interpreter=$(head -n1 "$path" 2>/dev/null | sed -nE 's|^#!(.*)$|\1|p')
    interpreter=${interpreter%% *}
    if [ -n "$interpreter" ] && has_ansible "$interpreter"; then
      py=$interpreter
      break
    fi
  done
fi
if [ -z "$py" ]; then
  echo "SKIP: no python on this host can import ansible (pip install ansible-core, or set PYTHON)"
  exit 0
fi

"$py" -I "$here/render.py" "$repo"
rc=$?
[ "$rc" -eq 0 ] && echo "all passed"
exit "$rc"
