"""The deprecated inventory.py must fail loudly when the catalog has no device login (fleet API platform)."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_class():
    with open(os.path.join(ROOT, 'inventory.py')) as f:
        src = f.read()
    # The script instantiates itself on import; load only the class.
    assert src.rstrip().endswith('TeknoirInventory()')
    src = src.rstrip()[: -len('TeknoirInventory()')]
    ns = {'__name__': 'inventory_under_test'}
    with contextlib.redirect_stderr(io.StringIO()):
        exec(compile(src, 'inventory.py', 'exec'), ns)
    return ns['TeknoirInventory']


def device(name, settings):
    return {
        'metadata': {'name': name, 'namespace': 'ns1', 'labels': {}},
        'spec': {
            'settings': settings,
            'subresources': {'status': {'remote_access': {'active': True, 'port': 2201}}},
        },
    }


class InventoryLoginTest(unittest.TestCase):
    def run_inventory(self, devices):
        cls = load_class()
        home = tempfile.mkdtemp()
        env = {'HOME': home, 'DOMAIN': 'example.test', 'NAMESPACE': 'ns1'}
        out = io.StringIO()
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(sys, 'argv', ['inventory.py', '--list']), \
                mock.patch.object(cls, 'fetch_devices', lambda self, d, n: devices), \
                mock.patch.object(cls, 'load_config', lambda self: {}), \
                contextlib.redirect_stdout(out):
            cls()
        return json.loads(out.getvalue())

    def test_devices_with_login_are_listed(self):
        inv = self.run_inventory([device('d1', {'username': 'dQ==', 'userpassword': 'cA==', 'rsa_private': 'aw=='})])
        self.assertIn('ansible_user', next(iter(inv['_meta']['hostvars'].values())))

    def test_missing_login_stops_with_a_message_not_an_empty_inventory(self):
        with self.assertRaises(SystemExit) as cm:
            self.run_inventory([device('d1', {'username': 'dQ=='}), device('d2', {})])
        msg = str(cm.exception.code)
        self.assertIn('d1', msg)
        self.assertIn('d2', msg)
        self.assertIn('tnctl ansible-inventory', msg)


if __name__ == '__main__':
    unittest.main()
