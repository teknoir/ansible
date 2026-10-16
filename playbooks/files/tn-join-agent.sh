#!/bin/sh
# tn-join-agent.sh - run by playbooks/join-robot-agent.yml, ON the computer that becomes a k3s agent.
#
# UNTESTED: run it on a VM first (see the README).
#
# What it does, in this order, and nothing else:
#   1. backs up /etc/rancher/k3s/config.yaml and config.yaml.d to /root/k3s-pre-join.<time> (root only)
#   2. uninstalls the k3s that the computer runs now (k3s-uninstall.sh or k3s-agent-uninstall.sh), which
#      deletes its cluster data: /var/lib/rancher/k3s, the kubelet state and the containers
#   3. puts the prepared config.yaml (node-name, node-label, node-taint) in /etc/rancher/k3s
#   4. runs the k3s installer as an agent of K3S_URL
# It is started detached (the connection may be lost when the old k3s goes away: the tunnel can run in it).
# Progress is in <dir>/status (running / done / failed) and <dir>/install.log. The token is read from
# <dir>/join.env (root only) and the file is removed on exit, on success and on failure.
#
# Usage: tn-join-agent.sh <dir>     <dir> holds join.env, config.yaml and k3s-install.sh;
#                                   created root-only by the playbook.
set -eu

dir=${1:?usage: tn-join-agent.sh <dir>}
# Paths; the environment overrides them only so that the script can be tested in a sandbox.
etc="${TN_K3S_ETC:-/etc/rancher/k3s}"
bin="${TN_BIN_DIR:-/usr/local/bin}"
backup_root="${TN_BACKUP_DIR:-/root}"
status="$dir/status"
log="$dir/install.log"

fail() {
    echo "failed" >"$status"
    echo "tn-join-agent: $*" >>"$log"
    exit 1
}
trap 'rm -f "$dir/join.env"' EXIT
trap 'fail "interrupted or an unexpected error (see the lines above)"' INT TERM HUP

[ "$(id -u)" = 0 ] || fail "must run as root"
echo "running" >"$status"
: >"$log"
chmod 600 "$status" "$log"

[ -r "$dir/join.env" ] || fail "no join.env"
# shellcheck disable=SC1091
. "$dir/join.env"
: "${K3S_URL:?}" "${K3S_TOKEN:?}"

steps() {
    # 1. backup
    if [ -e "$etc/config.yaml" ] || [ -d "$etc/config.yaml.d" ]; then
        bk="$backup_root/k3s-pre-join.$(date +%s)"
        mkdir -m 0700 "$bk"
        if [ -e "$etc/config.yaml" ]; then cp -a "$etc/config.yaml" "$bk/"; fi
        if [ -d "$etc/config.yaml.d" ]; then cp -a "$etc/config.yaml.d" "$bk/"; fi
        echo "backup of the k3s config in $bk"
    fi

    # 2. uninstall what runs now
    for u in "$bin/k3s-uninstall.sh" "$bin/k3s-agent-uninstall.sh"; do
        if [ -x "$u" ]; then
            echo "running $u"
            "$u"
        fi
    done

    # 3. config
    mkdir -p "$etc"
    cp "$dir/config.yaml" "$etc/config.yaml"
    chmod 600 "$etc/config.yaml"

    # 4. install
    export K3S_URL K3S_TOKEN
    export INSTALL_K3S_EXEC="agent"
    export INSTALL_K3S_SYMLINK=force
    if [ -n "${INSTALL_K3S_VERSION:-}" ]; then export INSTALL_K3S_VERSION; fi
    sh "$dir/k3s-install.sh"
}

# set -e is ignored in anything that is the left side of || or in an if condition, so the steps run in a
# subshell of their own that is not: the first failing command ends the steps.
set +e
(set -e; steps) >>"$log" 2>&1
rc=$?
set -e
[ "$rc" = 0 ] || fail "a step failed (exit $rc), see install.log"

echo "done" >"$status"
