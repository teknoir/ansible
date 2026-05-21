#!/usr/bin/env python3

import os
import argparse
import json
import base64
from kubernetes import client, config

"""
Teknoir custom dynamic inventory script for Ansible, in Python.
"""


class TeknoirInventory(object):

    def __init__(self):
        self.inventory = {}
        self.read_cli_args()

        # Called with `--list`.
        if self.args.list:
            self.inventory = self.teknoir_inventory()
        # Called with `--host [hostname]`.
        elif self.args.host:
            # Not implemented, since we return _meta info `--list`.
            self.inventory = self.teknoir_inventory()
        # If no groups or vars are present, return empty inventory.
        else:
            self.inventory = self.empty_inventory()

        print(json.dumps(self.inventory, indent=4, sort_keys=True))

    def decode(self, s):
        return base64.b64decode(s.encode('utf-8')).decode('utf-8')

    def teknoir_inventory(self):
        try:
            config.load_kube_config()
        except config.ConfigException:
            try:
                config.load_incluster_config()
            except config.ConfigException:
                raise Exception("Could not configure kubernetes python client")

        contexts, current_context = config.list_kube_config_contexts()
        if not contexts or len(contexts) < 2:
            raise Exception("No valid kube config contexts found")

        def get_domain(value):
            return {
                'teknoir-poc-eks': 'teknoir.online',
                'gke_teknoir_us-central1-c_teknoir-cluster': 'teknoir.cloud',
                'gke_teknoir-poc_us-central1-c_teknoir-dev-cluster': 'teknoir.dev',
            }.get(value, os.environ.get('DOMAIN', 'teknoir.online'))
        domain = get_domain(current_context['context']['cluster'])
        namespace = current_context['context'].get('namespace', os.environ.get('NAMESPACE', 'default'))

        custom_api = client.CustomObjectsApi()
        devices = custom_api.list_namespaced_custom_object(group="teknoir.org",
                                                           version="v1",
                                                           namespace=namespace,
                                                           plural="devices")

        inventory = {
            '_meta': {
                'hostvars': {}
            }
        }

        for device in devices['items']:
            ansible_group = device["metadata"]["namespace"].replace('-', '_').replace('.', '_')

            home_dir = os.path.expanduser("~")
            inventory_path = os.path.join(home_dir, ".ansible", "tmp", "inv", ansible_group)
            hostname = f'{device["metadata"]["name"]}'

            if ansible_group not in inventory:
                inventory[ansible_group] = {
                    'hosts': [],
                    'vars': {}
                }
                os.makedirs(inventory_path, exist_ok=True)
            inventory[ansible_group]['hosts'].append(hostname)

            for label, value in device["metadata"]["labels"].items():
                label = label.replace('-', '_').replace('.', '_')
                value = value.replace('-', '_').replace('.', '_')
                additional_group = f'{label}_{value}'
                if additional_group not in inventory:
                    inventory[additional_group] = {
                        'hosts': [],
                        'vars': {}
                    }
                inventory[additional_group]['hosts'].append(hostname)

            private_key_file = os.path.join(inventory_path, f'{device["metadata"]["name"]}.pem')
            if not os.path.isfile(private_key_file):
                with open(private_key_file, 'w') as outfile:
                    outfile.write(self.decode(device['spec']['keys']['data']['rsa_private']))
                os.chmod(private_key_file, 0o400)

            # print(json.dumps(device, indent=4, sort_keys=True))

            if not ('remote_access' in device['subresources']['status'] and
                    'active' in device['subresources']['status']['remote_access'] and
                    'port' in device['subresources']['status']['remote_access']):
                continue

            tunnel_opened = device['subresources']['status']['remote_access']['active']
            tunnel_port = device['subresources']['status']['remote_access']['port']

            if not tunnel_opened:
                continue

            if ('data' not in device['spec']['keys'] or
                    'username' not in device['spec']['keys']['data'] or
                    'userpassword' not in device['spec']['keys']['data']):
                continue

            deadendhost = f'deadend-{namespace}.{domain}'
            deadendport = 2222
            username = self.decode(device['spec']['keys']['data']['username'])
            userpassword = self.decode(device['spec']['keys']['data']['userpassword'])
            # ppcmd = f"openssl s_client -quiet -connect {deadendhost}:{deadendport} -servername {deadendhost}"
            ppcmd = f"ncat --ssl {deadendhost} {deadendport}"
            pcmd = f"ssh -o ProxyCommand='{ppcmd}' -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -i {private_key_file} -N -W %h:%p teknoir@{deadendhost} -p {deadendport}"
            inventory['_meta']['hostvars'][hostname] = {
                'ansible_namespace': device["metadata"]["namespace"],
                'ansible_port': tunnel_port,
                'ansible_host': '127.0.0.1',
                'ansible_user': username,
                'ansible_sudo_pass': userpassword,
                'ansible_become_user': 'root',
                'ansible_become_pass': userpassword,
                'ansible_become_flags': '-E',
                'ansible_ssh_private_key_file': private_key_file,
                'ansible_ssh_args': f'-o ForwardAgent=yes -o ProxyCommand="{pcmd}"',
                'ansible_python_interpreter': '/usr/bin/python3',
                'ansible_ssh_retries': 20,
                'ansible_kubectl_namespace': device["metadata"]["namespace"],
                'ansible_teknoir_tunnel_port': tunnel_port,
                'ansible_teknoir_tunnel_open': tunnel_opened,
                'ansible_teknoir_device': device['metadata']['name'],
                'ansible_teknoir_domain': domain,
            }
        return inventory

    # Empty inventory for testing.
    def empty_inventory(self):
        return {'_meta': {'hostvars': {}}}

    # Read the command line args passed to the script.
    def read_cli_args(self):
        parser = argparse.ArgumentParser()
        parser.add_argument('--list', action='store_true')
        parser.add_argument('--host', action='store')
        self.args = parser.parse_args()


# Get the inventory.
TeknoirInventory()
