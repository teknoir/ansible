#!/usr/bin/env bash
# Local test of the TOE-image keeping of playbooks/rebootstrap-device.yml (playbooks/tasks/toe-keep-*.yml)
# against a throwaway manifest and a stubbed kubectl. No device, no root. Usage: tests/toe-keep/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/manifests" "$work/bin"
export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_HOST_KEY_CHECKING=False
M="$work/manifests/teknoir.yaml" B="$work/backups"
D1=$(printf 'a%.0s' $(seq 64))
PINNED="docker.io/tekn0ir/toe:toe_v4.1-cf281112@sha256:$D1"
BADROLL="docker.io/tekn0ir/toe:badroll@sha256:$D1"
TAGONLY="docker.io/tekn0ir/toe:toe_v4.1"
TPL="docker.io/tekn0ir/toe:toe_v4"

cat > "$work/bin/kubectl" <<'S'
#!/bin/sh
img=$(awk '/- \/manager/{f=1;next} f&&/image:/{print $2;exit}' "$TOE_MANIFEST")
case "$*" in
  *"get deploy"*) printf '%s' "$img";;
  *"rollout status"*) case "$img" in *badroll*) echo "timed out" >&2; exit 1;; esac; echo "deployment successfully rolled out";;
esac
S
cat > "$work/bin/crictl" <<'S'
#!/bin/sh
case "$1" in
  pull) case "$2" in *unpullable*) echo "pull failed" >&2; exit 1;; esac; echo "Image is up to date";;
  inspecti) case "$4" in *mismatch*) echo '{"status":{"repoDigests":["x@sha256:0"]}}';; *) echo "{\"status\":{\"repoDigests\":[\"$4\"]}}";; esac;;
esac
S
chmod +x "$work/bin/kubectl" "$work/bin/crictl"
export TOE_MANIFEST="$M"

CANARY="CANARY-PULL-SECRET-$$-xyz"
# slurp returns the file base64-encoded, so a leak shows as the base64 of the file: its first 60 characters
B64HEAD=$(printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: pull, namespace: kube-system}\ntype: kubernetes.io/dockerconfigjson\n' | base64 -w0 | cut -c1-60)
mk() { # image policy
cat > "$M" <<EOT
apiVersion: v1
kind: Secret
metadata: {name: pull, namespace: kube-system}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $CANARY
---
kind: Deployment
metadata:
  name: toe
spec:
  template:
    spec:
      containers:
      - args:
        - --health-probe-bind-address=:8081
        command:
        - /manager
        image: $1
        imagePullPolicy: $2
        name: toe
      - name: sidecar
        image: other:1
        imagePullPolicy: Always
EOT
}
run() { ( cd "$here" && ansible-playbook -i localhost, -c local --limit localhost play.yml \
  -e ansible_become=false -e toe_manifest="$M" -e toe_backup_dir="$B" \
  -e "{\"toe_kubectl_cmd\":[\"$work/bin/kubectl\"],\"toe_crictl_cmd\":[\"$work/bin/crictl\"]}" "$@" ) 2>&1 | cat; }
img() { awk '/- \/manager/{f=1;next} f&&/image:/{print $2;exit}' "$M"; }
pol() { awk '/- \/manager/{f=1;next} f&&/imagePullPolicy:/{print $2;exit}' "$M"; }
fail=0
ok() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

# 1. pinned TOE, the script writes the template's image: put back
mk "$PINNED" IfNotPresent; rm -rf "$B"
o=$(run -e fake_script=rewrite)
ok "script ran and the run passed" "echo \"\$o\" | grep -q 'failed=0'"
ok "digest-pinned image and IfNotPresent are back" "[ \"\$(img)\" = \"$PINNED\" ] && [ \"\$(pol)\" = IfNotPresent ]"
ok "one status line says kept, put back" "[ \$(echo \"\$o\" | grep -c 'TOE image:') = 1 ] && echo \"\$o\" | grep -q 'TOE image: kept $PINNED (put back'"
ok "backup of the script's manifest is outside the manifests dir (holds the template image)" "[ \$(ls $B | wc -l) = 1 ] && grep -q 'toe:toe_v4$' $B/* && [ \$(ls $work/manifests | wc -l) = 1 ]"
ok "sidecar untouched" "grep -q 'image: other:1' $M && [ \$(grep -c 'imagePullPolicy: Always' $M) = 1 ]"

# 2. pinned TOE, the script leaves the manifest: nothing changes, no backup
mk "$PINNED" IfNotPresent; rm -rf "$B"; cp "$M" "$work/before"
o=$(run -e fake_script=keep)
ok "script left it: no change, no backup" "echo \"\$o\" | grep -q 'failed=0' && cmp -s $M $work/before && [ ! -d $B ] && echo \"\$o\" | grep -q 'TOE image: kept $PINNED (the script left it)'"

# 2b. pinned image with imagePullPolicy Always (the script changed only the policy): policy corrected
mk "$PINNED" Always; rm -rf "$B"
o=$(run -e fake_script=keep)
ok "pinned image with policy Always is set to IfNotPresent" "[ \"\$(img)\" = \"$PINNED\" ] && [ \"\$(pol)\" = IfNotPresent ]"

# 3. a tag without digest is left to the templates
mk "$TAGONLY" Always; rm -rf "$B"
o=$(run -e fake_script=rewrite)
ok "tag without digest: not touched" "echo \"\$o\" | grep -q 'failed=0' && [ \"\$(img)\" = \"$TPL\" ] && [ \"\$(pol)\" = Always ] && [ ! -d $B ] && echo \"\$o\" | grep -q 'TOE image: nothing to keep'"

# 4. the stock template image: nothing to keep
mk "$TPL" Always; rm -rf "$B"
o=$(run -e fake_script=rewrite)
ok "template tag: nothing to keep" "echo \"\$o\" | grep -q 'nothing to keep' && [ \"\$(img)\" = \"$TPL\" ]"

# 5. no manifest: no failure, a warning (see 11)
rm -f "$M"
o=$(run -e fake_script=keep)
ok "no manifest: no failure" "echo \"\$o\" | grep -q 'failed=0'"

# 6. the rollout of the kept image fails: the script's manifest is restored, the run fails
mk "$BADROLL" IfNotPresent; rm -rf "$B"
o=$(run -e fake_script=rewrite)
ok "failed rollout: run fails, script's manifest restored" "echo \"\$o\" | grep -q 'failed=1' && [ \"\$(img)\" = \"$TPL\" ] && echo \"\$o\" | grep -q 'manifest of the script was restored'"

# 7. the failed run prints no token-like output
ok "no token-like output" "! echo \"\$o\" | grep -qi 'token'"

# 8. unpullable / wrong-digest pinned image: never reaches the manifest, the run fails with the hint
UNPULL="docker.io/tekn0ir/toe:unpullable@sha256:$D1"
mk "$UNPULL" IfNotPresent; rm -rf "$B"
o=$(run -e fake_script=rewrite)
ok "unpullable image: run fails, the script's manifest is left, no backup, hint names the image" "echo \"\$o\" | grep -q 'failed=1' && [ \"\$(img)\" = \"$TPL\" ] && [ ! -d $B ] && echo \"\$o\" | grep -q 'playbooks/toe-image.yml -e toe_image=$UNPULL'"
MISM="docker.io/tekn0ir/toe:mismatch@sha256:$D1"
mk "$MISM" IfNotPresent; rm -rf "$B"
o=$(run -e fake_script=rewrite)
ok "digest mismatch: run fails, the script's manifest is left" "echo \"\$o\" | grep -q 'failed=1' && [ \"\$(img)\" = \"$TPL\" ] && [ ! -d $B ] && echo \"\$o\" | grep -q 'does not carry the digest'"

# 9. the manifest cannot be understood after the script, an image was to be kept: fail with the hint
mk "$PINNED" IfNotPresent
o=$(run -e fake_script=delete)
ok "manifest gone after the script: fails with the hint (not 'the script left it')" "echo \"\$o\" | grep -q 'failed=1' && ! echo \"\$o\" | grep -q 'the script left it' && echo \"\$o\" | grep -q 'playbooks/toe-image.yml -e toe_image=$PINNED'"
mk "$PINNED" IfNotPresent
o=$(run -e fake_script=double)
ok "two toe containers after the script: fails with the hint" "echo \"\$o\" | grep -q 'failed=1' && echo \"\$o\" | grep -q '2 toe container' && echo \"\$o\" | grep -q 'playbooks/toe-image.yml -e toe_image=$PINNED'"

# 10. a step between the script and the restore fails: the hint is printed; a good run prints none
mk "$PINNED" IfNotPresent
o=$(run -e fake_script=rewrite -e fake_fail=true)
ok "failure before the restore: hint with the pinned image" "echo \"\$o\" | grep -q 'failed=1' && echo \"\$o\" | grep -q 'stopped before its TOE image was checked' && echo \"\$o\" | grep -q 'toe_image=$PINNED'"
mk "$PINNED" IfNotPresent
o=$(run -e fake_script=rewrite)
ok "good run: no hint" "! echo \"\$o\" | grep -q 'stopped before its TOE image'"
mk "$TPL" Always
o=$(run -e fake_script=rewrite -e fake_fail=true)
ok "nothing remembered: no hint on failure" "echo \"\$o\" | grep -q 'failed=1' && ! echo \"\$o\" | grep -q 'stopped before its TOE image'"

# 11. no manifest at the default path (custom k3s data-dir): a clear warning, not "nothing to keep"
rm -f "$M"
o=$(run -e fake_script=keep)
ok "missing manifest: warning names the path and the data-dir" "echo \"\$o\" | grep -q 'WARNING: TOE manifest not found at $M: custom k3s data-dir? the TOE image was not kept' && ! echo \"\$o\" | grep -q 'nothing to keep'"

# 12. the manifest holds Secrets: its content is never printed, at any verbosity
for v in -v -vvv; do
  mk "$PINNED" IfNotPresent; o=$(run -e fake_script=rewrite $v)
  ok "$v run restored the image" "echo \"\$o\" | grep -q 'failed=0' && [ \"\$(img)\" = \"$PINNED\" ]"
  ok "$v: the Secret in the manifest is never printed (plain or base64)" "! echo \"\$o\" | grep -q '$CANARY' && ! echo \"\$o\" | grep -qF '$B64HEAD'"
done
for v in "--diff -vvv" "--check --diff -vvv"; do
  mk "$PINNED" IfNotPresent; o=$(run -e fake_script=rewrite $v)
  ok "$v: the Secret in the manifest is never printed (plain or base64)" "echo \"\$o\" | grep -q 'PLAY RECAP' && ! echo \"\$o\" | grep -q '$CANARY' && ! echo \"\$o\" | grep -qF '$B64HEAD'"
done
mk "$PINNED" IfNotPresent; o=$(run -e fake_script=rewrite --diff -vvv)
ok "--diff -vvv run restored the image" "echo \"\$o\" | grep -q 'failed=0' && [ \"\$(img)\" = \"$PINNED\" ]"
mk "$PINNED" IfNotPresent; o=$(run -e fake_script=delete -vvv)
ok "-vvv failing run: the Secret is never printed (plain or base64)" "! echo \"\$o\" | grep -q '$CANARY' && ! echo \"\$o\" | grep -qF '$B64HEAD'"

[ $fail = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
