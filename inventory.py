#!/usr/bin/env python3

import os
import argparse
import json
import base64
import yaml
import requests
import datetime

"""
Teknoir custom dynamic inventory script for Ansible, in Python.
"""

# DEPRECATED: use tnctl as the inventory (`tnctl ansible`, `tnctl ansible-playbook`,
# `tnctl ansible-inventory`). See https://github.com/teknoir/cli/blob/main/docs/commands/ansible.md
import sys  # noqa: E402
print("[DEPRECATED] The Teknoir Ansible inventory plugin is replaced by tnctl: "
      "tnctl ansible / tnctl ansible-playbook (https://github.com/teknoir/cli/blob/main/docs/commands/ansible.md)",
      file=sys.stderr)

# The audience and scope of the WireGuard hub. A token that has the audience opens hub sessions,
# so this script must never send one to Backstage (it only needs the main token); see tnctl login.
ZTNA = 'teknoir-ztna'
MAIN_SCOPE = 'openid profile email offline_access'


def jwt_claims(token):
    """The (unverified) claims of a JWT, or {} for anything that is not one."""
    try:
        payload = str(token).split('.')[1]
        payload += '=' * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload.encode('utf-8')))
        return claims if isinstance(claims, dict) else {}
    except Exception:
        return {}


def has_hub_audience(token):
    aud = jwt_claims(token).get('aud') or []
    if isinstance(aud, str):
        aud = [aud]
    return ZTNA in aud


def main_scope(refresh_token):
    """The scopes to redeem a refresh token with: what it was granted minus the hub scope.

    A refresh without a scope parameter returns every granted scope, the hub audience included.
    Returns None when the token has no scope claim or was not granted the hub scope: then the
    plain refresh (no scope parameter) cannot add the audience, and sending one could ask for more
    than was granted.
    """
    granted = str(jwt_claims(refresh_token).get('scope') or '').split()
    if ZTNA not in granted:
        return None
    return ' '.join(sc for sc in granted if sc != ZTNA) or MAIN_SCOPE


class TeknoirInventory(object):

    def __init__(self):
        self.inventory = {}
        self.read_cli_args()

        self.config = self.load_config()
        self.domain = os.environ.get('DOMAIN', self.config.get('domain', 'teknoir.online'))
        self.namespace = os.environ.get('NAMESPACE', self.get_namespace_from_config())

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
        if not s:
            return ""
        return base64.b64decode(s.encode('utf-8')).decode('utf-8')

    def load_config(self):
        config_path = os.path.expanduser("~/.tnctl.yaml")
        if not os.path.exists(config_path):
            return {"domain": "teknoir.online", "auths": {}}
        with open(config_path, 'r') as f:
            try:
                return yaml.safe_load(f) or {}
            except yaml.YAMLError:
                return {}

    def save_config(self):
        config_path = os.path.expanduser("~/.tnctl.yaml")
        try:
            # To be safe, we only update domain and auths, similar to tnctl
            # but we might not have all fields if they were in the file but not in our model.
            # Since we used safe_load, we have everything.
            
            # Remove top-level namespace and device as tnctl does
            self.config.pop('namespace', None)
            self.config.pop('device', None)
            
            with open(config_path, 'w') as f:
                yaml.safe_dump(self.config, f)
        except Exception:
            # If we can't save, just continue. It's an inventory script.
            pass

    def get_namespace_from_config(self):
        sanitized_domain = self.domain.replace('.', '_')
        auth = self.config.get('auths', {}).get(sanitized_domain, {})
        return auth.get('namespace') or self.config.get('namespace') or 'default'

    def get_valid_token(self, domain):
        sanitized_domain = domain.replace('.', '_')
        auths = self.config.get('auths', {})
        if sanitized_domain not in auths:
            raise Exception(f"No authentication found for domain: {domain}")

        auth = auths[sanitized_domain]
        access_token = auth.get('access_token')
        refresh_token = auth.get('refresh_token')
        expiry_str = auth.get('expiry')

        should_refresh = False
        if not access_token:
            should_refresh = True
        elif has_hub_audience(access_token):
            # What `tnctl login` stored before it learned to downscope: never send it on.
            should_refresh = True
        elif expiry_str:
            try:
                expiry = datetime.datetime.fromisoformat(expiry_str)
                # Ensure expiry is offset-aware
                if expiry.tzinfo is None:
                    expiry = expiry.replace(tzinfo=datetime.timezone.utc)
                
                now = datetime.datetime.now(datetime.timezone.utc)
                if expiry <= now + datetime.timedelta(minutes=1):
                    should_refresh = True
            except Exception:
                should_refresh = True
        else:
            should_refresh = True

        if not should_refresh:
            return access_token

        # Refresh token
        realm = auth.get('realm', 'master')
        client_id = auth.get('client_id', 'teknoir-cli')
        client_secret = auth.get('client_secret')

        auth_domain = f"auth.{domain}"
        token_url = f"https://{auth_domain}/auth/realms/{realm}/protocol/openid-connect/token"

        data = {
            'grant_type': 'refresh_token',
            'refresh_token': refresh_token,
            'client_id': client_id,
        }
        if client_secret:
            data['client_secret'] = client_secret
        scope = main_scope(refresh_token)
        if scope:
            data['scope'] = scope

        response = requests.post(token_url, data=data)
        if response.status_code != 200:
            raise Exception(f"Failed to refresh token for {domain}: {response.text}")

        new_token_data = response.json()
        if has_hub_audience(new_token_data.get('access_token')):
            # Backstage must not get a token the WireGuard hub accepts.
            raise Exception(f"Refreshed token for {domain} has the {ZTNA} audience; not using it. "
                            "Run `tnctl login` again, or use `tnctl ansible-inventory`.")
        auth['access_token'] = new_token_data['access_token']
        if 'refresh_token' in new_token_data:
            auth['refresh_token'] = new_token_data['refresh_token']

        if 'expires_in' in new_token_data:
            expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=new_token_data['expires_in'])
            auth['expiry'] = expiry.isoformat()

        self.save_config()
        return auth['access_token']

    def fetch_devices(self, domain, namespace):
        token = self.get_valid_token(domain)
        url = f"https://{domain}/api/catalog/entities"
        params = {
            'filter': f'kind=resource,spec.type=device,metadata.namespace={namespace}',
            'order': 'asc:metadata.name'
        }
        headers = {
            'Authorization': f'Bearer {token}',
            'Accept': 'application/json'
        }
        response = requests.get(url, params=params, headers=headers)
        if response.status_code != 200:
            raise Exception(f"Failed to fetch devices: {response.text}")
        return response.json()

    def teknoir_inventory(self):
        devices = self.fetch_devices(self.domain, self.namespace)

        inventory = {
            '_meta': {
                'hostvars': {}
            }
        }

        missing_login = []
        for device in devices:
            metadata = device.get('metadata', {})
            spec = device.get('spec', {})
            
            name = metadata.get('name')
            namespace = metadata.get('namespace', self.namespace)
            labels = metadata.get('labels', {})

            ansible_group = namespace.replace('-', '_').replace('.', '_')

            inventory_path = os.path.join("/tmp", ".ansible", "inv", ansible_group)
            hostname = name

            if ansible_group not in inventory:
                inventory[ansible_group] = {
                    'hosts': [],
                    'vars': {}
                }
                os.makedirs(inventory_path, exist_ok=True)
            inventory[ansible_group]['hosts'].append(hostname)

            for label, value in labels.items():
                label = label.replace('-', '_').replace('.', '_')
                value = value.replace('-', '_').replace('.', '_')
                additional_group = f'{label}_{value}'
                if additional_group not in inventory:
                    inventory[additional_group] = {
                        'hosts': [],
                        'vars': {}
                    }
                inventory[additional_group]['hosts'].append(hostname)

            settings = spec.get('settings', {})
            private_key_b64 = settings.get('rsa_private')
            username_b64 = settings.get('username')
            userpassword_b64 = settings.get('userpassword')

            private_key_file = os.path.join(inventory_path, f'{name}.pem')
            if private_key_b64:
                if not os.path.isfile(private_key_file):
                    with open(private_key_file, 'w') as outfile:
                        outfile.write(self.decode(private_key_b64))
                    os.chmod(private_key_file, 0o400)

            subresources = spec.get('subresources', {})
            status = subresources.get('status', {})
            remote_access = status.get('remote_access', {})

            tunnel_opened = remote_access.get('active', False)
            tunnel_port = remote_access.get('port')

            if not tunnel_opened or not tunnel_port:
                continue

            if not (username_b64 and userpassword_b64):
                # A platform that keeps device logins out of the catalog (fleet API) leaves these out.
                # Skipping the device silently would hand Ansible an empty inventory.
                missing_login.append(name)
                continue

            deadendhost = f'deadend-{namespace}.{self.domain}'
            deadendport = 2222
            username = self.decode(username_b64)
            userpassword = self.decode(userpassword_b64)
            # ppcmd = f"openssl s_client -quiet -connect {deadendhost}:{deadendport} -servername {deadendhost}"
            ppcmd = f"ncat --ssl {deadendhost} {deadendport}"
            pcmd = f"ssh -o ProxyCommand='{ppcmd}' -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -i {private_key_file} -N -W %h:%p teknoir@{deadendhost} -p {deadendport}"
            inventory['_meta']['hostvars'][hostname] = {
                'ansible_namespace': namespace,
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
                'ansible_kubectl_namespace': namespace,
                'ansible_teknoir_namespace': namespace,
                'ansible_teknoir_tunnel_port': tunnel_port,
                'ansible_teknoir_tunnel_open': tunnel_opened,
                'ansible_teknoir_device': name,
                'ansible_teknoir_domain': self.domain,
            }
        if missing_login:
            shown = ', '.join(missing_login[:10]) + (', ...' if len(missing_login) > 10 else '')
            sys.exit(
                f"ERROR: {len(missing_login)} device(s) with an open tunnel have no login in the catalog ({shown}). "
                "A platform with the fleet API no longer puts device logins (private key, password) into the "
                "catalog, which this deprecated inventory reads. Use tnctl as the inventory: "
                "`tnctl ansible-inventory --list` or `tnctl ansible-playbook` "
                "(https://github.com/teknoir/cli/blob/main/docs/commands/ansible.md)."
            )
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
