from __future__ import (absolute_import, division, print_function)

import base64
import signal
import subprocess
import importlib.util
import os
import atexit
from time import sleep
from ansible.utils.display import Display
from kubernetes import client, config

from ansible.errors import AnsibleConnectionFailure

__metaclass__ = type

DOCUMENTATION = '''
    name: teknoir
    short_description: Connect via ssh client binary to teknoir devices
    description:
        - This connection plugin allows ansible to communicate to the teknoir devices via normal ssh command line.
    author: Anders Åslund
    version_added: historical
    options:
      host:
          description: Hostname/ip to connect to.
          vars:
               - name: inventory_hostname
               - name: ansible_host
               - name: ansible_ssh_host
               - name: delegated_vars['ansible_host']
               - name: delegated_vars['ansible_ssh_host']
      host_key_checking:
          description: Determines if ssh should check host keys
          type: boolean
          ini:
              - section: defaults
                key: 'host_key_checking'
              - section: ssh_connection
                key: 'host_key_checking'
                version_added: '2.5'
          env:
              - name: ANSIBLE_HOST_KEY_CHECKING
              - name: ANSIBLE_SSH_HOST_KEY_CHECKING
                version_added: '2.5'
          vars:
              - name: ansible_host_key_checking
                version_added: '2.5'
              - name: ansible_ssh_host_key_checking
                version_added: '2.5'
      password:
          description: Authentication password for the C(remote_user). Can be supplied as CLI option.
          vars:
              - name: ansible_password
              - name: ansible_ssh_pass
              - name: ansible_ssh_password
      sshpass_prompt:
          description:
              - Password prompt that sshpass should search for. Supported by sshpass 1.06 and up.
              - Defaults to ``Enter PIN for`` when pkcs11_provider is set.
          default: ''
          ini:
              - section: 'ssh_connection'
                key: 'sshpass_prompt'
          env:
              - name: ANSIBLE_SSHPASS_PROMPT
          vars:
              - name: ansible_sshpass_prompt
          version_added: '2.10'
      ssh_args:
          description: Arguments to pass to all ssh cli tools
          default: '-C -o ControlMaster=auto -o ControlPersist=60s'
          ini:
              - section: 'ssh_connection'
                key: 'ssh_args'
          env:
              - name: ANSIBLE_SSH_ARGS
          vars:
              - name: ansible_ssh_args
                version_added: '2.7'
          cli:
              - name: ssh_args
      ssh_common_args:
          description: Common extra args for all ssh CLI tools
          ini:
              - section: 'ssh_connection'
                key: 'ssh_common_args'
                version_added: '2.7'
          env:
              - name: ANSIBLE_SSH_COMMON_ARGS
                version_added: '2.7'
          vars:
              - name: ansible_ssh_common_args
          cli:
              - name: ssh_common_args
      ssh_executable:
          default: ssh
          description:
            - This defines the location of the ssh binary. It defaults to ``ssh`` which will use the first ssh binary available in $PATH.
            - This option is usually not required, it might be useful when access to system ssh is restricted,
              or when using ssh wrappers to connect to remote hosts.
          env: [{name: ANSIBLE_SSH_EXECUTABLE}]
          ini:
          - {key: ssh_executable, section: ssh_connection}
          #const: ANSIBLE_SSH_EXECUTABLE
          version_added: "2.2"
          vars:
              - name: ansible_ssh_executable
                version_added: '2.7'
      sftp_executable:
          default: sftp
          description:
            - This defines the location of the sftp binary. It defaults to ``sftp`` which will use the first binary available in $PATH.
          env: [{name: ANSIBLE_SFTP_EXECUTABLE}]
          ini:
          - {key: sftp_executable, section: ssh_connection}
          version_added: "2.6"
          vars:
              - name: ansible_sftp_executable
                version_added: '2.7'
      scp_executable:
          default: scp
          description:
            - This defines the location of the scp binary. It defaults to `scp` which will use the first binary available in $PATH.
          env: [{name: ANSIBLE_SCP_EXECUTABLE}]
          ini:
          - {key: scp_executable, section: ssh_connection}
          version_added: "2.6"
          vars:
              - name: ansible_scp_executable
                version_added: '2.7'
      scp_extra_args:
          description: Extra exclusive to the ``scp`` CLI
          vars:
              - name: ansible_scp_extra_args
          env:
            - name: ANSIBLE_SCP_EXTRA_ARGS
              version_added: '2.7'
          ini:
            - key: scp_extra_args
              section: ssh_connection
              version_added: '2.7'
          cli:
            - name: scp_extra_args
      sftp_extra_args:
          description: Extra exclusive to the ``sftp`` CLI
          vars:
              - name: ansible_sftp_extra_args
          env:
            - name: ANSIBLE_SFTP_EXTRA_ARGS
              version_added: '2.7'
          ini:
            - key: sftp_extra_args
              section: ssh_connection
              version_added: '2.7'
          cli:
            - name: sftp_extra_args
      ssh_extra_args:
          description: Extra exclusive to the 'ssh' CLI
          vars:
              - name: ansible_ssh_extra_args
          env:
            - name: ANSIBLE_SSH_EXTRA_ARGS
              version_added: '2.7'
          ini:
            - key: ssh_extra_args
              section: ssh_connection
              version_added: '2.7'
          cli:
            - name: ssh_extra_args
      reconnection_retries:
          description: Number of attempts to connect.
          default: 3
          type: integer
          env:
            - name: ANSIBLE_SSH_RETRIES
          ini:
            - section: connection
              key: retries
            - section: ssh_connection
              key: retries
          vars:
            - name: ansible_ssh_retries
              version_added: '2.7'
      port:
          description: Remote port to connect to.
          type: int
          ini:
            - section: defaults
              key: remote_port
          env:
            - name: ANSIBLE_REMOTE_PORT
          vars:
            - name: ansible_port
            - name: ansible_ssh_port
      remote_user:
          description:
              - User name with which to login to the remote server, normally set by the remote_user keyword.
              - If no user is supplied, Ansible will let the ssh client binary choose the user as it normally
          ini:
            - section: defaults
              key: remote_user
          env:
            - name: ANSIBLE_REMOTE_USER
          vars:
            - name: ansible_user
            - name: ansible_ssh_user
          cli:
            - name: user
      pipelining:
          env:
            - name: ANSIBLE_PIPELINING
            - name: ANSIBLE_SSH_PIPELINING
          ini:
            - section: connection
              key: pipelining
            - section: ssh_connection
              key: pipelining
          vars:
            - name: ansible_pipelining
            - name: ansible_ssh_pipelining
      private_key_file:
          description:
              - Path to private key file to use for authentication
          ini:
            - section: defaults
              key: private_key_file
          env:
            - name: ANSIBLE_PRIVATE_KEY_FILE
          vars:
            - name: ansible_private_key_file
            - name: ansible_ssh_private_key_file
          cli:
            - name: private_key_file
      control_path:
        description:
          - This is the location to save ssh's ControlPath sockets, it uses ssh's variable substitution.
          - Since 2.3, if null (default), ansible will generate a unique hash. Use `%(directory)s` to indicate where to use the control dir path setting.
          - Before 2.3 it defaulted to `control_path=%(directory)s/ansible-ssh-%%h-%%p-%%r`.
          - Be aware that this setting is ignored if `-o ControlPath` is set in ssh args.
        env:
          - name: ANSIBLE_SSH_CONTROL_PATH
        ini:
          - key: control_path
            section: ssh_connection
        vars:
          - name: ansible_control_path
            version_added: '2.7'
      control_path_dir:
        default: ~/.ansible/cp
        description:
          - This sets the directory to use for ssh control path if the control path setting is null.
          - Also, provides the `%(directory)s` variable for the control path setting.
        env:
          - name: ANSIBLE_SSH_CONTROL_PATH_DIR
        ini:
          - section: ssh_connection
            key: control_path_dir
        vars:
          - name: ansible_control_path_dir
            version_added: '2.7'
      sftp_batch_mode:
        default: 'yes'
        description: 'TODO: write it'
        env: [{name: ANSIBLE_SFTP_BATCH_MODE}]
        ini:
        - {key: sftp_batch_mode, section: ssh_connection}
        type: bool
        vars:
          - name: ansible_sftp_batch_mode
            version_added: '2.7'
      ssh_transfer_method:
        default: smart
        description:
            - "Preferred method to use when transferring files over ssh"
            - Setting to 'smart' (default) will try them in order, until one succeeds or they all fail
            - Using 'piped' creates an ssh pipe with ``dd`` on either side to copy the data
        choices: ['sftp', 'scp', 'piped', 'smart']
        env: [{name: ANSIBLE_SSH_TRANSFER_METHOD}]
        ini:
            - {key: transfer_method, section: ssh_connection}
      scp_if_ssh:
        default: smart
        description:
          - "Preferred method to use when transfering files over ssh"
          - When set to smart, Ansible will try them until one succeeds or they all fail
          - If set to True, it will force 'scp', if False it will use 'sftp'
        env: [{name: ANSIBLE_SCP_IF_SSH}]
        ini:
        - {key: scp_if_ssh, section: ssh_connection}
        vars:
          - name: ansible_scp_if_ssh
            version_added: '2.7'
      use_tty:
        version_added: '2.5'
        default: 'yes'
        description: add -tt to ssh commands to force tty allocation
        env: [{name: ANSIBLE_SSH_USETTY}]
        ini:
        - {key: usetty, section: ssh_connection}
        type: bool
        vars:
          - name: ansible_ssh_use_tty
            version_added: '2.7'
      timeout:
        default: 10
        description:
            - This is the default ammount of time we will wait while establishing an ssh connection
            - It also controls how long we can wait to access reading the connection once established (select on the socket)
        env:
            - name: ANSIBLE_TIMEOUT
            - name: ANSIBLE_SSH_TIMEOUT
              version_added: '2.11'
        ini:
            - key: timeout
              section: defaults
            - key: timeout
              section: ssh_connection
              version_added: '2.11'
        vars:
          - name: ansible_ssh_timeout
            version_added: '2.11'
        cli:
          - name: timeout
        type: integer
      pkcs11_provider:
        version_added: '2.12'
        default: ""
        description:
          - "PKCS11 SmartCard provider such as opensc, example: /usr/local/lib/opensc-pkcs11.so"
          - Requires sshpass version 1.06+, sshpass must support the -P option
        env: [{name: ANSIBLE_PKCS11_PROVIDER}]
        ini:
          - {key: pkcs11_provider, section: ssh_connection}
        vars:
          - name: ansible_ssh_pkcs11_provider
      kubectl_namespace:
        description:
          - The namespace with teknoir devices
        vars:
          - name: ansible_kubectl_namespace
          - name: delegated_vars['ansible_kubectl_namespace']
        cli:
          - name: namespace
      teknoir_tunnel_port:
        description:
          - The port on the deadend host that has the reverse tunnel created by the teknoir device
        vars:
          - name: ansible_teknoir_tunnel_port
          - name: delegated_vars['ansible_teknoir_tunnel_port']
      teknoir_tunnel_open:
        description:
          - Indicates if the device has been instructed to create a reverse tunnel or not
        type: bool
        vars:
          - name: ansible_teknoir_tunnel_open
          - name: delegated_vars['ansible_teknoir_tunnel_open']
      teknoir_device:
        description:
          - The name of the device
        vars:
          - name: ansible_teknoir_device
          - name: delegated_vars['ansible_teknoir_device']
'''

try:
    from __main__ import display
except ImportError:
    from ansible.utils.display import Display

display = Display()


# HACK: Ansible core does classname-based validation checks, to ensure connection plugins inherit directly from a class
# named "ConnectionBase". This intermediate class works around this limitation.
# class ConnectionBase(SSHConnection):
#     pass

def load_module(name, path):
    module_spec = importlib.util.spec_from_file_location(
        name, path
    )
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module

# NOTICE(cloudnull): The connection plugin imported using the full path to the
#                    file because the ssh connection plugin is not importable.
import ansible.plugins.connection as conn
SSH = load_module(
    'ssh',
    os.path.join(os.path.dirname(conn.__file__), 'ssh.py')
)

# class Connection(ConnectionBase):
class Connection(SSH.Connection):
    ''' ssh based connections '''

    transport = 'teknoir'
    portforward_subprocess = None

    def __init__(self, *args, **kwargs):
        super(Connection, self).__init__(*args, **kwargs)
        self.inventory = 'teknoir'

    def __exit__(self, exc_type, exc_value, traceback):
        display.vv(f"(exit)", host=self.inventory)

    def _start_reverse_tunnel(self, custom_api, namespace, name, port):
        device_patch = {
            "spec": {
                "keys": {
                    "data": {
                        "tunnel": base64.b64encode(port.encode('utf-8')).decode('utf-8')
                    }
                }
            }
        }
        custom_api.patch_namespaced_custom_object("kubeflow.org",
                                                  "v1beta1",
                                                  namespace,
                                                  "devices",
                                                  name,
                                                  device_patch)

    def _stop_reverse_tunnel(self, custom_api, namespace, name):
        display.v(f"Stop reverse tunnel", host=self.inventory)
        device_patch = {
            "spec": {
                "keys": {
                    "data": {
                        "tunnel": base64.b64encode('NA'.encode('utf-8')).decode('utf-8')
                    }
                }
            }
        }
        custom_api.patch_namespaced_custom_object("kubeflow.org",
                                                  "v1beta1",
                                                  namespace,
                                                  "devices",
                                                  name,
                                                  device_patch)

    def _connect(self):
        super(Connection, self)._connect()
        device_name = self.get_option('teknoir_device')
        namespace = self.get_option('kubectl_namespace')
        tunnel_open = self.get_option('teknoir_tunnel_open')
        tunnel_port = self.get_option('teknoir_tunnel_port')
        ansible_group = namespace.replace('-', '_').replace('.', '_')
        self.inventory = f'{ansible_group}-{device_name}'

        config.load_kube_config()
        custom_api = client.CustomObjectsApi()

        if not tunnel_open:
            display.v(f"Start reverse tunnel, PORT({tunnel_port})", host=self.inventory)
            self._start_reverse_tunnel(custom_api, namespace, device_name, tunnel_port)
            self.set_option('teknoir_tunnel_open', True)

        return self

    def close(self):
        super(Connection, self).close()

    @staticmethod
    def start_portforward():
        display.vv(f"Checking start port-forward to deadendproxy", host="localhost")
        if Connection.portforward_subprocess is None:
            display.v(f"Start port-forward to deadendproxy", host="localhost")
            cmd = "kubectl --namespace=deadend-system port-forward svc/deadendproxy 8118:8118"
            display.vvv(cmd, host="localhost")
            Connection.portforward_subprocess = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                                      preexec_fn=os.setsid)

            display.v(f"Port-forward not yet warmed up", host="localhost")
            sleep(4)
            display.v(f"Port-forward warmed up", host="localhost")

            if Connection.portforward_subprocess.poll() is not None:
                raise AnsibleConnectionFailure(
                    f"Port-forward did not start correctly...maybe you need to kill a process blocking the 8118 port!?")

            nextline = Connection.portforward_subprocess.stdout.readline()
            if b'Forwarding from' in nextline:
                display.vv(f"Port-forwarding is up and running, Nextline: ({nextline.decode()}), PID({Connection.portforward_subprocess.pid})", host="localhost")
            else:
                raise AnsibleConnectionFailure(
                    f"Port-forward almost ready..., Nextline: ({nextline.decode()}) ...maybe you need to kill a process blocking the 8118 port!?")

    @staticmethod
    def stop_portforward():
        if Connection.portforward_subprocess is not None:
            display.v(f"Killing port-forwarding (close), PID({Connection.portforward_subprocess.pid})", host="localhost")
            os.killpg(os.getpgid(Connection.portforward_subprocess.pid), signal.SIGTERM)
            Connection.portforward_subprocess = None


Connection.start_portforward()
atexit.register(Connection.stop_portforward)
