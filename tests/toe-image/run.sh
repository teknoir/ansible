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
  *"diff --server-side"*)
    # `kubectl diff --server-side` of one item on stdin; the name prefix picks the answer. Exit 0 no difference,
    # 1 difference ("@@ -0,0" = the object does not exist), 2 error.
    in=$(cat); printf '%s\n' "$in" >> "$TOE_DIFF_LOG"
    case "$in" in
      *'"name": "new-'*) printf '%s\n' '--- LIVE' '+++ MERGED' '@@ -0,0 +1,3 @@' '+apiVersion: v1'; exit 1;;
      *'"name": "chg-'*) printf '%s\n' '--- LIVE' '+++ MERGED' '@@ -1,3 +1,3 @@' '-a: "1"' '+a: "2"'; exit 1;;
      *'"name": "fb-'*) echo 'Error from server: failed to create typed patch object (default/fb; apps/v1, Kind=Deployment): .spec.bogus: field not declared in schema' >&2; exit 2;;
      *'"name": "err-'*) echo 'Error from server (Invalid): Deployment.apps "err" is invalid: spec.selector: field is immutable' >&2; exit 2;;
      *'"name": "dep-'*) echo 'Error from server (NotFound): namespaces "new-ns" not found' >&2; exit 2;;
    esac
    exit 0;;
  *"get toes.teknoir.org"*) if [ -f "$TOE_CR" ]; then cat "$TOE_CR"; else echo 'Error from server (NotFound): toes.teknoir.org "toe-config" not found' >&2; exit 1; fi;;
  *"get deploy"*) printf '%s' "$img";;
  *"rollout status"*) case "$img" in *badroll*) echo "timed out" >&2; exit 1;; esac; echo "deployment successfully rolled out";;
  *"get pods"*) echo "toe-0 $img sha256:cfg restarts=0";;
esac
S
chmod +x "$work/bin/"*
CANARY="CANARY-PULL-SECRET-$$-xyz"
cat > "$M" <<EOT
apiVersion: v1
kind: Namespace
metadata: {name: x}
---
apiVersion: v1
kind: Secret
metadata: {name: pull, namespace: kube-system}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $CANARY
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
export TOE_MANIFEST="$M" TOE_CR="$work/toe-config.json" TOE_DIFF_LOG="$work/diff.log"
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
ok "check mode shows the image before and after (the plan, not a file diff)" "echo \"\$o\" | grep -qF -- '-> $GOOD (IfNotPresent)' && echo \"\$o\" | grep -qF '$OLD (Always)'"
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

# ---- pre-flight: what the new TOE would create or change (server-side dry run per config item)
specs() { printf '{"spec":{"config":{"items":[%s]}},"status":{"last_applied_config":{"items":[]}}}\n' "$1" > "$TOE_CR"; }
CM='{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s"%s},"data":{"a":"1"}}'
cmi() { printf "$CM" "$1" "${2:+,\"namespace\":\"$2\"}"; }
cp "$M" "$work/before"; n=$(ls "$B" | wc -l)
specs "$(cmi same default)"
: > "$TOE_DIFF_LOG"
o=$(run -e toe_image="$GOOD2"); ok "no difference: rolls without the flag" "echo \"\$o\" | grep -q 'failed=0' && echo \"\$o\" | grep -q '0 create, 0 change, 0 refused as server-side apply' && [ \"\$(img)\" = \"$GOOD2\" ]"
sleep 1
o=$(run -e toe_rollback=true -e toe_backup="$first"); ok "back to the original manifest (changes pre-flight)" "[ \"\$(img)\" = \"$OLD\" ]"
cp "$M" "$work/before"; n=$(ls "$B" | wc -l)
specs "$(cmi new-cm default),$(cmi chg-cm kube-system)"
o=$(run -e toe_image="$GOOD2"); ok "creates and changes: refused, listed, nothing changed" "echo \"\$o\" | grep -q 'create ConfigMap default/new-cm' && echo \"\$o\" | grep -q 'change ConfigMap kube-system/chg-cm' && echo \"\$o\" | grep -q '1 create, 1 change' && echo \"\$o\" | grep -q 'Nothing was changed' && cmp -s $M $work/before && [ \$(ls $B | wc -l) = $n ]"
o=$(run --check --diff -e toe_image="$GOOD2"); ok "creates and changes: --check shows the same refusal" "echo \"\$o\" | grep -q 'create ConfigMap default/new-cm' && cmp -s $M $work/before"
specs "$(cmi fb-cm default)"
o=$(run -e toe_image="$GOOD2"); ok "item refused as server-side apply: refused, listed as applied the old way" "echo \"\$o\" | grep -q 'ConfigMap default/fb-cm' && echo \"\$o\" | grep -q '1 refused as server-side apply' && cmp -s $M $work/before"
specs "$(cmi err-cm default)"
o=$(run -e toe_image="$GOOD2"); ok "item the apiserver fails on: refused with the first line of the error" "echo \"\$o\" | grep -q 'error(s)' && echo \"\$o\" | grep -q 'field is immutable' && cmp -s $M $work/before"
# an item in a namespace that another new item creates is a create, not an error
specs "{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"name\":\"new-ns\"}},$(cmi dep-cm new-ns)"
o=$(run -e toe_image="$GOOD2"); ok "item in a namespace created by this config: create, not error" "echo \"\$o\" | grep -q '2 create, 0 change, 0 refused' && echo \"\$o\" | grep -q ' 0 error(s)' && cmp -s $M $work/before"
sleep 1
o=$(run -e toe_image="$GOOD2" -e toe_allow_changes=true); ok "toe_allow_changes=true rolls" "echo \"\$o\" | grep -q 'failed=0' && [ \"\$(img)\" = \"$GOOD2\" ]"
o=$(run -e toe_image="$GOOD2"); ok "changes pending, image already in place: no flag needed (a no-op re-run)" "echo \"\$o\" | grep -q 'failed=0' && echo \"\$o\" | grep -q 'changed=0'"
sleep 1
o=$(run -e toe_rollback=true -e toe_backup="$first"); ok "back to the original manifest (changes pre-flight 2)" "[ \"\$(img)\" = \"$OLD\" ]"
# items are sent as the TOE applies them: namespace default for namespaced kinds, none for cluster-scoped, no status, secrets not echoed
cat > "$TOE_CR" <<'J'
{"spec":{"config":{"items":[
  {"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"nons"},"status":{"x":1}},
  {"apiVersion":"rbac.authorization.k8s.io/v1","kind":"ClusterRole","metadata":{"name":"cr","namespace":"default"}},
  {"apiVersion":"v1","kind":"Secret","metadata":{"name":"new-secret","namespace":"default"},"stringData":{"pw":"SECRETVALUE"}}]}}}
J
: > "$TOE_DIFF_LOG"
o=$(run -e toe_image="$GOOD2"); ok "secret value is not printed" "! echo \"\$o\" | grep -q SECRETVALUE"
o=$(run -vvv -e toe_image="$GOOD2"); ok "secret value is not printed with -vvv" "! echo \"\$o\" | grep -q SECRETVALUE"
ok "the -vvv run did run the playbook" "echo \"\$o\" | grep -q 'Server-side dry run'"
# the manifest holds Secrets (image pull secrets): slurp returns it base64-encoded, so a leak shows as the base64 of the file
B64HEAD=$(printf 'apiVersion: v1\nkind: Namespace\nmetadata: {name: x}\n---\napiVersion: v1\nkind: Secret\n' | base64 -w0 | cut -c1-60)
ok "the manifest Secret is not printed with -vvv (plain or base64)" "! echo \"\$o\" | grep -q '$CANARY' && ! echo \"\$o\" | grep -qF '$B64HEAD'"
for v in "--diff -vvv" "--check --diff -vvv"; do
  o=$(run $v -e toe_image="$GOOD"); ok "the manifest Secret is not printed with $v on a roll (plain or base64)" "echo \"\$o\" | grep -q 'PLAY RECAP' && ! echo \"\$o\" | grep -q '$CANARY' && ! echo \"\$o\" | grep -qF '$B64HEAD'"
done
o=$(run --diff -vvv -e toe_rollback=true); ok "the manifest Secret is not printed with --diff -vvv on a rollback" "! echo \"\$o\" | grep -q '$CANARY' && ! echo \"\$o\" | grep -qF '$B64HEAD'"
o=$(run -vvv -e toe_rollback=true); ok "the manifest Secret is not printed with -vvv on a rollback" "! echo \"\$o\" | grep -q '$CANARY' && ! echo \"\$o\" | grep -qF '$B64HEAD'"
ok "namespaced item without a namespace is sent to default" "grep '\"name\": \"nons\"' $TOE_DIFF_LOG | grep -q '\"namespace\": \"default\"'"
ok "status is not sent" "! grep -q '\"status\"' $TOE_DIFF_LOG"
ok "cluster-scoped item is sent without a namespace" "! grep '\"name\": \"cr\"' $TOE_DIFF_LOG | grep -q namespace"
rm -f "$TOE_CR"

printf 'foo: bar\n' > "$work/manifests/teknoir.yaml"
o=$(run -e toe_image="$GOOD"); ok "manifest without the toe container is refused" "echo \"\$o\" | grep -q 'found 0'"
rm -f "$work/manifests/teknoir.yaml"
o=$(run -e toe_image="$GOOD"); ok "missing manifest is refused with the path" "echo \"\$o\" | grep -q 'TOE manifest not found at $M'"
exit $fail
