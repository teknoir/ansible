# Teknoir Ansible Inventory Plugin
The easiest way to start off is to run the install script:
```bash
curl -sSL https://raw.githubusercontent.com/teknoir/ansible/main/install.sh | bash
```

> Ofc you need to have Ansible installed!
> ... and `PyYAML`, `requests` python packages

## Limitations
* As namespaces/labels become groups, and Ansible do not support namespaces/labels with dashes(-).
  * Dashes(-) will be replaced with underscores(_), remember that when using them!!!
* Start tunneling for the device manually, and disable tunneling when done, all from the teknoir cloud console.

## Authentication & Context
This plugin uses the credentials and context managed by the `tnctl` CLI tool.

### Login
Log in to the Teknoir platform:
```bash
tnctl login --domain <domain>
```
__Where `<domain>` is the domain you want to login to, e.g. `teknoir.cloud`__

### Set Domain & Namespace
The inventory will use the active domain and namespace set in `tnctl`.
```bash
# Switch Domain
tnctl domain

# Switch Namespace
tnctl ns
```

## Namespaces & labels become ansible groups
To see all ansible groups use the inventory command below.

> Dashes(-) will be replaced with underscores(_), remember that when limiting playbooks
> Device labels are concatenated with underscore i.e. f"{key}_{value}" to create an ansible group name

## Inventory
Creates an inventory so you are able to connect to any device in any namespace.
To see inventory run:
```bash
python3 inventory.py --list
```

### List devices
```bash
ansible -i inventory.py --list-hosts all
```

## List devices
```bash
ansible -i inventory.py --list-hosts <namespace>
```

## Ansible commands
Quick commands to manipulate devices

### Synchronize (rsync) from host to local
```bash
ansible <device_name> -m synchronize -a "src=/path/to/source/dir/ dest=/path/to/local/target/dir/ use_ssh_args=yes mode=pull"
```
_Synchronize does not work with "become"(sudo)_

### Syncronize (rsync) from local to host
```bash
ansible <device_name> -m synchronize -a "src=/path/to/local/source/dir/ dest=/path/to/target/dir/ use_ssh_args=yes"
```
_Synchronize does not work with "become"(sudo)_

## Run playbook examples
Run for one device:
```bash
ansible-playbook -v -i inventory.py test-playbook.yaml --limit <device_name>
```

### Run for all devices in a namespace:
```bash
ansible-playbook -v -i inventory.py test-playbook.yaml --limit <namespace>
```

### Run for all devices with label:
```bash
ansible-playbook -v -i inventory.py test-playbook.yaml --limit <label>
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
ansible-playbook -i inventory.py playbooks/k3s-ca.yml --limit <device>
ansible-playbook -i inventory.py playbooks/k3s-ca.yml --limit <namespace> --tags check

# Remediate: one device at a time (serial 1), the rollout stops at the first failure
ansible-playbook -i inventory.py playbooks/k3s-ca.yml --limit <device> -e tn_k3s_ca_remediate=true
```

What it does per device: copies the script to a root-only temp dir and verifies its sha256; runs `check`
(rc 0 ok, 2 needs rotation, 3 needs regeneration, 4 foreign CA or no server data; rc 1 and, when remediating,
anything but 0 and 2 stop the run); with `tn_k3s_ca_remediate=true` and rc 2 runs `remediate` (in the
background, polled, because a k3s restart can take minutes and may drop the tunnel); then verifies that k3s is
active, `k3s kubectl get nodes` reports every node Ready (within `tn_k3s_ca_ready_timeout`, 600 s), `check`
returns 0 and the TOE deployment (`tn_k3s_ca_toe_deployment`, default `kube-system/toe`, empty to skip) is Ready.
The temp dir is always removed. A re-run on a fixed device is a no-op.

The devices must have remote access (tunnel) switched on in the Teknoir console, see Limitations. Test the
playbook on a virtual device or a VM first.

> The shipped `ansible.cfg` sets `stdout_callback = debug`, which needs the `community.general` collection.
> With `ansible-core` alone use `ANSIBLE_STDOUT_CALLBACK=ansible.builtin.default`.

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
ansible-playbook -i inventory.py playbooks/label-node-role.yml --limit vision-station-01 \
  -e node_role=vision -e robot=vision-station-01 -e '{"extra_labels": {"teknoir.org/gpu": "nvidia"}}'

# the io node of a multi-node robot, labelled from its server (--limit is the server device)
ansible-playbook -i inventory.py playbooks/label-node-role.yml --limit mobile-01 \
  -e node_role=io -e robot=mobile-01 -e node_name=rpi4-8gb-black-se

# only look: prints the plan and runs kubectl with --dry-run=server, nothing is written
ansible-playbook -i inventory.py playbooks/label-node-role.yml --limit mobile-01 --check -e node_role=io -e robot=mobile-01
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
ansible-playbook -i inventory.py playbooks/join-robot-agent.yml --limit rpi4-8gb-black-se \
  -e robot_server=orin-agx-32gb-se -e server_url=https://orin-agx-32gb-se.local:6443 \
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

# CHANGELOG
## 2026-10-16
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
