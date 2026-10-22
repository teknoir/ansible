#!/usr/bin/env bash
# Local test of playbooks/files/tn-k3s-networks.sh (used by playbooks/rebootstrap-device.yml) against
# throwaway fake k3s unit / config files and a stubbed kubectl. No device, no root. Usage: tests/k3s-networks/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
S="$here/../../playbooks/files/tn-k3s-networks.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for x in "$@"; do echo "     $x"; done; fail=1; }

cat > "$work/kubectl" <<'S'
#!/bin/sh
case "$*" in
  *podCIDR*) printf '%s' "$FAKE_POD" ;;
  *service*kubernetes*) printf '%s' "$FAKE_SVC" ;;
esac
[ -z "${FAKE_DOWN:-}" ] || exit 1
S
chmod +x "$work/kubectl"

# new <case>: fresh fake device in $d
new() {
  d="$work/$1"; mkdir -p "$d/k3s/config.yaml.d"
  export TN_K3S_UNIT="$d/k3s.service" TN_K3S_CONFIG="$d/k3s/config.yaml" TN_K3S_CONFIG_DIR="$d/k3s/config.yaml.d" TN_K3S_KUBECTL="$work/kubectl"
  export FAKE_POD=10.42.0.0/24 FAKE_SVC=10.43.0.1; unset FAKE_DOWN TN_DRY_RUN
  printf '%s\n' '[Service]' 'ExecStartPre=/sbin/modprobe br_netfilter' 'ExecStart=/usr/local/bin/k3s \' '    server \' "    '--token' 'SECRET-TOKEN-VALUE' \\" > "$d/k3s.service"
}
run() { out=$(sh "$S" 2>"$work/err"); rc=$?; err=$(cat "$work/err"); }
leak() { case "$out$err" in *SECRET-TOKEN-VALUE*) bad "$1: the token leaked into the output";; esac; }

# 1. default networks, nothing written
new default; run
[ $rc = 0 ] && [[ $out == *"none, default"* ]] && [ -z "$(ls -A "$d/k3s/config.yaml.d")" ] && ok "default networks: nothing written" || bad "default" "$rc $out $err"; leak default

# 2. virtual device: flags on the unit command line (both = and space, quoted) are copied
new vdev
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/k3s \' '    server \' "    '--cluster-cidr=10.52.0.0/16' \\" '    --service-cidr 10.53.0.0/16 \' '    "--cluster-dns=10.53.0.10" \' '    --token SECRET-TOKEN-VALUE' > "$d/k3s.service"
FAKE_POD=10.52.0.0/24 run; f="$d/k3s/config.yaml.d/10-k3s-networks.yaml"
[ $rc = 0 ] && [[ $out == tn-k3s-networks:\ changed* ]] && grep -qx 'cluster-cidr: "10.52.0.0/16"' "$f" && grep -qx 'service-cidr: "10.53.0.0/16"' "$f" \
  && grep -qx 'cluster-dns: "10.53.0.10"' "$f" && [ "$(stat -c %a "$f")" = 644 ] && grep -q '^# ' "$f" && ! grep -q SECRET "$f" && ok "unit flags written to the drop-in (0644, commented, no token)" || bad "vdev" "$rc $out $err"; leak vdev
# the reinstall drops the flags from the unit: the drop-in keeps them, a second run changes nothing
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/k3s server --token SECRET-TOKEN-VALUE' > "$d/k3s.service"
cp "$f" "$work/before"; run
[ $rc = 0 ] && [[ $out == *unchanged* ]] && cmp -s "$f" "$work/before" && ok "after the reinstall: unchanged, drop-in intact" || bad "vdev after" "$rc $out $err"
# the same device again with the flags still on the unit: idempotent
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/k3s \' '    server --cluster-cidr=10.52.0.0/16 --service-cidr=10.53.0.0/16 --cluster-dns=10.53.0.10' > "$d/k3s.service"; run
[ $rc = 0 ] && [[ $out == *unchanged* ]] && cmp -s "$f" "$work/before" && ok "flags on the unit and in the drop-in: idempotent" || bad "vdev idem" "$rc $out"

# 3. dry run writes nothing
new dry
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/k3s server --cluster-cidr=10.52.0.0/16' > "$d/k3s.service"
TN_DRY_RUN=1 run
[ $rc = 0 ] && [[ $out == *would-change* ]] && [ -z "$(ls -A "$d/k3s/config.yaml.d")" ] && ok "dry run: reported, not written" || bad "dry" "$rc $out"

# 4. keys in config.yaml (scalar, list, comments, quotes) are moved to a drop-in; the token is not
new cfg
printf '%s\n' 'token: SECRET-TOKEN-VALUE' 'cluster-cidr: "10.60.0.0/16"  # mine' 'service-cidr:' '  - 10.61.0.0/16' '  - fd00:61::/112' 'node-name: x' > "$d/k3s/config.yaml"
FAKE_POD=10.60.0.0/24 run; f="$d/k3s/config.yaml.d/10-k3s-networks.yaml"
[ $rc = 0 ] && grep -qx 'cluster-cidr: "10.60.0.0/16"' "$f" && grep -qx 'service-cidr: "10.61.0.0/16,fd00:61::/112"' "$f" && ! grep -qE 'cluster-dns|node-name|token' "$f" && ok "config.yaml keys copied (scalar and list), nothing else" || bad "cfg" "$rc $out $err"; leak cfg

# 5. already in another drop-in: nothing written
new dropin
printf '%s\n' 'cluster-cidr: 10.52.0.0/16' > "$d/k3s/config.yaml.d/20-vdevice-networks.yaml"
FAKE_POD=10.52.0.0/24 run
[ $rc = 0 ] && [[ $out == *unchanged* ]] && [ "$(ls "$d/k3s/config.yaml.d")" = 20-vdevice-networks.yaml ] && ok "already in a drop-in: nothing written" || bad "dropin" "$rc $out"

# 6. a later drop-in that disagrees with the unit would win after the reinstall: refuse, and change nothing
new conflict
printf '%s\n' 'cluster-cidr: 10.70.0.0/16' > "$d/k3s/config.yaml.d/20-other.yaml"
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/k3s server --cluster-cidr=10.52.0.0/16' > "$d/k3s.service"
run
[ $rc = 6 ] && [[ $err == *overridden* ]] && [ "$(ls -A "$d/k3s/config.yaml.d")" = 20-other.yaml ] && ok "conflicting later drop-in: refused, no drop-in and no temp file left" || bad "conflict" "$rc $out $err $(ls -A "$d/k3s/config.yaml.d")"
# an existing 10-k3s-networks.yaml is left as it was
printf '%s\n' 'service-cidr: "10.53.0.0/16"' > "$d/k3s/config.yaml.d/10-k3s-networks.yaml"; cp "$d/k3s/config.yaml.d/10-k3s-networks.yaml" "$work/old10"
run
[ $rc = 6 ] && cmp -s "$d/k3s/config.yaml.d/10-k3s-networks.yaml" "$work/old10" && [ "$(ls -A "$d/k3s/config.yaml.d" | wc -l)" = 2 ] && ok "refusal leaves an existing 10-k3s-networks.yaml untouched" || bad "conflict existing" "$rc $err"
# a missing config dir is created when the drop-in is written
new conflict2; rm -rf "$d/k3s/config.yaml.d"; mkdir -p "$d/k3s"
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/k3s server --cluster-cidr=10.52.0.0/16' > "$d/k3s.service"
run
[ $rc = 0 ] && [ -f "$d/k3s/config.yaml.d/10-k3s-networks.yaml" ] && ok "missing config dir is created when the drop-in is written" || bad "no dir" "$rc $out $err"
# an EARLIER drop-in with another value loses against the 10- file: written
new earlier
printf '%s\n' 'cluster-cidr: 10.70.0.0/16' > "$d/k3s/config.yaml.d/05-other.yaml"
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/k3s server --cluster-cidr=10.52.0.0/16' > "$d/k3s.service"
run
[ $rc = 0 ] && grep -qx 'cluster-cidr: "10.52.0.0/16"' "$d/k3s/config.yaml.d/10-k3s-networks.yaml" && ok "earlier drop-in with another value: ours wins, written" || bad "earlier" "$rc $out $err"

# 7. undeterminable, podCIDR outside 10.42/16: refuse; service IP outside 10.43/16: refuse
new refuse; FAKE_POD=10.52.0.0/24 run
[ $rc = 6 ] && [[ $err == *"refused"*"10.52.0.0/24"* ]] && [ -z "$(ls -A "$d/k3s/config.yaml.d")" ] && ok "unknown networks, custom podCIDR: refused" || bad "refuse pod" "$rc $out $err"
new refuse2; FAKE_SVC=10.53.0.1 run
[ $rc = 6 ] && [[ $err == *"10.53.0.1"* ]] && ok "unknown networks, custom service IP: refused" || bad "refuse svc" "$rc $out $err"
# a dual-stack default (v6 entry) is not a custom IPv4 network
new dual; FAKE_POD='10.42.0.0/24,fd00:42::/64' run
[ $rc = 0 ] && ok "default dual-stack podCIDR accepted" || bad dual "$rc $err"

# 8. k3s not answering and nothing configured: warn, do not block
new down; FAKE_DOWN=1 FAKE_POD= FAKE_SVC= run
[ $rc = 0 ] && [[ $out == *unverified* ]] && ok "k3s down, nothing configured: warning only" || bad down "$rc $out $err"

# 9. the playbook runs the script before the bootstrap script, and asserts its result
p="$here/../../playbooks/rebootstrap-device.yml"
a=$(grep -n 'tn-k3s-networks.sh' "$p" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1); b=$(grep -n 'Run the bootstrap script (output' "$p" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && grep -q 'tn_networks.rc == 0' "$p" && ok "playbook: networks step before the bootstrap run, result asserted" || bad "playbook order" "$a $b"

[ $fail = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
