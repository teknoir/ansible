#!/usr/bin/env python3

import os
import sys
import argparse
import json
import base64
from kubernetes import client, config
from kubernetes.config import ConfigException

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

        print(json.dumps(self.inventory, indent=4, sort_keys=True));

    def decode(self, s):
        return base64.b64decode(s.encode('utf-8')).decode('utf-8')

    def teknoir_inventory(self):
        context = config.list_kube_config_contexts()[1]
        config.load_kube_config()
        custom_api = client.CustomObjectsApi()
        devices = custom_api.list_cluster_custom_object(group="kubeflow.org",
                                                        version="v1",
                                                        plural="devices")

        inventory = {
            '_meta': {
                'hostvars': {}
            }
        }
        ssh_port = 2200
        for device in devices['items']:
            path = f'inv/{context["name"]}/{device["metadata"]["namespace"]}/'
            if device['metadata']['namespace'] not in inventory:
                inventory[device['metadata']['namespace']] = {
                    'hosts': [],
                    'vars': {}
                }
                os.makedirs(path, exist_ok=True)
            private_key_file = f'{path}{device["metadata"]["name"]}.pem'
            if not os.path.isfile(private_key_file):
                with open(private_key_file, 'w') as outfile:
                    outfile.write(self.decode(device['spec']['keys']['data']['rsa_private']))
                os.chmod(private_key_file, 0o400)

            hostname = f'{device["metadata"]["namespace"]}-{device["metadata"]["name"]}'
            inventory[device['metadata']['namespace']]['hosts'].append(hostname)
            inventory['_meta']['hostvars'][hostname] = {
                'ansible_connection': 'teknoir',
                'ansible_port': ssh_port,
                'ansible_host': 'localhost',
                'ansible_user': self.decode(device['spec']['keys']['data']['username']),
                'ansible_sudo_pass': self.decode(device['spec']['keys']['data']['userpassword']),
                'ansible_become': 'yes',
                'ansible_become_user': 'root',
                'ansible_become_pass': self.decode(device['spec']['keys']['data']['userpassword']),
                'ansible_ssh_private_key_file': private_key_file,
                'ansible_python_interpreter': '/usr/bin/python3',
                'ansible_ssh_retries': 20,
                'ansible_kubectl_context': context,
                'ansible_kubectl_namespace': device['metadata']['namespace'],
                'ansible_teknoir_tunnel_port': self.decode(device['spec']['keys']['data']['tunnel']),
                'ansible_teknoir_device': device['metadata']['name']
            }
            ssh_port = ssh_port + 1
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
