# Teknoir Ansible playbooks
Playbooks for host-level maintenance of Teknoir devices (OS, k3s service, files) below the Kubernetes layer. Run
them with **tnctl as the inventory**: `tnctl ansible` and `tnctl ansible-playbook` (reference:
[tnctl ansible](https://github.com/teknoir/cli/blob/main/docs/commands/ansible.md)).

> The Teknoir Ansible inventory plugin (`inventory.py`, `install.sh`) in this repo is **deprecated**, see
> [Deprecated: the inventory plugin](#deprecated-the-inventory-plugin).

## Setup
1. Install [tnctl](https://github.com/teknoir/cli) and Ansible (`ansible-core` is enough). Devices on Ubuntu 20.04 (Jetsons on JetPack 5, L4T R35) have Python 3.8, and ansible-core 2.20 and newer stop at Gathering Facts there (`Ansible requires Python 3.9 or newer on the target`). tnctl sets `ansible_python_interpreter=/usr/bin/python3`, and the apt module needs that interpreter's `python3-apt`, so a newer Python on the device does not help. Run those devices with ansible-core 2.19:
   ```bash
   uv venv --python 3.12 ~/.venvs/ansible-2.19 && uv pip install --python ~/.venvs/ansible-2.19 'ansible-core<2.20'
   PATH=~/.venvs/ansible-2.19/bin:$PATH tnctl ansible-playbook playbooks/desktop.yml --limit <orin>
   ```
2. Install the collections the playbooks use:
   ```bash
   ansible-galaxy collection install -r requirements.yml   # ansible.posix, community.general
   ```
3. Sign in and pick the domain and teamspace (or pass `-d <domain> -n <namespace>` to each command):
   ```bash
   tnctl login --domain teknoir.cloud
   tnctl domain
   tnctl ns
   ```

## Inventory and groups
`tnctl ansible-inventory --list` shows the inventory. Hosts are the devices of the teamspace that tnctl can reach:
over WireGuard where it is enabled and active for the device, else through the SSH tunnel (enable tunneling on the
device page). Other devices are left out, with one line on stderr each. `TNCTL_ANSIBLE_TRANSPORT=auto|wireguard|tunnel`
picks the transport.

Groups are the namespace and every device label as `<key>_<value>`; every character outside `A-Za-z0-9_` becomes `_`
(`teknoir-demo` is `teknoir_demo`, `device-group=test` is `device_group_test`, `teknoir.org/robot=amr-01` is
`teknoir_org_robot_amr_01`).

```bash
tnctl ansible-inventory --list
tnctl ansible all --list-hosts
tnctl ansible teknoir_demo --list-hosts
```

## Ansible commands
```bash
tnctl ansible <device> -m ping
tnctl ansible <device> -b -m command -a 'uptime'     # -b: as root
tnctl ansible device_group_test -b -m command -a 'systemctl is-active k3s'
```

`-b` uses sudo. The device bootstrap gives the platform user passwordless sudo when the platform holds no password
for it; otherwise the inventory supplies the platform password. Devices bootstrapped before that need one run of
[Re-bootstrap a device](#re-bootstrap-a-device).

### Synchronize (rsync)
`synchronize` runs its own ssh for rsync: pass `use_ssh_args=yes` so it goes through tnctl's transport, and
`verify_host=yes` so it keeps the host key check. It works with `-b` when the platform user has passwordless sudo.
```bash
# from the device to local
tnctl ansible <device> -m synchronize -a "src=/path/on/device/ dest=/local/path/ mode=pull use_ssh_args=yes verify_host=yes"
# from local to the device
tnctl ansible <device> -m synchronize -a "src=/local/path/ dest=/path/on/device/ use_ssh_args=yes verify_host=yes"
```

## Run playbooks
```bash
tnctl ansible-playbook -v test-playbook.yaml --limit <device>
tnctl ansible-playbook -v test-playbook.yaml --limit <namespace_group>
tnctl ansible-playbook -v test-playbook.yaml --limit <label_group>
```

## k3s CA maintenance
`playbooks/k3s-ca.yml` checks, and on request fixes, the k3s root CA of a device.

A Teknoir device uses its own certificate as the root of the k3s cluster CA. Devices bootstrapped before
the fix have a root without the `keyCertSign` key usage. Such a device is healthy until k3s is upgraded to
v1.34.12 / v1.35.9 / v1.36.5 / v1.37.1 or later, which refuse to start with it. The remediation re-issues the
root from the same key and subject (valid 20 years), so everything signed below it stays valid; it backs up
`server/tls`, runs `k3s certificate rotate-ca` and restarts k3s. Workloads keep running.

The device script is `tn-k3s-ca.sh` from teknoir/cli commit `1d61656` (`pkg/templates/scripts/tn-k3s-ca.sh`),
vendored byte for byte in `playbooks/files/` and sha256-checked on the device before it runs
(`b19b66252eb2247f2ac563e963e55e2adeb327616ad06bc555c50aacb9ea3736`). Use a newer cli version by replacing the
file and `tn_k3s_ca_sha256` in the playbook together.

```bash
# Check only (default). Changes nothing on the device, the temp dir is removed.
# --limit is required: the playbook refuses to run against "all".
tnctl ansible-playbook playbooks/k3s-ca.yml --limit <device>
tnctl ansible-playbook playbooks/k3s-ca.yml --limit <namespace> --tags check

# Remediate: one device at a time (serial 1), the rollout stops at the first failure
tnctl ansible-playbook playbooks/k3s-ca.yml --limit <device> -e tn_k3s_ca_remediate=true
```

What it does per device: copies the script to a root-only temp dir and verifies its sha256; runs `check`
(rc 0 ok, 2 needs rotation, 3 needs regeneration, 4 foreign CA or no server data; rc 1 and, when remediating,
anything but 0 and 2 stop the run); with `tn_k3s_ca_remediate=true` and rc 2 runs `remediate` (in the
background, polled, because a k3s restart can take minutes and may drop the tunnel); then verifies that k3s is
active, `k3s kubectl get nodes` reports every node Ready (within `tn_k3s_ca_ready_timeout`, 600 s), `check`
returns 0 and the TOE deployment (`tn_k3s_ca_toe_deployment`, default `kube-system/toe`, empty to skip) is Ready.
The temp dir is always removed. A re-run on a fixed device is a no-op.

The devices must be reachable through tnctl (WireGuard or the SSH tunnel). Test the playbook on a virtual device or
a VM first.


## Re-bootstrap a device
`playbooks/rebootstrap-device.yml` re-runs the Teknoir bootstrap on a device that already runs Teknoir, with the
script that `tnctl bootstrap <device> --skip-upload` generates from the platform. It brings the platform user,
its sudo, the keys in `/etc/teknoir`, the TOE manifests and the k3s service config up to the current bootstrap
templates. It keeps the installed k3s version, the k3s token and data, and it never rotates the k3s CA
(`TN_K3S_CA_AUTO_REMEDIATE=false`; use `playbooks/k3s-ca.yml` for that).

Run it with tnctl as the inventory (`tnctl ansible-playbook`, tnctl >= the version with teknoir/cli#19), so the
login, domain and teamspace come from tnctl and the connection goes over WireGuard or the tunnel:

```bash
# First run on a device whose platform user still needs a sudo password: log in as another sudoer
tnctl ansible-playbook playbooks/rebootstrap-device.yml --limit <device> \
  -e ansible_user=<sudoer> -e ansible_ssh_private_key_file=~/.ssh/id_rsa
# Afterwards the key-only platform user has passwordless sudo
tnctl ansible-playbook playbooks/rebootstrap-device.yml --limit <device>
tnctl ansible <device> -b -m command -a 'id -u'
```

Only for a k3s server node with containerd: it refuses k3s agent nodes (devices joined to a robot with
`join-robot-agent.yml`), Docker-mode k3s and devices without k3s.

Per device (serial 1, the rollout stops at the first failure): renders the script on the controller in a private
temp dir that is always removed (the script holds the device keys); refuses to continue when the device
certificate in the platform differs from `/etc/teknoir/rsa_public.pem`, or the device has none (it is the root of the
device's k3s CA; adopt the device with `playbooks/adopt-device.yml` instead, or pass
`-e rebootstrap_allow_missing_cert=true`); keeps custom k3s networks (the script rewrites the k3s unit, which would
drop `--cluster-cidr`, `--service-cidr` and `--cluster-dns` given only on the install command line, as virtual devices
have: k3s then crash-loops on the podCIDR of the node): `files/tn-k3s-networks.sh` reads only those three keys from
the unit and `config.yaml[.d]` and writes them to `/etc/rancher/k3s/config.yaml.d/10-k3s-networks.yaml` unless a
drop-in already holds them, and the run stops if they cannot be determined while the node's podCIDR is outside
10.42.0.0/16 (test: `tests/k3s-networks/run.sh`); remembers a TOE image that is pinned by digest (`@sha256:`): the
bootstrap templates regenerate `teknoir.yaml` with the moving tag `docker.io/tekn0ir/toe:toe_v4` and
`imagePullPolicy: Always`, which would undo a TOE rolled out with `playbooks/toe-image.yml`; after the script it puts
the pinned image back the way `toe-image.yml` does (same shared tasks in `playbooks/tasks/`: `crictl pull` and digest
check first, so an unpullable image never reaches the manifest; then backup outside the manifests directory, image line
replaced, `IfNotPresent`, wait for the rollout), prints one line (`TOE image: kept <image> ...`, `nothing to keep`, or a
WARNING when `teknoir.yaml` is not at the default path: custom k3s data-dir, pass `-e toe_manifest=<data-dir>/server/manifests/teknoir.yaml`)
and leaves a TOE on a tag without a digest to the templates. The run fails, and prints `toe-image.yml -e toe_image=<image>`,
when the image cannot be put back or the manifest no longer holds exactly one toe container; the same command is printed
when the run stops earlier. The manifest holds the image pull Secrets and is never printed (`no_log`; test:
`tests/toe-keep/run.sh`); copies the script root-only, runs it in the background
(polled; a k3s restart may drop the connection for a while) with its output in `/var/log/teknoir-rebootstrap.log`,
and removes it; removes duplicate members of the `users` and `sudo` groups that older scripts left; then checks
that k3s is active, the TOE deployment is Ready, and that the platform user has passwordless sudo when the platform
holds no password for it.
`--limit` is required. Test on a VM or virtual device first.

## TOE image rollout
`playbooks/toe-image.yml` switches the TOE (the on-device agent, Deployment `kube-system/toe`) to an immutable,
digest-pinned image, and rolls back. The Deployment lives in `/var/lib/rancher/k3s/server/manifests/teknoir.yaml`, which
k3s re-applies when the file changes, so `kubectl set image` is reverted and the config channel cannot change it; the
playbook edits that file. It is the lighter alternative to `rebootstrap-device.yml`, which would reset the line to
`docker.io/tekn0ir/toe:toe_v4`.

```bash
# Roll out (one device at a time; --limit must name exactly one device, -e toe_image must carry a digest)
tnctl ansible-playbook playbooks/toe-image.yml --limit vm-fresh-01 \
  -e toe_image=ghcr.io/teknoir/toe-app:sha-1a2b3c4d@sha256:<64 hex digits>

# Only look: prints the plan and the diff of the manifest; no pull, no backup, no restart
tnctl ansible-playbook playbooks/toe-image.yml --limit vm-fresh-01 --check --diff -e toe_image=...

# Roll back: restore the newest backup (or -e toe_backup=<file>) and wait for the TOE to be Ready
tnctl ansible-playbook playbooks/toe-image.yml --limit vm-fresh-01 -e toe_rollback=true
```

Per device (`serial: 1`, `max_fail_percentage: 0`: the run stops at the first failure). `--limit` must name exactly one
device: `--limit all`, wildcards and patterns that match several devices are refused unless `-e toe_allow_many=true`.
1. validates `toe_image` (`<registry>/<repo>[:<tag>]@sha256:<digest>`; a reference without a digest is refused) and that
   the manifest holds exactly one toe container (the one after `command: - /manager`). With `toe_pin_server` (default
   true) it also checks that the TOE pod spec (Deployment `kube-system/toe` with `priorityClassName: high-priority-toe`)
   is found exactly once and has no other `nodeSelector`, and that `kubectl get nodes -l
   node-role.kubernetes.io/control-plane=true` returns exactly one node, the k3s server node the TOE has to run on.
   Otherwise the run is refused before anything is changed;
2. **pre-flight, before anything is changed**: reads the TOE object `toe-config` and lists the items the new TOE would
   delete on its first start, the ones in `status.last_applied_config` that `spec.config.items` no longer has (same
   identity as the TOE: API group, kind, namespace, name; no namespace on a cluster-scoped kind, `default` when a
   namespaced item has none). The old TOE returned on its first create error before pruning, so such an item may still run
   on the device, and the new TOE deletes it at once (a HelmChart is uninstalled). The run is refused unless
   `-e toe_allow_prune=true`; look first (`kubectl get toes.teknoir.org toe-config -o yaml`) or fix the device config. A re-run
   with the image already in place is not blocked. The identity is the API group, not the version, so a record with a
   removed apiVersion (`batch/v1beta1`) is listed like any other; the new TOE deletes its object through a served version;
   also **before anything is changed**, asks the apiserver what the new TOE does on its first start with the remaining
   items: `kubectl diff --server-side --field-manager=toe --force-conflicts` per item of `spec.config.items`, a server-side
   dry run that writes nothing (needs `diff` on the device). The old TOE stopped at its first error, did not recreate
   objects deleted by hand and skipped changes, so the new TOE's first pass can install charts that never ran, upgrade
   them and roll Deployments. The play lists what it would **create**, what it would **change**, the items the apiserver
   refuses as server-side apply (an unknown field or a duplicate list key: the TOE applies them with create/merge patch and
   drops what the apiserver does not know, with a Warning Event `ApplyFallback`) and the items that fail outright. Secret
   values are never printed. The run is refused unless `-e toe_allow_changes=true`; a re-run that changes nothing
   (image, policy and nodeSelector already as wanted) is not blocked, but a run that only adds the nodeSelector to the
   image the device already has is checked like any roll;
3. `k3s crictl pull` the image and checks that the cached image carries the requested digest. An unpullable image never
   reaches the manifest: the watchdog reboots a device whose TOE is not Ready, so it would become a reboot loop;
4. copies the manifest to `/var/lib/rancher/k3s/server/toe-image-backups/teknoir.yaml.bak-<UTC time>`, outside the
   manifests directory so that k3s does not apply backups;
5. replaces only the toe container's `image:` and sets `imagePullPolicy: IfNotPresent` (the pinned image stays cached,
   so a registry outage does not stop a TOE restart), and pins the TOE pod to the server node: adds, once and
   idempotently, `nodeSelector: node-role.kubernetes.io/control-plane: "true"` directly under the pod spec (the line
   after `priorityClassName: high-priority-toe`). It does this also when the image is the one the device already has: the
   run then only adds the selector and rolls the Deployment. Why: the TOE mounts the hostPath `/etc/teknoir` (the device
   keys) and signs its MQTT JWT with `rsa_private.pem` from it. On an agent node of the robot (a Raspberry Pi joined to the
   robot, say) it reads that computer's keys, EMQX refuses it (reason 135) and the robot goes offline with the TOE in a
   restart loop. The pin comes first, the image second, so a manifest applied between the two edits never has the new
   image unpinned;
6. waits until the Deployment carries the new image and the nodeSelector, `rollout status` is done (`toe_wait_timeout`,
   default 300 s), and asserts that the live TOE pods run on the server node (and only there). Pods that are Failed or
   Succeeded (Evicted, NodeAffinity, UnexpectedAdmissionError left behind by an earlier ReplicaSet) and pods being
   deleted are ignored;
7. on any failure: restores the backup, waits for the old TOE to be Ready, and fails the run;
8. prints the TOE pod, its node, image, `imageID` and restarts.

A second run with the same image changes nothing (no new backup). `rebootstrap-device.yml` uses the same shared tasks: the
templates write the pod spec without the nodeSelector, so its restore of a digest-pinned TOE image puts the pin back too
(and does so when only the pin is missing). Roll back with `toe_rollback=true`: it restores a backup and, because a backup that predates the pin has no
selector, pins the pod again (after the same pre-flight check on the backup, before anything is changed). `-e toe_pin_server=false` leaves the pod template alone (an existing `nodeSelector`
is never removed), for example on a robot with several server nodes, which the pin refuses (exactly one labelled node is
required). Variables: `toe_image`, `toe_rollback`, `toe_backup`,
`toe_wait_timeout`, `toe_allow_prune`, `toe_allow_changes`, `toe_allow_many`, `toe_pin_server`; the paths and commands (`toe_manifest`, `toe_backup_dir`, `toe_kubectl_cmd`, `toe_crictl_cmd`,
`toe_use_become`) default to a Teknoir device.

Order: a VM device first, then a virtual device, then real devices one by one (check TOE Ready, 0 restarts, the device
Online, no `ApplyFailed` events, before the next). Production devices only with the usual production OK. Never use a
moving tag (`toe_v4`, `latest`); roll back to the old tag by restoring the backup.

**Test it without a device** (fake manifest, stubbed `crictl` and `kubectl`, runs as a normal user):
```bash
tests/toe-image/run.sh
```
It covers validation, the `--limit` guard (all, wildcard, union, two devices), the digest mismatch message,
`--check --diff`, an unpullable image, the prune pre-flight (refused, `--check`, `toe_allow_prune`, namespace
normalization, a fresh device), the create/change pre-flight (creates, changes, items refused as server-side apply,
errors, a namespace created by the same config, `toe_allow_changes`, items sent as the TOE applies them, no secret
values printed), a successful rollout, idempotence, a failing rollout that is restored, and rollback. The pin tests cover a
fresh manifest, an idempotent re-run, an unchanged image that still gets the selector (and is checked like any roll), a
pod spec that is not found exactly once or has another nodeSelector, no or two nodes with the control-plane label, the
TOE pod on another node after the rollout (restored), a Failed or terminating TOE pod left on another node (ignored), the rollback that pins again (and its refusal
on a robot with two labelled nodes), `toe_pin_server=false`, the manifest of the cli bootstrap template (recognised as
already pinned, `tests/toe-image/cli-server.teknoir.yaml`), and that the manifest Secret is never printed. `tests/toe-keep/run.sh` covers the pin in the re-bootstrap restore.

## Registry mirror (Harbor pull-through cache)
`playbooks/registry-mirror.yml` makes a robot that already runs pull its images through the platform's Harbor
(`harbor.<domain>`): Docker Hub, GitHub (`ghcr.io`), `gcr.io`, `quay.io`, `registry.k8s.io` and `nvcr.io` map to the
Harbor proxy-cache projects `dockerhub`, `ghcr`, `gcr`, `quay`, `k8s` and `nvcr`. It writes
`/etc/rancher/k3s/registries.yaml` (root, `0600`, first line `# managed by teknoir`). k3s always tries the upstream
registry last, so a Harbor outage never blocks public images. New robots get the same file from
`tnctl bootstrap --registry-mirror`. Design: `plans/harbor-proxy-staging.md` (workspace).

```bash
# Only look: the probe runs (it only reads), the diff is redacted, nothing is changed
tnctl ansible-playbook playbooks/registry-mirror.yml --limit vm-fresh-01 -e registry_kube_context=vpro --check --diff

# Apply (one device at a time)
tnctl ansible-playbook playbooks/registry-mirror.yml --limit vm-fresh-01 -e registry_kube_context=vpro

# Roll back: restore the newest backup (or -e registry_backup=<file>), restart k3s if the file changes
tnctl ansible-playbook playbooks/registry-mirror.yml --limit vm-fresh-01 -e registry_rollback=true
```

Per device (`serial: 1`, `any_errors_fatal`, `max_fail_percentage: 0`). `--limit` is required and must name exactly one
device (`all`, wildcards and patterns that match several are refused unless `-e registry_allow_many=true`).
1. **pre-flight** on the device: a `k3s` or `k3s-agent` unit, not Docker mode, `KillMode=process` (a k3s restart then
   leaves the pods running; with any other KillMode it would stop them, so the run is refused), and a `registries.yaml`
   whose first line is not `# managed by teknoir` (or `# managed by tnctl bootstrap`) belongs to the device owner and
   is refused unless `-e registry_allow_replace=true`; k3s's data directory is found (the unit's `--data-dir`, else
   `data-dir` in `/etc/rancher/k3s/config.yaml` and `config.yaml.d/*.yaml`, a later drop-in winning, else
   `/var/lib/rancher/k3s`; `-e registry_data_dir=<dir>` skips the search) and the run is refused, nothing changed, when
   `<data-dir>/agent` does not exist (a robot bootstrapped with a custom data-dir keeps containerd's `hosts.toml` there);
2. **credential**, read on the controller with `no_log`: Secret `teknoir-system/harbor-teamspace-pull` of the kube
   context `registry_kube_context`, keys `<ansible_teknoir_namespace>.username` and `.password` (only those two keys are
   fetched; harbor-config creates the robot of every teamspace). The context is required and never defaulted; a
   production context is refused;
3. **probe from the device**, before anything is changed: `https://<host>/v2/` answers `401` with a valid TLS chain, a
   token for `repository:dockerhub/rancher/mirrored-pause:pull` is issued for the credential and a `HEAD` of that
   manifest through Harbor answers `200`. The credential and the token go to curl on stdin (a curl config), never in an
   argument list. A failed probe stops the run with nothing changed;
4. **redacted `--diff`** of `registries.yaml` (password, auth, identity_token and token values show as `********`; when only the
   credential changes the plan says so; with `registry_allow_replace=true` the device owner's file is never printed, only
   its line count);
5. **backup** to `/var/lib/rancher/k3s/registry-mirror-backups/registries.yaml.bak-<UTC>` (outside the k3s directories,
   `0600`), or `registries.yaml.absent-<UTC>` when the device had no file;
6. **write** the file (root, `0600`; only when it differs);
7. **restart k3s only when the file changed**, then wait: on a server the node and the TOE are Ready, on an agent
   the unit is active and containerd reports the runtime ready (an agent has no apiserver to ask);
8. **checks**: containerd's `docker.io` `hosts.toml` has the host `https://<host>/v2` with the rewrite
   `^(.*)$` -> `dockerhub/$1` (the format k3s really writes), `k3s crictl pull docker.io/rancher/mirrored-pause:3.6`
   works, and then a pull of a small **private** image (`registry_proof_image`, default
   `ghcr.io/teknoir/observatory-event-processing-app:latest`, ~100 MB, amd64 and arm64). The public probe also passes
   through the upstream fallback; the private image is refused there (403), so its pull proves that containerd used
   Harbor with the credential and the rewrite. The proof image is removed again (`crictl rmi`, by image ID) unless the
   device had it before the pull, so ~100 MB does not stay on a small robot; a failed removal does not fail the run;
9. **on any failure after step 6**: restores the backup (or removes the file), restarts k3s, waits, then fails.

`-e registry_rollback=true` restores the newest backup by the timestamp in its name, `bak` or `absent` alike (the file it replaces is kept as `registries.yaml.pre-rollback-<UTC>`),
restarts k3s only if the file changes, and waits. After a second change (a re-run for a rotated credential) the newest backup is the previous Harbor file; to remove the mirror altogether add `-e registry_rollback_to=original`, which restores the oldest backup (the owner's file from before the first run, or removes the file when there was none). `--check` stops after step 4. A second run changes nothing (no
backup, no restart). The credential is never printed: not in the plan, the diff, the task output or `-vvv`.

Variables: `registry_kube_context` (required unless rolling back), `registry_host` (default
`harbor.<ansible_teknoir_domain>`), `registry_rollback`, `registry_rollback_to`, `registry_backup`, `registry_allow_replace`,
`registry_allow_many`, `registry_proof_image`, `registry_wait_timeout` (300), `registry_node_name` (default: `node-name` of
`/etc/rancher/k3s/config.yaml`, else the host name); the paths and commands (`registry_file`, `registry_file_owner`,
`registry_backup_dir`, `registry_data_dir`, `registry_hosts_toml` (default `<data-dir>/agent/etc/containerd/certs.d/docker.io/hosts.toml`), `registry_config_yaml`, `registry_*_cmd`, `registry_use_become`) default to a
Teknoir device.

**Credential rotation.** harbor-config (platform chart `harbor`) writes a new password for a teamspace's robot
`robot$ts-<teamspace>` when its key is missing from `harbor-teamspace-pull` or Harbor answers 401/403 for the stored
one, and deleting the keys rotates it on purpose. Every robot of that teamspace then holds a stale password in its
`registries.yaml`: Harbor answers 401, containerd falls through to the upstream, public images keep working and private
`ghcr.io/teknoir/*` images stop pulling. **After a rotation re-run this playbook on every robot of that teamspace**, one
`--limit` at a time (the changed credential is written, k3s restarted, the mirror proven again); nothing does it
automatically yet. Proposed, not built: an alert on failed Harbor logins by `robot$ts-*` (harbor-core access log or the
gateway's 401s on `harbor.<domain>/service/token`, per robot name) so a stale robot shows up before a pull fails.

Order: a VM device first, then real devices one at a time (check TOE Ready, no new restarts and unchanged pod start
times before the next). Production devices only with the usual production OK. The agent nodes of multi-node robots
are not in the tnctl inventory and keep pulling from upstream.

**Test it without a device** (stubbed `kubectl`, `curl`, `crictl`, `systemctl`, `hostname`; no root, no network; takes
about two minutes):
```bash
tests/registry-mirror/run.sh
```
It covers the guards (`--limit`, kube context), the pre-flight (KillMode, Docker mode, no k3s, a foreign file, a file
from `tnctl bootstrap`, the k3s data directory: default, `config.yaml`, drop-ins, the unit's `--data-dir`, a missing
`agent` directory refused before any change), a fresh install, a no-op re-run, `--check --diff`, a rotated credential, rollback (newest,
named, absent-marker, no backup), probe failures (TLS, no credential, refused credential, manifest not served: nothing
changed), the proof image (removed again, kept when it was there before, a failed `rmi`),
failures after the write (probe pull, restart, `hosts.toml`, node not Ready: restored), the node name, an
agent, and that the password, the token and the robot secret appear in no output, also with `-vvv`.

## Remote desktop (host mode)
`playbooks/desktop.yml` turns on the browser remote desktop of a device in **host mode**: the device's own desktop
environment runs in a TigerVNC X server (Xvnc) whose VNC listener is the unix socket
`/run/teknoir-desktop/vnc.sock`. The platform's `teknoir-desktop` pod (injected by the platform, not by this
playbook) mounts `/run/teknoir-desktop` as a hostPath and bridges the socket to the browser; the browser reaches that
pod only through Tunneling, and only a user who may `create pods/exec` in the device's teamspace gets to it (the hub
checks this). This playbook installs the **host side** only.

```bash
# Install, start and check (one device at a time: serial 1)
tnctl ansible-playbook playbooks/desktop.yml --limit rpi4-white-se
tnctl ansible-playbook playbooks/desktop.yml --limit rpi4-white-se -e desktop_geometry=1920x1080

# A device that must not get XFCE (the run fails when it has no session of its own)
tnctl ansible-playbook playbooks/desktop.yml --limit rpi4-white-se -e desktop_install_xfce=false

# Remove the host side again
tnctl ansible-playbook playbooks/desktop.yml --limit rpi4-white-se -e desktop_state=absent
```
`--limit` is required: the playbook refuses to run against every device.
A Jetson on JetPack 5 (Ubuntu 20.04, Python 3.8) needs ansible-core 2.19 or older on your side, see [Setup](#setup).

| Variable | Default | |
| --- | --- | --- |
| `desktop_state` | `present` | `present` installs and starts; `absent` stops, disables and removes the unit, the drop-in, the script, the runtime directory and the X auth cookie |
| `desktop_user` | the device's login user from tnctl (`ansible_teknoir_login_user`), else `teknoir` | the user whose desktop runs; it must exist (the run fails with `user <u> does not exist on <host>`), and it must not be root (uid 0): the desktop has no password. A plain user name (`^[a-z_][a-z0-9_-]{0,31}$`), because it goes into the unit's drop-in |
| `desktop_group` | `teknoir-desktop` | the socket group; a plain group name (`^[a-z_][a-z0-9_-]{0,31}$`), for the same reason |
| `desktop_gid` | `64080` | its gid, the same on every device (the platform's pod runs with `supplementalGroups: [64080]`); an integer 1000..65535 |
| `desktop_geometry` | `1600x900` | the screen size (`^[0-9]{3,4}x[0-9]{3,4}$`) |
| `desktop_install_xfce` | `auto` | `auto`: install XFCE (`xfce4`, `xfce4-terminal`) only when none of `startxfce4`, `startlxqt`, `mate-session` is on the PATH (GNOME never counts, not even with `gnome-flashback`: plain GNOME needs a full graphics stack, and the playbook does not look for the flashback session); `true`: always; `false`: never (the run fails when no session is found) |

Per device (`serial: 1`):
1. validates the variables, then refuses a device that is not Debian or Ubuntu, a `desktop_user` that does not exist
   or is root (uid 0), and a socket group or gid that belongs to something else (the name with another gid, or the gid
   with another name) or that has members other than the desktop user and root (in the group, or with gid 64080 as
   their primary group), and a device with no session (`startxfce4`, `startlxqt`, `mate-session`) when
   `desktop_install_xfce` is `false`. Nothing is changed before those checks pass;
2. creates the group `teknoir-desktop` with gid 64080 when it does not exist;
3. installs `tigervnc-standalone-server`, `dbus-x11` and `xauth` (the session script needs `xauth` for the X auth
   cookie), and XFCE per `desktop_install_xfce` (without its recommendations);
4. installs the session script `/usr/local/libexec/teknoir-desktop-session` (root, 0755) and the unit
   `/etc/systemd/system/teknoir-desktop.service` (root, 0644) from `playbooks/files/teknoir-desktop/`, and the
   drop-in `10-teknoir.conf` (`User`, `Group`, `TEKNOIR_DESKTOP_GROUP`, `TEKNOIR_DESKTOP_GEOMETRY`);
5. refuses another drop-in of the unit that sets a different `User=` or `Group=` (an `override.conf` from
   `systemctl edit` sorts after `10-teknoir.conf` and wins; checked with `systemctl show` after the files are written,
   before the unit is started or restarted), then enables and starts the unit, and restarts it only when one of those
   files changed or XFCE was just installed (the session script then switches to XFCE), or when the running unit is
   older than the installed session script, unit or drop-in (a run that stopped before its restart);
6. checks that the desktop really runs: the socket appears within 30 s, it is a **socket** of mode `0660` owned by
   `desktop_user` in group `teknoir-desktop`, `/run/teknoir-desktop` belongs to that group with group search
   permission, the server answers the VNC banner (`RFB `) on the socket (a `python3` probe as root, 12 bytes, 3 s) and
   Xvnc listens on no TCP port (only the unit's own `Xvnc` counts: another VNC server on the device, a
   `tigervncserver :1` on `127.0.0.1:5901` or a RealVNC one, is not this playbook's), and 8 s after the probe the unit
   is still the same process (a session that exits restarts it) and runs a session process (`xfce4-session`,
   `lxqt-session`, `mate-session` or `gnome-session`). When the socket's owner, group or mode is wrong, or the server
   listens on TCP, the unit is first stopped and disabled. A failed check prints the last 30 lines of
   `journalctl -u teknoir-desktop` and fails the run;
7. prints one line: the user, the group and gid, the session, the Xvnc version, and the next step.

The two host files are vendored from `teknoir/teknoir-desktop` (`host/`); do not edit them here, they are refreshed
from that repo. Everything else is set through the drop-in. Change the user with `-e desktop_user=<user>`, not with an
`override.conf` as in the unit's comment: the playbook refuses a drop-in that sets another `User=` or `Group=`.

**What the unit does.** The session runs as `desktop_user` with primary group `teknoir-desktop`; it is enabled for
`multi-user.target`, so it starts at every boot. `Restart=always`: when the session exits — a logout, or a crash — the
unit starts it again after 5 s, so a logout gives a fresh desktop. It gives up instead of restarting when a package is
missing (no desktop session, no TigerVNC that knows `-rfbunixpath`, no `xauth`, no `dbus-x11`): the session script
then exits with status 78 (EX_CONFIG), and `RestartPreventExitStatus=78` leaves the unit failed. Install the package
and run `systemctl restart teknoir-desktop`.
`RuntimeDirectoryPreserve=yes` keeps `/run/teknoir-desktop` (same inode, so the pod's hostPath keeps working) across a
stop and restart, and `PrivateTmp=yes` gives the unit its own `/tmp` for the X socket and lock. The X display has its
own MIT-MAGIC-COOKIE in `~/.teknoir-desktop.Xauthority` of `desktop_user` (mode 0600, a new one at every start), so
reaching the X socket is not enough to read the screen; it is outside `/run/teknoir-desktop` on purpose, because the
pod can read that directory.

`desktop_state=absent` stops and disables the unit and removes the drop-in, the unit, the session script and
`/run/teknoir-desktop` (which `RuntimeDirectoryPreserve` would otherwise leave behind), and the X auth cookie
`~/.teknoir-desktop.Xauthority` of the user the unit ran as (read from the unit, so `-e desktop_user` is not needed). It leaves the
packages, the user and the group behind (the group's gid is shared with the platform, and another workload may use the
packages). A second run reports no changes, and it fails rather than report success when the unit still runs after the
removal.
**Turn the desktop off on the Device before you remove the host side**: choose **Off** on the device's **Desktop** tab
(Devices → the device → Configure → Desktop), or use kubectl:
`kubectl --context <ctx> -n <teamspace> patch device <name> --type merge -p '{"spec":{"desktop":null}}'`. Otherwise the
platform's pod loses `/run/teknoir-desktop`: it fails its health check and, after a reboot, waits in ContainerCreating
for the hostPath, while the Device still shows the desktop as `Published`.

**Security model.** There is no VNC password, and host mode hands over the device's own session. Whoever opens a host
desktop works as the desktop user, usually with `sudo`, and that user's home folder holds the device's own key
(`~/.ssh/id_rsa`), the key the device signs in to MQTT and SSH with: whoever opens the desktop can copy it and keep
using it after the desktop is turned off. That is why only a teamspace admin can turn on a host desktop in the portal.
When the platform user logs in by key only, it has passwordless sudo
(`/etc/sudoers.d/90-teknoir-platform-user`), and the desktop is then root on the device. A user with a password can
still `sudo` with it. Xvnc listens on no TCP port (`-rfbport -1`,
`-nolisten tcp`). Its VNC listener is `/run/teknoir-desktop/vnc.sock`: mode `0660`, owner `desktop_user`, group
`teknoir-desktop` (gid 64080), in a `0750` directory with the same owner and group. The X display `:7` itself also has
local sockets, and only its X auth cookie guards them. On the device, the VNC socket can be opened by root, by
`desktop_user`, by members of group `teknoir-desktop`, and by any pod that mounts `/run/teknoir-desktop` from the host
and runs as root, as the user's uid, or with `supplementalGroups: [64080]` (the platform's pod). While the Device has
`spec.desktop.mode: host`, that pod serves the session on TCP 6080 with no password (Service
`desktop.teknoir-desktop:6080`). Its NetworkPolicy refuses other pods but admits the node the pod runs on. So every
process on that node's host network reaches the desktop as well, including any local user and any `hostNetwork` pod.
From outside the device, the browser gets there only through Tunneling, after the platform login and the hub's check
that the user may `create pods/exec` in the teamspace. Turn host mode on only on devices that have no untrusted local
users and no untrusted host-network workloads.

**Next step: turn the desktop on for the Device in the platform.** A teamspace admin chooses **Host** on the device's
**Desktop** tab in the portal (Devices → the device → Configure → Desktop; the security model above says why), or with
kubectl. The Device object says whether the platform injects the pod. Without it nothing outside the device reaches the
session, but the unit still starts at every boot and runs the desktop session (Xvnc and the session found or installed
above) as `desktop_user`. The desktop needs Tunneling on the Device (annotation `ztna.teknoir.org/wireguard: enabled`;
without it `status.desktop.state` is `NeedsTunneling`):
```bash
kubectl --context <ctx> -n <teamspace> patch device <name> --type merge -p '{"spec":{"desktop":{"mode":"host"}}}'
```
Check it with
`kubectl --context <ctx> -n <teamspace> get device <name> -o jsonpath='{.subresources.status.desktop}'`: `state` is
`Published`, and `url` is set once the Tunneling web gateway serves it. `Published` says the pod was injected, not
that the host unit works; that is what this playbook's check is for.

## Node roles
A node role is a set of k3s node labels (and optional taints), so workloads can be assigned to the nodes that fill
the role with a plain `nodeSelector`:

| Label | Value |
| --- | --- |
| `teknoir.org/node-role` | the role, for example `vision` (GPU: vision models, NVR) or `io` (cameras, sensors, control) |
| `teknoir.org/robot` | the robot the node belongs to |
| the role's extra labels | from the robot type, for example `teknoir.org/gpu=nvidia` |

**The role is chosen when the node registers.** k3s applies `node-label` / `node-taint` (in
`/etc/rancher/k3s/config.yaml`) at registration, so the place to choose it is the bootstrap (`tnctl bootstrap`). The two
playbooks cover what the bootstrap does not: a device that already runs k3s, and joining a device to another robot.
Labels set with `kubectl` live in the node object: they survive a restart of k3s, but not a node that is deleted and
registers again.

### label-node-role.yml: set the role of a node that exists
For a device that already is a k3s server (a single-node robot, or the server of a multi-node robot), and for the other
nodes of that robot (`node_name=`, the server sets their labels too). It runs `k3s kubectl` on the device.

```bash
tnctl -d teknoir.cloud -n teknoir-demo ansible-playbook playbooks/label-node-role.yml --limit rtx2000-ada-128gb-se \
  -e node_role=vision -e robot=vision-station-01 -e '{"extra_labels": {"teknoir.org/gpu": "nvidia"}}'

# the io node of a multi-node robot, labelled from its server (--limit is the server device)
tnctl -d teknoir.cloud -n teknoir-demo ansible-playbook playbooks/label-node-role.yml --limit orin-agx-32gb-se \
  -e node_role=io -e robot=mobile-01 -e node_name=mobile-01-io

# only look: prints the plan and runs kubectl with --dry-run=server, nothing is written
tnctl -d teknoir.cloud -n teknoir-demo ansible-playbook playbooks/label-node-role.yml --limit orin-agx-32gb-se --check -e node_role=vision -e robot=mobile-01
```

| Variable | |
| --- | --- |
| `node_role`, `robot` | required (label values) |
| `node_name` | default: the control-plane node (`teknoir-master` if there are several) |
| `extra_labels` | dict; quote `true`/`false`; keys under `kubernetes.io/` and `k8s.io/` are refused, as at bootstrap |
| `taints` | list of `{key, value, effect}`, effect `NoSchedule`, `PreferNoSchedule` or `NoExecute` |
| `remove_stale` | default `false`: only adds and changes. `true` also removes labels and taints that an earlier run set and that are not wanted now (the playbook records the keys it sets in the node annotations `teknoir.org/node-role-labels` and `teknoir.org/node-role-taints`), plus the labels in `stale_labels` |
| `stale_labels` | extra label keys that `remove_stale=true` removes (for labels that something else set, for example the bootstrap) |

It is idempotent (a second run reports `changed=0`), never touches a label it did not set unless you say so, and ends by
printing the resulting labels and taints. `--limit` is required.

**Try it on a throwaway cluster** (no device needed): the playbook only needs a `kubectl` it can run, so point it at the
local k3d cluster and run it on localhost without sudo:

```bash
ansible-playbook -i localhost, -c local --limit localhost playbooks/label-node-role.yml \
  -e use_become=false -e '{"kubectl_cmd": ["kubectl", "--context", "k3d-teknoir-dev"]}' \
  -e node_role=vision -e robot=vision-station-01 -e '{"extra_labels": {"teknoir.org/gpu": "nvidia"}}' --check
```

Drop `--check` to apply, run it twice to see the second run change nothing, and clean up with
`kubectl --context k3d-teknoir-dev label node <node> teknoir.org/node-role- teknoir.org/robot- teknoir.org/gpu-` and
`annotate node <node> teknoir.org/node-role-labels- teknoir.org/node-role-taints-`.

### join-robot-agent.yml: re-bootstrap a device as a k3s agent (VM-tested)
> **VM-tested, not yet run on a real device.** It passed the VM steps below on two Debian 13 VMs (2026-10-16, k3s
> v1.34.5+k3s1). It **deletes the k3s of the device** it runs on: have another way in for the first real device. Use an IP
> that is a node IP of the server in `server_url` (it is in the apiserver certificate), not a `.local` name.

Turns a device that is its own single-node robot into an agent node of the robot that runs on another device (for
example the io computer `rpi4-8gb-black-se` joining `mobile-01`, whose server is `orin-agx-32gb-se`). The role is chosen
here, at registration: the playbook writes `node-name`, `node-label` and `node-taint` into the agent's
`/etc/rancher/k3s/config.yaml` before the first start.

```bash
tnctl -d teknoir.cloud -n teknoir-demo ansible-playbook playbooks/join-robot-agent.yml --limit rpi4-8gb-black-se \
  -e robot_server=orin-agx-32gb-se -e server_url=https://192.168.2.51:6443 -e node_name=mobile-01-io \
  -e node_role=io -e robot=mobile-01 -e confirm_wipe=yes
```

What it does: reads the server's k3s release and node token (never printed: a `no_log` variable, handed to the device in a
root-only file that is removed afterwards), checks that the agent can reach `server_url` and that the node name is free on
the server, **stops without `confirm_wipe=yes`** if the device has a k3s of its own, downloads the installer first, and then
starts `files/tn-join-agent.sh` detached: back up the k3s config to `/root/k3s-pre-join.<time>`, uninstall the old k3s,
write the config, install `k3s agent` at the server's release (a kubelet must not be newer than its apiserver). It then waits
on the **server** until the node is Ready and has its labels, and prints them. A device that already is an agent of
`server_url` is left alone. `--check` runs the preflight only.

Things to know before the first real run: the device keeps `/etc/teknoir` but loses the TOE and any tunnel that ran in its
old k3s, so it can become unreachable from the platform (have another way in); the Teknoir Device object of that computer
is not handled here; the device needs internet access for the k3s installer (this is not the airgapped path).

**VM test steps** (nothing here needs a real device): two VMs from the VM rig (`infra/airgap/test/vm/`, or any two Debian
VMs with internet), a *server* (bootstrap it as a server, node name `teknoir-master`) and an *agent* (bootstrap it as its own
server first, so there is a k3s to wipe), both in the inventory (or a static `-i vm-server,vm-agent` inventory with
`ansible_user`).
1. `--check` against the agent: the plan and the config.yaml are printed, nothing changes.
2. Without `confirm_wipe=yes`: the run stops before touching the agent.
3. With `confirm_wipe=yes`: the agent VM becomes node `<node_name>`, Ready on the server, with `teknoir.org/node-role` and
   `teknoir.org/robot`; `kubectl get nodes -L teknoir.org/node-role` on the server shows it; a pod with
   `nodeSelector: {teknoir.org/node-role: io}` lands on it.
4. Run it again: the agent is reported as joined, nothing changes.
5. A wrong `server_url` or an existing node name must stop in the preflight, before the agent is wiped.
Also confirm that `become` works for the tasks that are delegated to `robot_server` (the first one tells at once) and that
the unmodified `tn-join-agent.sh` can be replaced by `tnctl bootstrap` for agents once that writes the role (preferred).

### Checks
```bash
yamllint playbooks/                                       # line length 140
ansible-lint --offline playbooks/label-node-role.yml playbooks/join-robot-agent.yml   # `uv tool install ansible-lint`
ansible-playbook -i localhost, --syntax-check playbooks/label-node-role.yml
```

## Deprecated: the inventory plugin
`inventory.py` (installed by `install.sh` into `~/.ansible/inventory.py` and `~/.ansible.cfg`) was the Teknoir dynamic
inventory before tnctl took over. Use `tnctl ansible` / `tnctl ansible-playbook` instead: same login, domain and
teamspace as every other tnctl command, WireGuard where it is active, passwordless become.

- `install.sh` no longer installs it for a user unless `TEKNOIR_ANSIBLE_LEGACY=1` is set.
- Both inventory scripts print a deprecation line on stderr.
- `ansible.cfg` no longer names an inventory. If `~/.ansible.cfg` still has `inventory = ~/.ansible/inventory.py`,
  remove that line (tnctl passes its own `-i`, so it is not used by `tnctl ansible`, but plain `ansible` would still
  use it).
- A platform with the fleet API (backstage PR #400) no longer puts device logins (`rsa_private`, `userpassword`)
  into the catalog, which `inventory.py` reads. On such a platform `inventory.py` stops with an error that names
  the devices and points to `tnctl ansible-inventory`; it does not return an empty inventory. Use tnctl.
- `inventory.py` sends Backstage only a main token: a stored token with the `teknoir-ztna` (WireGuard hub) audience is
  replaced, and it refreshes with the granted scopes minus `teknoir-ztna`. It refuses a refreshed token that still has
  the audience. Tests: `python3 -m unittest discover -s tests -p 'test_inventory*.py'`.
- `inventory_system.py` and `ansible_system.cfg` (`TEKNOIR_ANSIBLE_INSTALL=system`) stay for the JupyterLab notebook
  image until that image ships tnctl.

# CHANGELOG
## 2026-11-07
* Added `playbooks/desktop.yml`: install, check and remove the host side of the platform's browser remote desktop
  (host mode) on a device — TigerVNC Xvnc on the unix socket `/run/teknoir-desktop/vnc.sock` in group
  `teknoir-desktop` (gid 64080), Xvnc on no TCP port, `xauth` for the display's cookie. It refuses to run without
  `--limit`, refuses a root desktop user and a socket group with other members, and checks that the session stays up
  and runs a desktop session. The host files are vendored from `teknoir/teknoir-desktop` (`host/`) and configured
  through a systemd drop-in.

## 2026-10-16 (2)
* tnctl is the inventory: README rewritten for `tnctl ansible` / `tnctl ansible-playbook`; the inventory plugin
  (`inventory.py`, `install.sh`) is deprecated.

## 2026-10-16
* Added `playbooks/rebootstrap-device.yml`: re-bootstrap a device with the tnctl-generated script, run through
  tnctl as the inventory. Used on the staging devices after key-only platform users got passwordless sudo.

## 2026-10-16 (3)
* Added `playbooks/label-node-role.yml`: set the node role labels (and taints) of a k3s node, idempotent, with `--check` and `remove_stale`.
* Added `playbooks/join-robot-agent.yml` (untested, run on a VM first): re-bootstrap a device as a k3s agent of another device's cluster, role chosen at registration.

## 2026-10-12
* Added `playbooks/k3s-ca.yml`: check and remediate the k3s root CA of a device (no `keyCertSign`).

## 2026-06-09
* Fixed `install.sh` interactivity when run via `curl | bash`.
* Improved `install.sh` confirmation message to reflect installation target.
* Added "Advanced Installation" section to `README.md`.
* Refactored inventory plugin to use `tnctl` context and OAuth2 credentials.
* Removed `kubernetes` dependency; added `PyYAML` and `requests`.
* Updated documentation to reflect `tnctl` integration.

## 2024-09-08
* Removed become=yes from inventory.py, so it is possible to run synchronize module, but it also means that you are no longer able to run commands that require sudo by default.
