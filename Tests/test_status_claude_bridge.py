import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "status-claude-bridge.py"


class ClaudeBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.settings = root / ".claude" / "settings.json"
        self.state = root / "state"
        self.env = os.environ.copy()
        self.env["STATUS_CLAUDE_SETTINGS_PATH"] = str(self.settings)
        self.env["STATUS_CLAUDE_STATE_DIR"] = str(self.state)

    def tearDown(self):
        self.temp.cleanup()

    def run_bridge(self, *args, input_data=None, expected=0):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            input=input_data,
            text=True,
            capture_output=True,
            env=self.env,
            check=False,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def write_settings(self, value):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(value), encoding="utf-8")

    def collect_command(self):
        settings = json.loads(self.settings.read_text(encoding="utf-8"))
        return settings["statusLine"]["command"]

    def test_install_collect_status_uninstall_without_existing_statusline(self):
        install = json.loads(self.run_bridge("install").stdout)
        self.assertTrue(install["installed"])
        self.assertTrue(install["configured"])

        settings_mode = stat.S_IMODE(self.settings.stat().st_mode)
        state_mode = stat.S_IMODE(self.state.stat().st_mode)
        self.assertEqual(settings_mode, 0o600)
        self.assertEqual(state_mode, 0o700)

        secret = "oauth-secret-must-not-be-written"
        payload = {
            "version": "2.1.80",
            "session_id": "session-test",
            "oauth_token": secret,
            "cwd": "/private/project",
            "transcript_path": "/secret/transcript.jsonl",
            "rate_limits": {
                "five_hour": {"used_percentage": 23.5, "resets_at": 1_900_000_000},
                "seven_day": {"used_percentage": 41.2, "resets_at": 1_900_100_000},
            },
        }
        result = subprocess.run(
            self.collect_command(),
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            shell=True,
            env=self.env,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

        snapshot_path = self.state / "quota-snapshot.json"
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
        self.assertEqual(snapshot["rate_limits"]["five_hour"]["remaining_percentage"], 76.5)
        self.assertEqual(snapshot["rate_limits"]["seven_day"]["used_percentage"], 41.2)
        self.assertNotIn(secret, snapshot_path.read_text(encoding="utf-8"))
        self.assertNotIn("transcript", snapshot_path.read_text(encoding="utf-8"))
        self.assertEqual(stat.S_IMODE(snapshot_path.stat().st_mode), 0o600)

        status = json.loads(self.run_bridge("status").stdout)
        self.assertTrue(status["snapshot_present"])
        self.assertEqual(status["snapshot"], snapshot)

        uninstall = json.loads(self.run_bridge("uninstall").stdout)
        self.assertFalse(uninstall["installed"])
        self.assertFalse(self.settings.exists())
        self.assertFalse(snapshot_path.exists())

    def test_existing_statusline_is_passed_through_and_restored(self):
        old_command = (
            f"{shlex.quote(sys.executable)} -c "
            + shlex.quote(
                'import json,sys; print("legacy:" + json.load(sys.stdin)["model"]["display_name"])'
            )
        )
        previous = {
            "type": "command",
            "command": old_command,
            "padding": 2,
            "refreshInterval": 10,
        }
        self.write_settings({"theme": "dark", "statusLine": previous})
        self.run_bridge("install")

        installed = json.loads(self.settings.read_text(encoding="utf-8"))["statusLine"]
        self.assertEqual(installed["padding"], 2)
        self.assertEqual(installed["refreshInterval"], 10)
        payload = {
            "model": {"display_name": "Opus"},
            "rate_limits": {
                "five_hour": {"used_percentage": 10, "resets_at": 1_900_000_000}
            },
        }
        result = subprocess.run(
            installed["command"],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            shell=True,
            env=self.env,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "legacy:Opus\n")

        self.run_bridge("uninstall")
        restored = json.loads(self.settings.read_text(encoding="utf-8"))
        self.assertEqual(restored["statusLine"], previous)
        self.assertEqual(restored["theme"], "dark")

    def test_missing_rate_limits_keeps_last_good_snapshot(self):
        self.run_bridge("install")
        command = self.collect_command()
        first = {
            "rate_limits": {
                "five_hour": {"used_percentage": 50, "resets_at": 1_900_000_000}
            }
        }
        subprocess.run(command, input=json.dumps(first), text=True, shell=True, env=self.env)
        snapshot_path = self.state / "quota-snapshot.json"
        before = snapshot_path.read_bytes()
        subprocess.run(command, input=json.dumps({"version": "2.1.80"}), text=True, shell=True, env=self.env)
        self.assertEqual(snapshot_path.read_bytes(), before)

    def test_uninstall_refuses_to_overwrite_concurrent_change(self):
        self.run_bridge("install")
        settings = json.loads(self.settings.read_text(encoding="utf-8"))
        settings["statusLine"] = {"type": "command", "command": "echo changed"}
        self.write_settings(settings)
        result = self.run_bridge("uninstall", expected=2)
        self.assertIn("modifiée", json.loads(result.stdout)["error"])
        current = json.loads(self.settings.read_text(encoding="utf-8"))
        self.assertEqual(current["statusLine"]["command"], "echo changed")

    def test_invalid_existing_statusline_is_not_overwritten(self):
        original = {"statusLine": {"type": "unsupported", "value": "keep"}}
        self.write_settings(original)
        self.run_bridge("install", expected=2)
        self.assertEqual(json.loads(self.settings.read_text(encoding="utf-8")), original)


if __name__ == "__main__":
    unittest.main()
