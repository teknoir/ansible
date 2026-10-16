# Teknoir Ansible Inventory Plugin
The easiest way to start off is to run the install script:
```bash
curl -sSL https://raw.githubusercontent.com/teknoir/ansible/main/install.sh | bash
```

> Ofc you need to have Ansible installed!
> ... and `PyYAML`, `requests` python packages

With `ansible-core` only, also install the collections the playbooks use (`ansible.posix` for `synchronize`,
`community.general` for the `debug` stdout callback in `ansible.cfg`):
```bash
ansible-galaxy collection install -r requirements.yml
```

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

> The shipped `ansible.cfg` sets `stdout_callback = debug`, which needs the `community.general` collection
> (`requirements.yml`). Without it use `ANSIBLE_STDOUT_CALLBACK=ansible.builtin.default`.

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

# CHANGELOG
## 2026-10-16
* Added `playbooks/rebootstrap-device.yml`: re-bootstrap a device with the tnctl-generated script, run through
  tnctl as the inventory. Used on the staging devices after key-only platform users got passwordless sudo.

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
