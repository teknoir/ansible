# Teknoir Ansible Inventory Plugin
The easiest way to start off is to clone and run the install script:
```bash
./install.sh
```

> Ofc you need to have Ansible installed!
> ... and kubernetes python packages

## Limitations
* As namespaces/labels become groups, and Ansible do not support namespaces/labels with dashes(-).
  * Dashes(-) will be replaced with underscores(_), remember that when using them!!!
* You have to set kubectl context before running ansible commands.
* Start tunneling for the device manually, and disable tunneling when done, all from the teknoir cloud console.

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
## 2024-09-08
* Removed become=yes from inventory.py, so it is possible to run synchronize module, but it also means that you are no longer able to run commands that require sudo by default.
