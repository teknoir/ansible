# Teknoir Ansible playbooks
Playbooks for host-level maintenance of Teknoir devices (OS, k3s service, files) below the Kubernetes layer. Run
them with **tnctl as the inventory**: `tnctl ansible` and `tnctl ansible-playbook` (reference:
[tnctl ansible](https://github.com/teknoir/cli/blob/main/docs/commands/ansible.md)).

> The Teknoir Ansible inventory plugin (`inventory.py`, `install.sh`) in this repo is **deprecated**, see
> [Deprecated: the inventory plugin](#deprecated-the-inventory-plugin).

## Setup
1. Install [tnctl](https://github.com/teknoir/cli) and Ansible (`ansible-core` is enough).
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
`-e rebootstrap_allow_missing_cert=true`); copies the script root-only, runs it in the background
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
   the manifest holds exactly one toe container (the one after `command: - /manager`);
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
   values are never printed. The run is refused unless `-e toe_allow_changes=true`; a re-run with the image already in place
   is not blocked;
3. `k3s crictl pull` the image and checks that the cached image carries the requested digest. An unpullable image never
   reaches the manifest: the watchdog reboots a device whose TOE is not Ready, so it would become a reboot loop;
4. copies the manifest to `/var/lib/rancher/k3s/server/toe-image-backups/teknoir.yaml.bak-<UTC time>`, outside the
   manifests directory so that k3s does not apply backups;
5. replaces only the toe container's `image:` and sets `imagePullPolicy: IfNotPresent` (the pinned image stays cached,
   so a registry outage does not stop a TOE restart);
6. waits until the Deployment carries the new image and `rollout status` is done (`toe_wait_timeout`, default 300 s);
7. on any failure: restores the backup, waits for the old TOE to be Ready, and fails the run;
8. prints the TOE pod, its image, `imageID` and restarts.

A second run with the same image changes nothing (no new backup). Variables: `toe_image`, `toe_rollback`, `toe_backup`,
`toe_wait_timeout`, `toe_allow_prune`, `toe_allow_changes`, `toe_allow_many`; the paths and commands (`toe_manifest`, `toe_backup_dir`, `toe_kubectl_cmd`, `toe_crictl_cmd`,
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
values printed), a successful rollout, idempotence, a failing rollout that is restored, and rollback.

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
- `inventory_system.py` and `ansible_system.cfg` (`TEKNOIR_ANSIBLE_INSTALL=system`) stay for the JupyterLab notebook
  image until that image ships tnctl.

# CHANGELOG
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
