#!/usr/bin/env bash
# Local test of playbooks/toe-image.yml against a throwaway directory with a fake manifest and stubbed
# `crictl` / `kubectl`. No device, no cluster, no root needed. Usage: tests/toe-image/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/manifests" "$work/bin"
export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_HOST_KEY_CHECKING=False
M="$work/manifests/teknoir.yaml" B="$work/backups"
D1=$(printf 'a%.0s' $(seq 64)); D2=$(printf 'b%.0s' $(seq 64))
GOOD="ghcr.io/teknoir/toe-app:sha-11111111@sha256:$D1"
GOOD2="ghcr.io/teknoir/toe-app:sha-22222222@sha256:$D2"
NOPULL="ghcr.io/teknoir/toe-app:unpullable@sha256:$D1"
BADROLL="ghcr.io/teknoir/toe-app:badroll@sha256:$D2"
OLD="docker.io/tekn0ir/toe:toe_v4"

cat > "$work/bin/crictl" <<'S'
#!/bin/sh
case "$1" in
  pull) case "$2" in *unpullable*) echo "pull failed" >&2; exit 1;; esac; echo "Image is up to date";;
  inspecti) d=${4#*@}; echo "{\"status\":{\"repoDigests\":[\"$4\"],\"id\":\"sha256:cfg\"}}"; case "$4" in *mismatch*) echo '{"status":{"repoDigests":["x@sha256:0"]}}';; esac;;
esac
S
cat > "$work/bin/kubectl" <<'S'
#!/bin/sh
# image the (fake) k3s has applied = what is in the manifest file
img=$(awk '/- \/manager/{f=1;next} f&&/image:/{print $2;exit}' "$TOE_MANIFEST")
case "$*" in
  *"get deploy"*) printf '%s' "$img";;
  *"rollout status"*) case "$img" in *badroll*) echo "timed out" >&2; exit 1;; esac; echo "deployment successfully rolled out";;
  *"get pods"*) echo "toe-0 $img sha256:cfg restarts=0";;
esac
S
chmod +x "$work/bin/"*
cat > "$M" <<EOT
apiVersion: v1
kind: Namespace
metadata: {name: x}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: toe
  namespace: kube-system
spec:
  template:
    spec:
      containers:
      - args:
        - --health-probe-bind-address=:8081
        command:
        - /manager
        image: $OLD
        imagePullPolicy: Always
        name: toe
      - name: sidecar
        image: other:1
        imagePullPolicy: Always
EOT
export TOE_MANIFEST="$M"
run() { ( cd "$repo" && ansible-playbook -i localhost, -c local --limit localhost playbooks/toe-image.yml \
  -e toe_use_become=false -e toe_manifest="$M" -e toe_backup_dir="$B" -e toe_wait_timeout=10 \
  -e "{\"toe_kubectl_cmd\":[\"$work/bin/kubectl\"],\"toe_crictl_cmd\":[\"$work/bin/crictl\"]}" "$@" ) 2>&1 | cat; }

fail=0
ok() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
img() { awk '/- \/manager/{f=1;next} f&&/image:/{print $2;exit}' "$M"; }
pol() { awk '/- \/manager/{f=1;next} f&&/imagePullPolicy:/{print $2;exit}' "$M"; }

o=$(run -e toe_image="$OLD"); ok "tag without digest is refused" "echo \"\$o\" | grep -q 'refused'"
o=$(run -e toe_image="ghcr.io/x/y@sha256:abc"); ok "short digest is refused" "echo \"\$o\" | grep -q 'refused'"
cp "$M" "$work/before"
o=$(run --check --diff -e toe_image="$GOOD"); [ -n "${SHOW:-}" ] && echo "$o"; ok "check mode changes nothing" "cmp -s $M $work/before && [ ! -d $B ]"
ok "check mode shows the diff" "echo \"\$o\" | grep -q '^+.*image: ghcr.io/teknoir/toe-app:sha-11111111'"
o=$(run -e toe_image="$NOPULL"); ok "unpullable image: run fails, manifest untouched" "! echo \"\$o\" | grep -q 'failed=0' && cmp -s $M $work/before && [ ! -d $B ]"
o=$(run -e toe_image="$GOOD"); ok "rollout succeeds" "echo \"\$o\" | grep -q 'failed=0' && [ \"\$(img)\" = \"$GOOD\" ] && [ \"\$(pol)\" = IfNotPresent ]"
ok "only the toe container changed (sidecar untouched)" "grep -q 'image: other:1' $M && [ \$(grep -c 'imagePullPolicy: Always' $M) = 1 ]"
ok "one backup exists, outside the manifests dir" "[ \$(ls $B | wc -l) = 1 ] && [ \$(ls $work/manifests | wc -l) = 1 ]"
ok "output prints the imageID" "echo \"\$o\" | grep -q 'sha256:cfg'"
n=$(ls "$B" | wc -l); o=$(run -e toe_image="$GOOD"); ok "second run is idempotent (no new backup, changed=0)" "echo \"\$o\" | grep -q 'changed=0' && [ \$(ls $B | wc -l) = $n ]"
sleep 1
o=$(run -e toe_image="$BADROLL"); ok "failed rollout restores the previous manifest and fails" "echo \"\$o\" | grep -q 'failed=1' && [ \"\$(img)\" = \"$GOOD\" ] && echo \"\$o\" | grep -q 'restored'"
sleep 1
o=$(run -e toe_image="$GOOD2"); ok "roll to a second image" "[ \"\$(img)\" = \"$GOOD2\" ]"
sleep 1
o=$(run -e toe_rollback=true); ok "rollback restores the newest backup" "echo \"\$o\" | grep -q 'failed=0' && [ \"\$(img)\" = \"$GOOD\" ]"
first=$(ls "$B"/teknoir.yaml.bak-* | head -1)
o=$(run -e toe_rollback=true -e toe_backup="$first"); ok "rollback to a named backup (the original)" "[ \"\$(img)\" = \"$OLD\" ] && [ \"\$(pol)\" = Always ]"
o=$(run -e toe_rollback=true -e toe_backup="$work/nonexistent"); ok "rollback with a missing backup fails" "echo \"\$o\" | grep -q 'failed=1'"
printf 'foo: bar\n' > "$work/manifests/teknoir.yaml"
o=$(run -e toe_image="$GOOD"); ok "manifest without the toe container is refused" "echo \"\$o\" | grep -q 'found 0'"
exit $fail
