"""Isolated integration tests; fake official CLI metadata, never real accounts or credentials."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = ROOT / 'work' / 'claude-bridge-tests'
        subprocess.run(['clang', '-fobjc-arc', '-DSTATUS_BRIDGE_TESTING', '-I', str(ROOT/'Native'),
                        '-framework', 'Foundation', *[str(ROOT/p) for p in (
                            'Tests/claude-bridge-harness.m', 'Native/StatusClaudeBridge.m',
                            'Native/StatusAccounts.m', 'Native/StatusQuota.m')], '-o', str(cls.build)], check=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="status ' test ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.fake = self.root/'claude'
        self.fake.write_text('''#!/bin/sh
case "$2" in
status)
  [ -z "$ANTHROPIC_API_KEY$CLAUDE_CODE_OAUTH_TOKEN$ANTHROPIC_AUTH_TOKEN$ANTHROPIC_BASE_URL" ] || exit 5
  cat "$CLAUDE_CONFIG_DIR/auth-fixture.json"
  ;;
logout) exit 0;;
*) exit 1;;
esac
''')
        self.fake.chmod(0o700)
        self.env = dict(os.environ, STATUS_SUPPORT_DIR=str(self.root/'support'), STATUS_TEST_CLAUDE=str(self.fake),
                        ANTHROPIC_API_KEY='must-not-inherit', CLAUDE_CODE_OAUTH_TOKEN='must-not-inherit')
        self.a, self.b = str(uuid.uuid4()), str(uuid.uuid4())
        for account, email in ((self.a, 'a@example.invalid'), (self.b, 'b@example.invalid')):
            self.run_bridge('prepare', account)
            self.auth(account, email)

    def path(self, account):
        return self.root/'support'/'ClaudeCode'/account

    def auth(self, account, email, logged=True):
        (self.path(account)/'auth-fixture.json').write_text(json.dumps(dict(
            loggedIn=logged, authMethod='claude.ai', email=email, orgId='org-'+email, subscriptionType='max',
            accessToken='secret-not-to-save')))

    def run_bridge(self, mode, account, data=None, generation=None, check=True):
        args=[str(self.build), mode, account]
        if generation is not None: args.append(generation)
        return subprocess.run(args, env=self.env, input=json.dumps(data or {}), text=True,
                              capture_output=True, check=check, timeout=15)

    def generation(self, account):
        return json.loads((self.path(account)/'bridge.json').read_text())['generation']

    def collect(self, account, rates=None, generation=None):
        return self.run_bridge('collect', account, dict(rate_limits=rates or {
            'five_hour':dict(used_percentage=23.5,resets_at=time.time()+3600),
            'seven_day':dict(used_percentage=72,resets_at=time.time()+86400)},
            transcript_path='private-transcript', session_id='private-session', secret='sensitive'),
            generation=generation or self.generation(account), check=False)

    def read(self, account):
        return json.loads(self.run_bridge('read', account).stdout)

    def test_two_accounts_and_metadata_only(self):
        self.assertEqual(self.collect(self.a).returncode, 0)
        self.assertEqual(self.read(self.a)['windows'][0]['remainingPercent'], 76.5)
        self.assertEqual(self.read(self.b)['windows'], [])
        self.assertEqual(self.collect(self.b).returncode, 0)
        self.assertEqual(self.read(self.b)['email'], 'b@example.invalid')
        snapshot=(self.path(self.a)/'quota-snapshot.json').read_text()
        for forbidden in ('private-transcript', 'private-session', 'sensitive', 'accessToken', 'secret-not-to-save'):
            self.assertNotIn(forbidden, snapshot)
        self.assertFalse(self.read(self.a)['liveSource'])
        self.assertEqual((self.path(self.a)/'quota-snapshot.json').stat().st_mode & 0o777, 0o600)

    def test_reconnect_invalidates_old_writers_and_measurements(self):
        old=self.generation(self.a)
        self.collect(self.a)
        self.run_bridge('prepare', self.a)
        self.assertEqual(self.read(self.a)['windows'], [])
        self.assertNotEqual(self.collect(self.a, generation=old).returncode, 0)

    def test_wrong_identity_and_wrong_account_are_rejected(self):
        self.collect(self.a)
        self.auth(self.a, 'someone-else@example.invalid')
        self.assertEqual(self.read(self.a)['windows'], [])
        (self.path(self.b)/'quota-snapshot.json').write_bytes((self.path(self.a)/'quota-snapshot.json').read_bytes())
        self.assertEqual(self.read(self.b)['windows'], [])

    def test_expired_and_invalid_windows_do_not_become_zero(self):
        self.collect(self.a, {'five_hour':dict(used_percentage=15,resets_at=time.time()-5),
                             'seven_day':dict(used_percentage='40',resets_at=time.time()+60)})
        self.assertEqual(self.read(self.a)['windows'], [])
        self.collect(self.a, {'five_hour':dict(used_percentage=True,resets_at=time.time()+60),
                             'seven_day':dict(used_percentage=101,resets_at=time.time()+60)})
        self.assertEqual(self.read(self.a)['windows'], [])

    def test_old_snapshot_is_stale_and_keeps_original_timestamp(self):
        self.collect(self.a)
        path=self.path(self.a)/'quota-snapshot.json'
        snapshot=json.loads(path.read_text());snapshot['capturedAt']=time.time()-2000
        path.write_text(json.dumps(snapshot))
        out=self.read(self.a)
        self.assertTrue(out['stale']);self.assertEqual(out['capturedAt'],snapshot['capturedAt'])
        self.assertFalse(out['liveSource'])

    def test_logout_disables_collector_and_clears_snapshot(self):
        self.collect(self.a);generation=self.generation(self.a)
        self.run_bridge('logout',self.a)
        self.assertFalse(self.read(self.a)['connected'])
        self.assertNotEqual(self.collect(self.a,generation=generation).returncode,0)
        self.assertFalse((self.path(self.a)/'quota-snapshot.json').exists())
        self.assertTrue((self.path(self.b)/'bridge.json').exists())

    def test_settings_isolated_and_shell_paths_quoted(self):
        for account in (self.a,self.b):
            config=json.loads((self.path(account)/'settings.json').read_text())
            self.assertIn(account,config['statusLine']['command'])
            self.assertEqual(config['forceLoginMethod'],'claudeai')
            script=self.path(account)/'Connexion Claude.command'
            subprocess.run(['/bin/zsh','-n',str(script)],check=True)
            self.assertIn('auth login',script.read_text())
        self.assertFalse((self.root/'settings.json').exists())

    def test_history_uses_observation_time_without_duplicate_poll_points(self):
        self.collect(self.a)
        captured=int(self.read(self.a)['capturedAt'])
        self.run_bridge('record',self.a);self.run_bridge('record',self.a)
        history=json.loads((self.root/'support'/'quota-history.json').read_text())
        self.assertEqual(len(history),1)
        self.assertEqual(history[0]['t'],captured)
        self.assertIn('claude:'+self.a+':five_hour',history[0]['p'])

    def test_invalid_id_and_broken_settings_rejected(self):
        self.assertNotEqual(self.run_bridge('prepare','../escape',check=False).returncode,0)
        settings=self.path(self.a)/'settings.json';settings.write_text('{broken')
        self.assertNotEqual(self.run_bridge('prepare',self.a,check=False).returncode,0)
        self.assertEqual(settings.read_text(),'{broken')


if __name__ == '__main__':
    unittest.main()
