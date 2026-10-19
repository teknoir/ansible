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
  inspecti) case "$4" in *mismatch*) echo '{"status":{"repoDigests":["x@sha256:0"],"id":"sha256:cfg"}}';; *) echo "{\"status\":{\"repoDigests\":[\"$4\"],\"id\":\"sha256:cfg\"}}";; esac;;
esac
S
cat > "$work/bin/kubectl" <<'S'
#!/bin/sh
# image the (fake) k3s has applied = what is in the manifest file
img=$(awk '/- \/manager/{f=1;next} f&&/image:/{print $2;exit}' "$TOE_MANIFEST")
case "$*" in
  *"api-resources"*) printf '%s\n' \
    'namespaces                        ns           v1                                     false        Namespace' \
    'nodes                             no           v1                                     false        Node' \
    'clusterroles                                   rbac.authorization.k8s.io/v1           false        ClusterRole';;
  *"get toes.teknoir.org"*) if [ -f "$TOE_CR" ]; then cat "$TOE_CR"; else echo 'Error from server (NotFound): toes.teknoir.org "toe-config" not found' >&2; exit 1; fi;;
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
export TOE_MANIFEST="$M" TOE_CR="$work/toe-config.json"
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

# ---- digest mismatch: the explanation is shown, the manifest is untouched
cp "$M" "$work/before"
MISMATCH="ghcr.io/teknoir/toe-app:mismatch@sha256:$D1"
o=$(run -e toe_image="$MISMATCH"); ok "digest mismatch is refused with the explanation" "echo \"\$o\" | grep -q 'does not carry the digest' && cmp -s $M $work/before"

# ---- --limit guard (the manifest is still the original one here)
one() { run -i 127.0.0.1, "$@"; }
o=$(one --limit all -e toe_image="$GOOD2"); ok "--limit all is refused" "echo \"\$o\" | grep -q 'Name exactly one device' && cmp -s $M $work/before"
o=$(one --limit 'local*' -e toe_image="$GOOD2"); ok "--limit with a wildcard is refused" "echo \"\$o\" | grep -q 'Name exactly one device' && cmp -s $M $work/before"
o=$(one --limit 'localhost,127.0.0.1' -e toe_image="$GOOD2"); ok "--limit matching two devices is refused" "echo \"\$o\" | grep -q 'matches 2 device' && cmp -s $M $work/before"
o=$(one --limit 'localhost:127.0.0.1' -e toe_image="$GOOD2"); ok "--limit with a union pattern is refused" "echo \"\$o\" | grep -q 'Name exactly one device' && cmp -s $M $work/before"

# ---- pre-flight: what the new TOE would delete on its first start
cr() { cat > "$TOE_CR"; }
cr <<'J'
{"spec":{"config":{"items":[
  {"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"keep","namespace":"default"}}]}},
 "status":{"last_applied_config":{"items":[
  {"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"keep","namespace":"default"}},
  {"apiVersion":"helm.cattle.io/v1","kind":"HelmChart","metadata":{"name":"gone","namespace":"kube-system"}}]}}}
J
n=$(ls "$B" | wc -l)
o=$(run -e toe_image="$GOOD2"); ok "stale record: the rollout is refused and lists the item" "echo \"\$o\" | grep -q 'HelmChart kube-system/gone' && echo \"\$o\" | grep -q 'would delete 1' && cmp -s $M $work/before && [ \$(ls $B | wc -l) = $n ]"
o=$(run --check --diff -e toe_image="$GOOD2"); ok "stale record: --check shows the same refusal" "echo \"\$o\" | grep -q 'HelmChart kube-system/gone' && cmp -s $M $work/before"
sleep 1
o=$(run -e toe_image="$GOOD2" -e toe_allow_prune=true); ok "stale record with toe_allow_prune=true rolls" "echo \"\$o\" | grep -q 'failed=0' && [ \"\$(img)\" = \"$GOOD2\" ] && echo \"\$o\" | grep -q 'HelmChart kube-system/gone'"
o=$(run -e toe_image="$GOOD2"); ok "stale record, image already in place: no flag needed (a no-op re-run)" "echo \"\$o\" | grep -q 'failed=0' && echo \"\$o\" | grep -q 'changed=0'"
sleep 1
o=$(run -e toe_rollback=true -e toe_backup="$first"); ok "back to the original manifest" "[ \"\$(img)\" = \"$OLD\" ]"
cp "$M" "$work/before"
# same identity as the TOE: no namespace on a cluster-scoped kind, "default" for a namespaced one, group in the key
cr <<'J'
{"spec":{"config":{"items":[
  {"apiVersion":"rbac.authorization.k8s.io/v1","kind":"ClusterRole","metadata":{"name":"cr"}},
  {"apiVersion":"v1","kind":"Namespace","metadata":{"name":"ns1","namespace":"default"}},
  {"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"cm","namespace":"default"}},
  {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"d"}}]}},
 "status":{"last_applied_config":{"items":[
  {"apiVersion":"rbac.authorization.k8s.io/v1","kind":"ClusterRole","metadata":{"name":"cr","namespace":"default"}},
  {"apiVersion":"v1","kind":"Namespace","metadata":{"name":"ns1"}},
  {"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"cm"}},
  {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"d","namespace":"default"}}]}}}
J
o=$(run -e toe_image="$GOOD2"); ok "namespace normalization like the TOE: nothing stale, rolls without the flag" "echo \"\$o\" | grep -q 'failed=0' && echo \"\$o\" | grep -q '0 item(s) the new TOE would delete' && [ \"\$(img)\" = \"$GOOD2\" ]"
sleep 1
o=$(run -e toe_rollback=true -e toe_backup="$first"); ok "back to the original manifest again" "[ \"\$(img)\" = \"$OLD\" ]"
cr <<'J'
{"spec":{"config":{"items":[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"x","namespace":"a"}}]}},
 "status":{"last_applied_config":{"items":[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"x","namespace":"b"}}]}}}
J
o=$(run -e toe_image="$GOOD2"); ok "a different namespace of a namespaced kind is a stale item" "echo \"\$o\" | grep -q 'ConfigMap b/x' && [ \"\$(img)\" = \"$OLD\" ]"
cr <<'J'
{"spec":{"config":{"items":[]}}}
J
sleep 1
o=$(run -e toe_image="$GOOD2"); ok "no status yet (fresh device): nothing stale, rolls" "echo \"\$o\" | grep -q 'failed=0' && [ \"\$(img)\" = \"$GOOD2\" ]"
rm -f "$TOE_CR"
sleep 1
o=$(run -e toe_rollback=true -e toe_backup="$first"); ok "back to the original manifest (end of pre-flight tests)" "[ \"\$(img)\" = \"$OLD\" ]"

printf 'foo: bar\n' > "$work/manifests/teknoir.yaml"
o=$(run -e toe_image="$GOOD"); ok "manifest without the toe container is refused" "echo \"\$o\" | grep -q 'found 0'"
exit $fail
