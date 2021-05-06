# Teknoir Ansible Inventory and Connection Plugin
The easiest way to start off is to copy content of this repo

> Ofc you need to have Ansible installed!

## Limitations
* As namespaces become groups, we do not support namespaces with dashes(-).
* You have to set kubectl context before running ansible commands.
* The Connection Plugin does not automatically enable tunnels for devices.
    * Enable tunneling from the teknoir cloud console.

## Inventory
Creates an inventory so you are able to connect to any device in any namespace.
To see inventory run:
```bash
python3 inventory.py --list
```

### Naming convention
Hostnames in Ansible has to be unique so the names are created as follows:
```python
f"{namespace}-{device_name}"
```

## Run commands
Run for one device:
```bash
ansible-playbook -v -i inventory.py test-playbook.yaml --limit <namespace>-<device_name>
```

Run for all devices in a namespace:
```bash
ansible-playbook -v -i inventory.py test-playbook.yaml --limit <namespace>
```
