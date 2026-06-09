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

# CHANGELOG
## 2026-06-09
* Fixed `install.sh` interactivity when run via `curl | bash`.
* Improved `install.sh` confirmation message to reflect installation target.
* Added "Advanced Installation" section to `README.md`.
* Refactored inventory plugin to use `tnctl` context and OAuth2 credentials.
* Removed `kubernetes` dependency; added `PyYAML` and `requests`.
* Updated documentation to reflect `tnctl` integration.

## 2024-09-08
* Removed become=yes from inventory.py, so it is possible to run synchronize module, but it also means that you are no longer able to run commands that require sudo by default.
