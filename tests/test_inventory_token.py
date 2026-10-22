"""inventory.py must never send Backstage a token that has the WireGuard hub audience (teknoir-ztna)."""
import base64
import contextlib
import datetime
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FULL = 'openid profile email offline_access teknoir-ztna'
MAIN = 'openid profile email offline_access'


def load_ns():
    with open(os.path.join(ROOT, 'inventory.py')) as f:
        src = f.read().rstrip()
    assert src.endswith('TeknoirInventory()')
    src = src[: -len('TeknoirInventory()')]
    ns = {'__name__': 'inventory_under_test'}
    with contextlib.redirect_stderr(io.StringIO()):
        exec(compile(src, 'inventory.py', 'exec'), ns)
    return ns


def jwt(claims):
    enc = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()
    return enc(b'{"alg":"none"}') + '.' + enc(json.dumps(claims).encode()) + '.' + enc(b'sig')


class Resp:
    def __init__(self, status, body):
        self.status_code, self._body, self.text = status, body, json.dumps(body)

    def json(self):
        return self._body


class IdP:
    """A token endpoint that puts the hub audience into the token unless the scope was downscoped."""

    def __init__(self, rt_scope=FULL):
        self.rt_scope, self.forms = rt_scope, []

    def post(self, url, data=None):
        self.forms.append(dict(data))
        scope = data.get('scope', self.rt_scope)  # no scope parameter: everything granted
        aud = ['teknoir-cli'] + (['teknoir-ztna'] if 'teknoir-ztna' in scope.split() else [])
        return Resp(200, {'access_token': jwt({'aud': aud}), 'refresh_token': jwt({'scope': self.rt_scope, 'n': len(self.forms)}), 'expires_in': 300})


def inventory(auth):
    """An instance without running __init__, with a config in a temp HOME."""
    ns = load_ns()
    cls = ns['TeknoirInventory']
    inv = cls.__new__(cls)
    inv.config = {'domain': 'example.test', 'auths': {'example_test': auth}}
    inv.save_config = lambda: None
    return inv, ns


def stored(access_token, rt_scope=FULL, minutes=10):
    exp = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=minutes)
    return {'access_token': access_token, 'refresh_token': jwt({'scope': rt_scope}), 'expiry': exp.isoformat(), 'realm': 'master', 'client_id': 'teknoir-cli'}


class InventoryTokenTest(unittest.TestCase):
    def get(self, auth, idp):
        inv, ns = inventory(auth)
        with mock.patch.object(ns['requests'], 'post', idp.post):
            return inv.get_valid_token('example.test'), inv

    def test_a_stored_hub_token_is_replaced_not_sent(self):
        hub = jwt({'aud': ['teknoir-cli', 'teknoir-ztna']})
        idp = IdP()
        token, inv = self.get(stored(hub), idp)
        self.assertNotEqual(token, hub)
        self.assertEqual(len(idp.forms), 1)
        self.assertEqual(idp.forms[0]['scope'], MAIN)
        self.assertFalse(load_ns()['has_hub_audience'](token))
        self.assertEqual(inv.config['auths']['example_test']['access_token'], token)

    def test_an_expired_token_is_refreshed_downscoped(self):
        idp = IdP()
        token, _ = self.get(stored(jwt({'aud': ['teknoir-cli']}), minutes=-5), idp)
        self.assertEqual(idp.forms[0]['scope'], MAIN)
        self.assertFalse(load_ns()['has_hub_audience'](token))

    def test_a_valid_main_token_is_used_without_a_request(self):
        main = jwt({'aud': ['teknoir-cli']})
        idp = IdP()
        token, _ = self.get(stored(main), idp)
        self.assertEqual(token, main)
        self.assertEqual(idp.forms, [])

    def test_a_login_without_the_hub_scope_refreshes_without_a_scope(self):
        idp = IdP(rt_scope=MAIN)
        self.get(stored(jwt({'aud': ['teknoir-cli']}), rt_scope=MAIN, minutes=-5), idp)
        self.assertNotIn('scope', idp.forms[0])

    def test_a_realm_that_still_returns_the_hub_audience_is_refused(self):
        idp = IdP()
        idp.post = lambda url, data=None: Resp(200, {'access_token': jwt({'aud': ['teknoir-ztna']}), 'expires_in': 300})
        with self.assertRaises(Exception) as cm:
            self.get(stored(jwt({'aud': ['teknoir-cli']}), minutes=-5), idp)
        self.assertIn('teknoir-ztna', str(cm.exception))

    def test_helpers(self):
        ns = load_ns()
        self.assertEqual(ns['main_scope'](jwt({'scope': FULL})), MAIN)
        self.assertEqual(ns['main_scope'](jwt({'scope': 'teknoir-ztna'})), MAIN)
        self.assertIsNone(ns['main_scope'](jwt({'scope': MAIN})))
        self.assertIsNone(ns['main_scope']('opaque'))
        self.assertTrue(ns['has_hub_audience'](jwt({'aud': 'teknoir-ztna'})))
        self.assertFalse(ns['has_hub_audience']('opaque'))
        self.assertFalse(ns['has_hub_audience'](None))


if __name__ == '__main__':
    unittest.main()
