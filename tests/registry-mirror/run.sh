#!/usr/bin/env bash
# Local test of playbooks/registry-mirror.yml against a throwaway directory with stubbed `kubectl`, `curl`,
# `crictl`, `systemctl` and `hostname`. No device, no cluster, no root, no network. Usage: tests/registry-mirror/run.sh
#
# The stubs behave like the real tools where it matters: the platform's Secret holds the credential under the
# key <namespace>.username/password, Harbor's token endpoint accepts only the right credential (read from the curl
# config on stdin), the manifest HEAD accepts only the token it issued, and a k3s restart regenerates containerd's
# hosts.toml from registries.yaml. Every run's output is collected and searched for the stub password and token.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] && echo "kept $work" || rm -rf "${work:?}"' EXIT
mkdir -p "$work/bin" "$work/etc" "$work/state"
export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_HOST_KEY_CHECKING=False
S="$work/state"
REG="$work/etc/registries.yaml" B="$work/backups" HT="$work/etc/hosts.toml" CFG="$work/etc/config.yaml"
export STUB_STATE="$S" STUB_REG="$REG" STUB_HT="$HT"
PASS='StubRobotPassw0rdFORtest'
PASS2='RotatedRobotPassw0rd2FORtest'
USERNAME='robot$ts-teknoir-demo'
TOKEN='TOKEN123StubOnly'
export STUB_USER_B64=$(printf '%s' "$USERNAME" | base64 -w0) STUB_PASS_B64=$(printf '%s' "$PASS" | base64 -w0) STUB_PASS="$PASS" STUB_TOKEN="$TOKEN"
ALL="$work/all-output.log"; : > "$ALL"

cat > "$work/bin/kubectl" <<'S'
#!/bin/sh
echo "$*" >> "$STUB_STATE/kubectl.log"
case "$*" in
  *"get secret harbor-teamspace-pull"*)
    case "$*" in *"--context vpro"*) ;; *) echo "error: context does not exist" >&2; exit 1;; esac
    [ -f "$STUB_STATE/nocred" ] && exit 0
    case "$*" in
      *'teknoir-demo\.username}'*) printf '%s' "$STUB_USER_B64";;
      *'teknoir-demo\.password}'*) printf '%s' "$STUB_PASS_B64";;
      *) exit 0;;
    esac;;
  *"get node"*) [ -f "$STUB_STATE/node-notready" ] && printf False || printf True;;
  *"rollout status"*) echo "deployment successfully rolled out";;
esac
S
cat > "$work/bin/curl" <<'S'
#!/bin/sh
echo "$*" >> "$STUB_STATE/curl.log"
cfg=""
case " $* " in *" --config - "*) cfg=$(cat);; esac
for a in "$@"; do url=$a; done
case "$url" in
  */v2/)
    [ -f "$STUB_STATE/tlsfail" ] && { echo "curl: (60) SSL certificate problem: unable to get local issuer certificate" >&2; exit 60; }
    printf 401;;
  */service/token*)
    case "$cfg" in
      *"user = \"$STUB_USER_PLAIN:$STUB_PASS\""*) printf '{"token":"%s","expires_in":1800}' "$STUB_TOKEN";;
      *) printf '{"errors":[{"code":"UNAUTHORIZED","message":"unauthorized"}]}';;
    esac;;
  */manifests/*)
    case "$cfg" in
      *"Bearer $STUB_TOKEN"*) [ -f "$STUB_STATE/head403" ] && printf 403 || printf 200;;
      *) printf 401;;
    esac;;
esac
S
cat > "$work/bin/crictl" <<'S'
#!/bin/sh
echo "$*" >> "$STUB_STATE/crictl.log"
case "$1" in
  pull) [ -f "$STUB_STATE/pullfail" ] && { echo "pull failed: 403" >&2; exit 1; }; echo "Image is up to date";;
  info) echo '{"status":{"conditions":[{"type":"RuntimeReady","status":true},{"type":"NetworkReady","status":true}]}}';;
esac
S
cat > "$work/bin/systemctl" <<'S'
#!/bin/sh
echo "$*" >> "$STUB_STATE/systemctl.log"
case "$1" in
  show) cat "$STUB_STATE/unit-$2" 2>/dev/null || echo "LoadState=not-found";;
  is-active) echo active;;
  restart)
    echo "$2" >> "$STUB_STATE/restarts.log"
    if [ -f "$STUB_STATE/restart-fail-once" ]; then rm -f "$STUB_STATE/restart-fail-once"; echo "Job failed" >&2; exit 1; fi
    # k3s rewrites containerd's hosts.toml from registries.yaml at start
    host=$(sed -n 's|^ *- "https://\([^"]*\)"$|\1|p' "$STUB_REG" 2>/dev/null | head -1)
    if [ -n "$host" ] && [ ! -f "$STUB_STATE/hosts-noregen" ]; then
      printf 'server = "https://registry-1.docker.io"\n\n[host."https://%s/v2/dockerhub"]\n  capabilities = ["pull", "resolve"]\n  override_path = true\n' "$host" > "$STUB_HT"
    else
      printf 'server = "https://registry-1.docker.io"\n' > "$STUB_HT"
    fi;;
esac
S
printf '#!/bin/sh\necho Teknoir-Master\n' > "$work/bin/hostname"
chmod +x "$work/bin/"*
export STUB_USER_PLAIN="$USERNAME"

unit_server() { printf 'LoadState=loaded\nKillMode=%s\nExecStart={ path=/usr/local/bin/k3s ; argv[]=/usr/local/bin/k3s server %s ; ignore_errors=no }\n' "${1:-process}" "${2:-}" > "$S/unit-k3s"; rm -f "$S/unit-k3s-agent"; }
unit_agent() { printf 'LoadState=loaded\nKillMode=process\nExecStart={ path=/usr/local/bin/k3s ; argv[]=/usr/local/bin/k3s agent ; ignore_errors=no }\n' > "$S/unit-k3s-agent"; rm -f "$S/unit-k3s"; }
unit_server

run() { ( cd "$repo" && ansible-playbook -i localhost, -c local --limit localhost playbooks/registry-mirror.yml \
  -e registry_use_become=false -e registry_file_owner= -e registry_file="$REG" -e registry_backup_dir="$B" -e registry_hosts_toml="$HT" \
  -e registry_config_yaml="$CFG" -e registry_wait_timeout=10 \
  -e registry_kube_context=vpro -e ansible_teknoir_namespace=teknoir-demo -e ansible_teknoir_domain=test.example \
  -e "{\"registry_local_kubectl_cmd\":[\"$work/bin/kubectl\"],\"registry_kubectl_cmd\":[\"$work/bin/kubectl\"],\"registry_crictl_cmd\":[\"$work/bin/crictl\"],\"registry_curl_cmd\":[\"$work/bin/curl\"],\"registry_systemctl_cmd\":[\"$work/bin/systemctl\"],\"registry_hostname_cmd\":[\"$work/bin/hostname\"]}" \
  "$@" ) 2>&1 | cat; }
# like run, but collects the output for the secret scan
go() { local o; o=$(run "$@"); printf '%s\n' "$o" >> "$ALL"; [ -n "${SHOWALL:-}" ] && printf '=====RUN %s\n%s\n' "$*" "$o" >&2; printf '%s\n' "$o"; }

fail=0
ok() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
restarts() { [ -f "$S/restarts.log" ] && wc -l < "$S/restarts.log" || echo 0; }
nbak() { ls "$B" 2>/dev/null | grep -c . ; }
reset() { rm -rf "$REG" "$B" "$HT" "$S"/restarts.log "$S"/*.log "$S"/nocred "$S"/tlsfail "$S"/head403 "$S"/pullfail "$S"/restart-fail-once "$S"/hosts-noregen "$S"/node-notready; : > "$S/kubectl.log"; unit_server; }
HOST=harbor.test.example

# ---- argument guards
reset
o=$(cd "$repo" && ansible-playbook -i localhost, -c local playbooks/registry-mirror.yml -e registry_kube_context=vpro 2>&1 | cat); ok "no --limit is refused" "echo \"\$o\" | grep -q 'never runs against every device'"
one() { go -i 127.0.0.1, "$@"; }
o=$(one --limit all); ok "--limit all is refused" "echo \"\$o\" | grep -q 'Name exactly one device' && [ ! -e $REG ]"
o=$(one --limit 'local*'); ok "--limit with a wildcard is refused" "echo \"\$o\" | grep -q 'Name exactly one device' && [ ! -e $REG ]"
o=$(one --limit 'localhost,127.0.0.1'); ok "--limit matching two devices is refused" "echo \"\$o\" | grep -q 'matches 2 device' && [ ! -e $REG ]"
o=$(go -e registry_kube_context=); ok "a missing kube context is refused" "echo \"\$o\" | grep -q 'registry_kube_context' && echo \"\$o\" | grep -q 'never defaulted' && [ ! -e $REG ]"
o=$(go -e registry_kube_context=teknoir-poc-eks); ok "a production context is refused" "echo \"\$o\" | grep -q 'production context is refused' && [ ! -e $REG ] && [ ! -s $S/kubectl.log ]"

# ---- pre-flight on the device
reset; unit_server control-group
o=$(go); ok "KillMode other than process is refused" "echo \"\$o\" | grep -q 'no KillMode=process' && [ ! -e $REG ] && [ \$(restarts) = 0 ]"
reset; unit_server process "--docker"
o=$(go); ok "Docker mode is refused" "echo \"\$o\" | grep -q 'Docker mode' && [ ! -e $REG ]"
reset; rm -f "$S/unit-k3s"
o=$(go); ok "a device without k3s is refused" "echo \"\$o\" | grep -q 'no k3s or k3s-agent unit is loaded' && [ ! -e $REG ]"

# ---- fresh install (a server)
reset
o=$(go); [ -n "${SHOW:-}" ] && echo "$o"; [ -n "${STOP:-}" ] && exit 0
ok "fresh install succeeds" "echo \"\$o\" | grep -q 'failed=0' && [ -f $REG ]"
ok "file is ours, mode 0600, with the six mirrors and the credential" "[ \"\$(head -1 $REG)\" = '# managed by teknoir' ] && [ \"\$(stat -c %a $REG)\" = 600 ] && grep -q 'rewrite' $REG && [ \$(grep -c '\"https://$HOST\"' $REG) = 6 ] && grep -q '\"dockerhub/\$1\"' $REG && grep -q '\"nvcr/\$1\"' $REG && grep -q 'password: \"$PASS\"' $REG && grep -q 'username: \"robot\$ts-teknoir-demo\"' $REG"
ok "the file is valid YAML" "python3 -I -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert list(d[\"mirrors\"])==[\"docker.io\",\"ghcr.io\",\"gcr.io\",\"quay.io\",\"registry.k8s.io\",\"nvcr.io\"]; assert d[\"configs\"][\"$HOST\"][\"auth\"][\"password\"]==\"$PASS\"' $REG"
ok "backup directory holds an absent-marker (there was no file)" "[ \$(nbak) = 1 ] && ls $B | grep -q '^registries.yaml.absent-' && [ \"\$(stat -c %a $B)\" = 700 ]"
ok "k3s was restarted once" "[ \$(restarts) = 1 ]"
ok "hosts.toml names the Harbor project, the probe pull ran" "grep -q 'https://$HOST/v2/dockerhub' $HT && grep -q '^pull docker.io/rancher/mirrored-pause:3.6' $S/crictl.log"
ok "the probe ran from the device before the write: /v2/, token, HEAD" "grep -q '/v2/\$' $S/curl.log && grep -q '/service/token?service=harbor-registry&scope=repository:dockerhub/rancher/mirrored-pause:pull' $S/curl.log && grep -q -- '-I' $S/curl.log && grep -q 'manifests/3.6' $S/curl.log"
ok "the credential never appears in a curl argument list" "! grep -q -e '$PASS' -e '$TOKEN' -e 'robot\$ts' $S/curl.log"
ok "only the two credential keys were fetched, no whole Secret" "[ \$(grep -c 'get secret harbor-teamspace-pull' $S/kubectl.log) = 2 ] && ! grep -qE ' -o (json|yaml)( |\$)' $S/kubectl.log && grep -q -- '--context vpro' $S/kubectl.log"
ok "server: node and TOE were waited for" "grep -q 'get node teknoir-master' $S/kubectl.log && grep -q 'rollout status deploy/toe' $S/kubectl.log"
ok "no temporary diff file is left behind" "[ -z \"\$(ls ${TMPDIR:-/tmp} 2>/dev/null | grep '^registry-mirror-diff\\.')\" ]"

# ---- re-run: nothing changes, no restart
n=$(nbak); r=$(restarts); ino=$(stat -c %i "$REG")
o=$(go); ok "re-run is a no-op (no write, no backup, no restart)" "echo \"\$o\" | grep -q 'failed=0' && echo \"\$o\" | grep -q 'already in place' && [ \$(nbak) = $n ] && [ \$(restarts) = $r ] && [ \$(stat -c %i $REG) = $ino ]"

# ---- --check --diff: the probe runs, nothing is changed, the diff is redacted
reset
o=$(go --check --diff)
ok "--check changes nothing (no file, no backup, no restart)" "[ ! -e $REG ] && [ ! -d $B ] && [ \$(restarts) = 0 ]"
ok "--check ran the probe" "grep -q '/service/token' $S/curl.log && grep -q 'manifests/3.6' $S/curl.log"
ok "--check --diff shows the redacted diff" "echo \"\$o\" | grep -q '^+password: \"\\*\\*\\*\\*\\*\\*\\*\\*\"\\|^+      password: \"\\*\\*\\*\\*\\*\\*\\*\\*\"' && echo \"\$o\" | grep -q 'managed by teknoir'"
ok "--check --diff never shows the password" "! echo \"\$o\" | grep -q '$PASS'"
# a changed credential: the diff has no visible change in the file, the plan says so
go >/dev/null
export STUB_PASS_B64=$(printf '%s' "$PASS2" | base64 -w0) STUB_PASS="$PASS2"
o=$(go --check --diff); ok "--check with a new credential: says only the credential changes, shows no password" "echo \"\$o\" | grep -q 'only the credential changes' && ! echo \"\$o\" | grep -q -e '$PASS' -e '$PASS2'"
unset STUB_PASS_B64; export STUB_PASS_B64=$(printf '%s' "$PASS" | base64 -w0) STUB_PASS="$PASS"

# ---- a rotated credential is written, k3s restarted, a second backup exists
export STUB_PASS_B64=$(printf '%s' "$PASS2" | base64 -w0) STUB_PASS="$PASS2"
sleep 1; n=$(nbak); r=$(restarts)
o=$(go); ok "a rotated credential is written and k3s restarted" "echo \"\$o\" | grep -q 'failed=0' && grep -q 'password: \"$PASS2\"' $REG && [ \$(restarts) = $((r+1)) ] && [ \$(nbak) = $((n+1)) ]"
ok "the new backup is the previous file" "grep -q 'password: \"$PASS\"' \"\$(ls $B/registries.yaml.bak-* | tail -1)\" && [ \"\$(stat -c %a \$(ls $B/registries.yaml.bak-* | tail -1))\" = 600 ]"

# ---- rollback restores the newest backup
r=$(restarts)
sleep 1
o=$(go -e registry_rollback=true -e registry_kube_context=); ok "rollback restores the previous credential (needs no kube context)" "echo \"\$o\" | grep -q 'failed=0' && grep -q 'password: \"$PASS\"' $REG && [ \$(restarts) = $((r+1)) ] && ls $B | grep -q 'pre-rollback'"
r=$(restarts)
o=$(go -e registry_rollback=true -e registry_backup=$(ls "$B"/registries.yaml.absent-* | head -1)); ok "rollback to the absent-marker removes the file" "echo \"\$o\" | grep -q 'failed=0' && [ ! -e $REG ] && [ \$(restarts) = $((r+1)) ]"
r=$(restarts)
o=$(go -e registry_rollback=true -e registry_backup=$(ls "$B"/registries.yaml.absent-* | head -1)); ok "rollback to the absent-marker again: nothing to do, no restart" "echo \"\$o\" | grep -q 'failed=0' && [ \$(restarts) = $r ]"
o=$(go -e registry_rollback=true -e registry_backup="$work/nonexistent"); ok "rollback with a missing backup fails" "echo \"\$o\" | grep -q 'failed=1'"
reset
o=$(go -e registry_rollback=true); ok "rollback without any backup is refused" "echo \"\$o\" | grep -q 'No backup in' && [ \$(restarts) = 0 ]"
export STUB_PASS_B64=$(printf '%s' "$PASS" | base64 -w0) STUB_PASS="$PASS"

# ---- a file that is not ours
reset
printf 'mirrors:\n  docker.io:\n    endpoint:\n      - "https://mine.example"\n' > "$REG"; cp "$REG" "$work/foreign"
o=$(go); ok "a foreign registries.yaml is refused and untouched" "echo \"\$o\" | grep -q 'belongs to the device owner' && cmp -s $REG $work/foreign && [ ! -d $B ] && [ \$(restarts) = 0 ] && [ ! -s $S/curl.log ]"
o=$(go --check --diff); ok "a foreign registries.yaml is refused in --check too" "echo \"\$o\" | grep -q 'belongs to the device owner' && cmp -s $REG $work/foreign"
o=$(go -e registry_allow_replace=true); ok "registry_allow_replace=true replaces it and keeps a backup" "echo \"\$o\" | grep -q 'failed=0' && grep -q 'managed by teknoir' $REG && cmp -s \"\$(ls $B/registries.yaml.bak-* | head -1)\" $work/foreign && [ \$(restarts) = 1 ]"
reset
printf '# managed by tnctl bootstrap\nmirrors: {}\n' > "$REG"
o=$(go); ok "a file written by tnctl bootstrap counts as ours" "echo \"\$o\" | grep -q 'failed=0' && grep -q 'managed by teknoir' $REG && ls $B | grep -q '^registries.yaml.bak-'"
reset
printf '# not managed by teknoir\nmirrors: {}\n' > "$REG"
o=$(go); ok "a comment that merely contains the marker text is foreign" "echo \"\$o\" | grep -q 'belongs to the device owner'"

# ---- probe failures stop the run before anything changes
probe_fails() { # <description> <setup> <expected message>
  reset; eval "$2"
  o=$(go)
  ok "$1: refused before any change" "echo \"\$o\" | grep -q '$3' && [ ! -e $REG ] && [ ! -d $B ] && [ \$(restarts) = 0 ]"
}
probe_fails "TLS not trusted" "touch $S/tlsfail" 'curl exit code 60'
probe_fails "no credential in the platform Secret" "touch $S/nocred" 'no usable credential for teamspace teknoir-demo'
probe_fails "Harbor refuses the credential" "export STUB_USER_PLAIN=someone-else" 'gave no token'
export STUB_USER_PLAIN="$USERNAME"
probe_fails "Harbor does not serve the probe image" "touch $S/head403" 'answered'
printf 'x' > /dev/null
ok "a failed probe leaves the credential out of the output" "! grep -q -e '$PASS' -e '$PASS2' -e '$TOKEN' $ALL"

# ---- failures after the write roll back
reset
printf '# managed by teknoir\nmirrors:\n  docker.io:\n    endpoint:\n      - "https://old.example"\nconfigs:\n  "old.example":\n    auth:\n      username: "u"\n      password: "oldpw"\n' > "$REG"; cp "$REG" "$work/ours"
touch "$S/pullfail"
o=$(go); ok "failed probe pull restores the previous file and fails" "echo \"\$o\" | grep -q 'failed=1' && cmp -s $REG $work/ours && echo \"\$o\" | grep -q 'restored' && [ \$(restarts) = 2 ]"
ok "after the rollback the old configuration was restarted and waited for" "[ \$(restarts) = 2 ] && [ \$(grep -c 'rollout status' $S/kubectl.log) = 2 ]"
reset; touch "$S/pullfail"
o=$(go); ok "failed probe pull on a fresh device removes the file again" "echo \"\$o\" | grep -q 'failed=1' && [ ! -e $REG ] && echo \"\$o\" | grep -q 'removed (there was none)' && [ \$(restarts) = 2 ]"
reset; touch "$S/restart-fail-once"
o=$(go); ok "a failed restart is rolled back too" "echo \"\$o\" | grep -q 'failed=1' && [ ! -e $REG ] && [ \$(restarts) = 2 ]"
reset; touch "$S/hosts-noregen"
o=$(go -e registry_wait_timeout=5); ok "hosts.toml without the Harbor project is a failure that rolls back" "echo \"\$o\" | grep -q 'failed=1' && [ ! -e $REG ]"
reset; touch "$S/node-notready"
o=$(go -e registry_wait_timeout=5); ok "a node that does not become Ready is a failure that rolls back" "echo \"\$o\" | grep -q 'failed=1' && [ ! -e $REG ]"
ok "rollbacks leave the credential out of the output" "! grep -q -e '$PASS' -e '$PASS2' -e '$TOKEN' $ALL"

# ---- the node name of a server
reset; printf 'write-kubeconfig-mode: "0644"\nnode-name: "mobile-01-vision"\n' > "$CFG"
o=$(go); ok "server: the node name comes from config.yaml" "echo \"\$o\" | grep -q 'failed=0' && grep -q 'get node mobile-01-vision' $S/kubectl.log"
reset; rm -f "$CFG"
o=$(go -e registry_node_name=custom-node); ok "server: registry_node_name overrides it" "echo \"\$o\" | grep -q 'failed=0' && grep -q 'get node custom-node' $S/kubectl.log"
rm -f "$CFG"

# ---- an agent: no apiserver to ask
reset; unit_agent
o=$(go); ok "agent: installs, waits for containerd, asks no apiserver" "echo \"\$o\" | grep -q 'failed=0' && [ -f $REG ] && grep -q 'info' $S/crictl.log && ! grep -q -e 'get node' -e 'rollout' $S/kubectl.log && grep -q 'restart k3s-agent' $S/systemctl.log"

# ---- nothing secret in any output, also with -vvv
reset
o=$(go -vvv); ok "-vvv run succeeds" "echo \"\$o\" | grep -q 'failed=0'"
reset
o=$(go -vvv --check --diff); ok "-vvv --check --diff run succeeds" "echo \"\$o\" | grep -q 'failed=0'"
ok "the password, the token and the robot secret appear in no output of any run" "! grep -q -e '$PASS' -e '$PASS2' -e '$TOKEN' -e '$STUB_PASS_B64' $ALL"

exit $fail
