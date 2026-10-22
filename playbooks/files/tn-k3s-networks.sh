#!/bin/sh
# tn-k3s-networks.sh - keep the custom k3s networks of a server node across a re-bootstrap.
#
# Why. The bootstrap script (re)installs k3s and rewrites /etc/systemd/system/k3s.service. Network
# flags that were only given on the command line of the original install (for example the virtual
# devices of the platform: --cluster-cidr=10.52.0.0/16 --service-cidr=10.53.0.0/16
# --cluster-dns=10.53.0.10) are lost, k3s falls back to 10.42/10.43 and crash-loops against the
# podCIDR of the existing node. Settings in /etc/rancher/k3s/config.yaml.d/*.yaml survive a
# reinstall, so this script copies the effective values there first.
#
# What it does (POSIX sh, run as root on the device, before the bootstrap script):
#   1. Reads ONLY the keys cluster-cidr, service-cidr and cluster-dns from the ExecStart of the k3s
#      unit and from config.yaml / config.yaml.d/*.yaml (never anything else: the files hold the
#      k3s token). Precedence as in k3s: command line, then drop-ins (later file wins), then
#      config.yaml.
#   2. Writes the values that are not already effective through a drop-in to
#      config.yaml.d/10-k3s-networks.yaml (mode 0644). Nothing set, or everything already in
#      drop-ins: it writes nothing.
#   3. When a value cannot be determined at all, it asks the running node: a podCIDR outside
#      10.42.0.0/16 (or a kubernetes service IP outside 10.43.0.0/16) means a custom network that
#      the reinstall would lose, and the script refuses (exit 6). A node that cannot be asked
#      (k3s down) is reported as a warning only.
#
# Output (stdout): one status line, "tn-k3s-networks: <status> ...". Status: changed (drop-in
# written), would-change (TN_DRY_RUN=1), unchanged (already kept), none (default networks).
# Values are networks and addresses, never secrets. Exit: 0 ok, 6 refused.
#
# Environment (all optional; the defaults are a Teknoir device, tests override them):
#   TN_K3S_UNIT         /etc/systemd/system/k3s.service
#   TN_K3S_CONFIG       /etc/rancher/k3s/config.yaml
#   TN_K3S_CONFIG_DIR   /etc/rancher/k3s/config.yaml.d
#   TN_K3S_KUBECTL      "k3s kubectl"
#   TN_K3S_DROPIN       10-k3s-networks.yaml (file name in the config dir)
#   TN_DRY_RUN          1 = report, do not write
set -eu

UNIT=${TN_K3S_UNIT:-/etc/systemd/system/k3s.service}
CONFIG=${TN_K3S_CONFIG:-/etc/rancher/k3s/config.yaml}
CONFIG_DIR=${TN_K3S_CONFIG_DIR:-/etc/rancher/k3s/config.yaml.d}
KUBECTL=${TN_K3S_KUBECTL:-k3s kubectl}
DROPIN=${TN_K3S_DROPIN:-10-k3s-networks.yaml}
KEYS="cluster-cidr service-cidr cluster-dns"

# value of one key in one YAML file: scalar (`key: v`) or block list (`key:` then `- v` lines),
# joined with commas. Prints nothing when the key is absent. Reads nothing else out of the file.
yaml_key() { # file key
  [ -f "$1" ] || return 0
  awk -v key="$2" '
    function clean(s) { sub(/[[:space:]]+#.*$/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); gsub(/^["\047]|["\047]$/, "", s); return s }
    infound && /^[[:space:]]*-[[:space:]]/ { s = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); s = clean(s); out = out (out == "" ? "" : ",") s; next }
    infound && /^[[:space:]]*(#.*)?$/ { next }
    infound { exit }
    $0 ~ "^" key "[[:space:]]*:" {
      s = $0; sub("^" key "[[:space:]]*:", "", s); s = clean(s)
      if (s == "") { infound = 1 } else { out = s; exit }
    }
    END { if (out != "") print out }
  ' "$1"
}

# value of one flag in the ExecStart of the unit: --flag=value or --flag value, quoted or not.
unit_flag() { # flag
  [ -f "$UNIT" ] || return 0
  awk '
    /^ExecStart=/ { on = 1 }
    on { print; if ($0 !~ /\\[[:space:]]*$/) on = 0 }
  ' "$UNIT" | sed 's/\\[[:space:]]*$//' | tr '\n' ' ' | tr -d "\"'" |
    awk -v flag="--$1" '{
      for (i = 1; i <= NF; i++) {
        if ($i == flag && i < NF) v = $(i + 1)
        else if (index($i, flag "=") == 1) v = substr($i, length(flag) + 2)
      }
      if (v != "") print v
    }'
}

# the value that the drop-ins give (later file wins)
dropin_value() { # key
  _v=
  for _f in "$CONFIG_DIR"/*.yaml "$CONFIG_DIR"/*.yml; do
    [ -f "$_f" ] || continue
    _x=$(yaml_key "$_f" "$1")
    [ -z "$_x" ] || _v=$_x
  done
  printf '%s' "$_v"
}

effective_value() { # key
  _e=$(unit_flag "$1")
  [ -n "$_e" ] || _e=$(dropin_value "$1")
  [ -n "$_e" ] || _e=$(yaml_key "$CONFIG" "$1")
  printf '%s' "$_e"
}

need=0 have=0 summary=
for k in $KEYS; do
  eff=$(effective_value "$k")
  [ -z "$eff" ] || { have=1; summary="$summary $k=$eff"; }
  eval "eff_$(echo "$k" | tr - _)=\$eff"
  if [ -n "$eff" ] && [ "$(dropin_value "$k")" != "$eff" ]; then need=1; fi
done

if [ "$have" = 1 ]; then
  if [ "$need" = 0 ]; then
    echo "tn-k3s-networks: unchanged, kept by $CONFIG_DIR:$summary"
    exit 0
  fi
  if [ "${TN_DRY_RUN:-}" = 1 ]; then
    echo "tn-k3s-networks: would-change, would write $CONFIG_DIR/$DROPIN:$summary"
    exit 0
  fi
  mkdir -p "$CONFIG_DIR"
  tmp=$(mktemp "$CONFIG_DIR/.$DROPIN.XXXXXX")
  {
    echo "# Written by Teknoir playbooks/rebootstrap-device.yml (tn-k3s-networks.sh)."
    echo "# These k3s networks were set on the command line of the original install. The bootstrap"
    echo "# reinstall rewrites the k3s service unit and would drop them (k3s would crash-loop on the"
    echo "# podCIDR of the existing node), so they are kept here. Do not delete."
    for k in $KEYS; do
      eval "v=\$eff_$(echo "$k" | tr - _)"
      [ -z "$v" ] || echo "$k: \"$v\""
    done
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$CONFIG_DIR/$DROPIN"
  # A later drop-in with another value would still win after the reinstall.
  for k in $KEYS; do
    eval "v=\$eff_$(echo "$k" | tr - _)"
    if [ -n "$v" ] && [ "$(dropin_value "$k")" != "$v" ]; then
      echo "tn-k3s-networks: refused, $k=$v is overridden by another file in $CONFIG_DIR after $DROPIN; the reinstall would change it" >&2
      exit 6
    fi
  done
  echo "tn-k3s-networks: changed, wrote $CONFIG_DIR/$DROPIN:$summary"
  exit 0
fi

# Nothing configured: the node must be on the default networks, otherwise refuse.
pod=$($KUBECTL get node -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null || true)
svc=$($KUBECTL get service kubernetes -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
bad=
for c in $(echo "$pod" | tr ',' ' '); do
  case "$c" in *:*) ;; 10.42.*) ;; *) bad="$bad podCIDR $c is outside 10.42.0.0/16;" ;; esac
done
case "$svc" in ''|*:*|10.43.*) ;; *) bad="$bad the kubernetes service IP $svc is outside 10.43.0.0/16;" ;; esac
if [ -n "$bad" ]; then
  echo "tn-k3s-networks: refused, cannot determine the k3s networks of this node (no cluster-cidr/service-cidr/cluster-dns in $UNIT, $CONFIG or $CONFIG_DIR/*.yaml) but$bad the reinstall would reset them to 10.42.0.0/16 and 10.43.0.0/16 and k3s would crash-loop. Write $CONFIG_DIR/10-k3s-networks.yaml by hand (cluster-cidr, service-cidr, cluster-dns) and run again." >&2
  exit 6
fi
if [ -z "$pod" ]; then
  echo "tn-k3s-networks: none, no custom networks found; the node could not be asked (k3s not answering), podCIDR unverified"
else
  echo "tn-k3s-networks: none, default networks (podCIDR $pod)"
fi
