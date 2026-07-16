#!/usr/bin/env python3
"""Opt-in Claude Code statusLine bridge for the Status macOS app.

The bridge only consumes the documented `rate_limits` object Claude Code sends
to status-line commands. It never reads Claude credentials, transcripts, or
browser state.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
from typing import Any, Optional, Tuple


SCHEMA_VERSION = 1
BRIDGE_ID = "com.status.claude-code-statusline.v1"
MAX_STDIN_BYTES = 2 * 1024 * 1024
WINDOW_NAME = re.compile(r"^[a-z0-9_]{1,64}$")


class BridgeError(RuntimeError):
    pass


def _state_dir() -> Path:
    override = os.environ.get("STATUS_CLAUDE_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Status" / "Claude"


def _settings_path() -> Path:
    override = os.environ.get("STATUS_CLAUDE_SETTINGS_PATH")
    if override:
        return Path(override).expanduser()
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if config_dir:
        return Path(config_dir).expanduser() / "settings.json"
    return Path.home() / ".claude" / "settings.json"


def _paths() -> dict[str, Path]:
    root = _state_dir()
    return {
        "root": root,
        "manifest": root / "bridge-state.json",
        "snapshot": root / "quota-snapshot.json",
        "helper": root / "status-claude-bridge.py",
        "settings_backup": root / "settings-before-install.json",
    }


def _ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def _atomic_write_bytes(path: Path, data: bytes, mode: int = 0o600) -> None:
    _ensure_private_directory(path.parent)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
        os.chmod(path, mode)
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


def _atomic_write_json(path: Path, value: Any, mode: int = 0o600) -> None:
    payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)
    _atomic_write_bytes(path, (payload + "\n").encode("utf-8"), mode)


def _read_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise BridgeError(f"JSON illisible : {path}: {error}") from error


def _read_settings(path: Path) -> dict[str, Any]:
    value = _read_json(path, {})
    if not isinstance(value, dict):
        raise BridgeError(f"La configuration Claude doit être un objet JSON : {path}")
    return value


def _utc_now() -> Tuple[str, int]:
    now = dt.datetime.now(dt.timezone.utc)
    return now.isoformat(timespec="seconds").replace("+00:00", "Z"), int(now.timestamp())


def _safe_number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


def _safe_epoch(value: Any) -> Optional[int]:
    number = _safe_number(value)
    if number is None or number <= 0:
        return None
    return int(number)


def _normalize_rate_limits(payload: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(payload, dict):
        return {}
    normalized: dict[str, dict[str, Any]] = {}
    for name, raw_window in payload.items():
        if not isinstance(name, str) or not WINDOW_NAME.fullmatch(name):
            continue
        if not isinstance(raw_window, dict):
            continue
        used = _safe_number(raw_window.get("used_percentage"))
        resets_at = _safe_epoch(raw_window.get("resets_at"))
        if used is None or resets_at is None:
            continue
        used = min(100.0, max(0.0, used))
        normalized[name] = {
            "used_percentage": used,
            "remaining_percentage": 100.0 - used,
            "resets_at": resets_at,
        }
    return normalized


def _read_stdin_payload() -> Tuple[bytes, dict[str, Any]]:
    raw = sys.stdin.buffer.read(MAX_STDIN_BYTES + 1)
    if len(raw) > MAX_STDIN_BYTES:
        raise BridgeError("Le payload statusLine dépasse la limite de sécurité")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise BridgeError(f"Payload statusLine invalide : {error}") from error
    if not isinstance(value, dict):
        raise BridgeError("Le payload statusLine doit être un objet JSON")
    return raw, value


def _load_manifest(required: bool = True) -> Optional[dict[str, Any]]:
    value = _read_json(_paths()["manifest"], None)
    if value is None:
        if required:
            raise BridgeError("Le bridge Claude n'est pas installé")
        return None
    if not isinstance(value, dict) or value.get("bridge_id") != BRIDGE_ID:
        raise BridgeError("Manifest du bridge Claude invalide")
    return value


def _run_previous_status_line(manifest: dict[str, Any], raw: bytes) -> int:
    if not manifest.get("previous_status_line_present"):
        return 0
    previous = manifest.get("previous_status_line")
    if not isinstance(previous, dict):
        return 0
    if previous.get("type") != "command" or not isinstance(previous.get("command"), str):
        return 0
    command = previous["command"]
    completed = subprocess.run(
        command,
        shell=True,
        executable="/bin/sh",
        input=raw,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=os.getcwd(),
        env=os.environ.copy(),
        check=False,
    )
    sys.stdout.buffer.write(completed.stdout)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(completed.stderr)
    sys.stderr.buffer.flush()
    return completed.returncode


def command_collect(_: argparse.Namespace) -> int:
    manifest = _load_manifest(required=True)
    assert manifest is not None
    raw, payload = _read_stdin_payload()
    rate_limits = _normalize_rate_limits(payload.get("rate_limits"))
    if rate_limits:
        captured_at, captured_at_epoch = _utc_now()
        snapshot: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "provider": "claude",
            "source": "claude_code_statusline",
            "captured_at": captured_at,
            "captured_at_epoch": captured_at_epoch,
            "rate_limits": rate_limits,
        }
        version = payload.get("version")
        if isinstance(version, str) and len(version) <= 128:
            snapshot["claude_code_version"] = version
        session_id = payload.get("session_id")
        if isinstance(session_id, str) and len(session_id) <= 256:
            snapshot["session_id"] = session_id
        _atomic_write_json(_paths()["snapshot"], snapshot, 0o600)
    return _run_previous_status_line(manifest, raw)


def _installed_status_line(helper: Path, previous: Any) -> dict[str, Any]:
    result: dict[str, Any] = {
        "type": "command",
        "command": f"{shlex.quote(str(helper))} collect",
    }
    if isinstance(previous, dict):
        for key in ("padding", "refreshInterval", "hideVimModeIndicator"):
            if key in previous:
                result[key] = previous[key]
    return result


def _copy_self(destination: Path) -> None:
    source = Path(__file__).resolve()
    if source == destination.resolve(strict=False):
        os.chmod(destination, 0o700)
        return
    data = source.read_bytes()
    _atomic_write_bytes(destination, data, 0o700)


def command_install(_: argparse.Namespace) -> int:
    paths = _paths()
    settings_path = _settings_path()
    _ensure_private_directory(paths["root"])

    existing_manifest = _load_manifest(required=False)
    if existing_manifest is not None:
        settings = _read_settings(settings_path)
        if settings.get("statusLine") == existing_manifest.get("installed_status_line"):
            _copy_self(paths["helper"])
            _print_json({"ok": True, "changed": False, **_status_payload()})
            return 0
        raise BridgeError(
            "Le bridge a déjà un manifest, mais statusLine a changé. "
            "Exécutez status puis uninstall avant de réinstaller."
        )

    settings = _read_settings(settings_path)
    previous_present = "statusLine" in settings
    previous = settings.get("statusLine")
    if previous_present and (
        not isinstance(previous, dict)
        or previous.get("type") != "command"
        or not isinstance(previous.get("command"), str)
    ):
        raise BridgeError(
            "La statusLine existante n'est pas une commande compatible ; "
            "installation annulée sans modification."
        )

    original_bytes = (
        settings_path.read_bytes()
        if settings_path.exists()
        else b"{}\n"
    )
    _atomic_write_bytes(paths["settings_backup"], original_bytes, 0o600)
    _copy_self(paths["helper"])
    installed = _installed_status_line(paths["helper"], previous)
    captured_at, _ = _utc_now()
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "bridge_id": BRIDGE_ID,
        "installed_at": captured_at,
        "settings_path": str(settings_path),
        "snapshot_path": str(paths["snapshot"]),
        "helper_path": str(paths["helper"]),
        "settings_file_present": settings_path.exists(),
        "previous_status_line_present": previous_present,
        "previous_status_line": previous if previous_present else None,
        "installed_status_line": installed,
    }
    _atomic_write_json(paths["manifest"], manifest, 0o600)

    updated = dict(settings)
    updated["statusLine"] = installed
    try:
        _atomic_write_json(settings_path, updated, 0o600)
    except Exception:
        paths["manifest"].unlink(missing_ok=True)
        paths["helper"].unlink(missing_ok=True)
        raise

    _print_json({"ok": True, "changed": True, **_status_payload()})
    return 0


def _status_payload() -> dict[str, Any]:
    paths = _paths()
    settings_path = _settings_path()
    manifest = _load_manifest(required=False)
    settings_error: Optional[str] = None
    try:
        settings = _read_settings(settings_path)
    except BridgeError as error:
        settings = {}
        settings_error = str(error)

    installed = manifest is not None
    configured = bool(
        installed and settings.get("statusLine") == manifest.get("installed_status_line")
    )
    snapshot = _read_json(paths["snapshot"], None)
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "bridge_id": BRIDGE_ID,
        "installed": installed,
        "configured": configured,
        "settings_path": str(settings_path),
        "state_directory": str(paths["root"]),
        "snapshot_path": str(paths["snapshot"]),
        "snapshot_present": isinstance(snapshot, dict),
        "snapshot": snapshot if isinstance(snapshot, dict) else None,
    }
    if manifest is not None:
        result["previous_status_line_preserved"] = bool(
            manifest.get("previous_status_line_present")
        )
    if settings_error:
        result["settings_error"] = settings_error
    return result


def command_status(_: argparse.Namespace) -> int:
    _print_json({"ok": True, **_status_payload()})
    return 0


def command_uninstall(args: argparse.Namespace) -> int:
    paths = _paths()
    manifest = _load_manifest(required=False)
    if manifest is None:
        if not args.keep_snapshot:
            paths["snapshot"].unlink(missing_ok=True)
        _print_json({"ok": True, "changed": False, **_status_payload()})
        return 0

    settings_path = Path(str(manifest.get("settings_path") or _settings_path()))
    settings = _read_settings(settings_path)
    matches = settings.get("statusLine") == manifest.get("installed_status_line")
    if not matches and not args.force:
        raise BridgeError(
            "La configuration statusLine a été modifiée depuis l'installation. "
            "Aucun fichier n'a été écrasé. Utilisez uninstall --force uniquement "
            "si vous souhaitez restaurer l'ancienne statusLine."
        )

    updated = dict(settings)
    if manifest.get("previous_status_line_present"):
        updated["statusLine"] = manifest.get("previous_status_line")
    else:
        updated.pop("statusLine", None)
    if not updated and not manifest.get("settings_file_present"):
        settings_path.unlink(missing_ok=True)
    else:
        _atomic_write_json(settings_path, updated, 0o600)

    paths["manifest"].unlink(missing_ok=True)
    paths["settings_backup"].unlink(missing_ok=True)
    if not args.keep_snapshot:
        paths["snapshot"].unlink(missing_ok=True)
    helper = paths["helper"]
    try:
        helper.unlink(missing_ok=True)
    except OSError:
        pass
    _print_json({"ok": True, "changed": True, **_status_payload()})
    return 0


def _print_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Bridge opt-in des quotas Claude Code vers Status"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("install", help="Installer le collecteur et préserver la statusLine")
    subparsers.add_parser("status", help="Afficher l'état et le dernier snapshot JSON")
    subparsers.add_parser("collect", help=argparse.SUPPRESS)
    uninstall = subparsers.add_parser(
        "uninstall", help="Restaurer la statusLine précédente et retirer le bridge"
    )
    uninstall.add_argument(
        "--force",
        action="store_true",
        help="Restaurer malgré une modification concurrente de statusLine",
    )
    uninstall.add_argument(
        "--keep-snapshot",
        action="store_true",
        help="Conserver le dernier snapshot non secret",
    )
    return parser


def main() -> int:
    args = _parser().parse_args()
    commands = {
        "install": command_install,
        "status": command_status,
        "collect": command_collect,
        "uninstall": command_uninstall,
    }
    try:
        return commands[args.command](args)
    except BridgeError as error:
        _print_json({"ok": False, "error": str(error)})
        return 2
    except OSError as error:
        _print_json({"ok": False, "error": str(error)})
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
