# Teknoir Ansible Inventory and Connection Plugin
The easiest way to start off is to copy content of this repo

> Ofc you need to have Ansible installed!
> ... and kubernetes python packages

## Limitations
* As namespaces/labels become groups, we do not support namespaces/labels with dashes(-).
  * Dashes(-) will be replaced with underscores(_), remember that when using them
* You have to set kubectl context before running ansible commands.
* The Connection Plugin does only enable tunneling, adding the reverse tunnel.
    * Clean up manually, disable tunneling from the teknoir cloud console.

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

## List devices
```bash
ansible -i inventory.py --list-hosts all
```

## Run commands
Run for one device:
```bash
ansible-playbook -v -i inventory.py test-playbook.yaml --limit <device_name>
```

### Run for all devices in a namespace:
```bash
ansible-playbook -v -i inventory.py test-playbook.yaml --limit <namespace>
```

### Run for all devices in a namespace:
```bash
ansible-playbook -v -i inventory.py test-playbook.yaml --limit <namespace>
```