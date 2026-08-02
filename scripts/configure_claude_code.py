#!/usr/bin/env python3
"""Safely merge one verified Azure Databricks model into Claude Code."""

from __future__ import annotations

import argparse
import copy
import json
import os
import shlex
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


DEFAULT_MODEL = "databricks-claude-opus-5"
ANTHROPIC_PATH = "/serving-endpoints/anthropic"
ONE_MILLION_MODEL_IDS = {
    "databricks-claude-opus-5",
    "databricks-claude-sonnet-5",
    "databricks-claude-sonnet-4-6",
}
CONFLICTING_ENV_KEYS = {
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_USE_ANTHROPIC_AWS",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_VERTEX",
}
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Merge Azure Databricks routing and one verified model into Claude Code "
            "without overwriting unrelated settings."
        )
    )
    parser.add_argument(
        "--auth",
        choices=("pat", "oauth"),
        default="pat",
        help="Credential mode to configure (default: pat).",
    )
    parser.add_argument(
        "--scope",
        choices=("user", "project"),
        default="user",
        help="Write user settings or project-local settings (default: user).",
    )
    parser.add_argument(
        "--host",
        help="Azure Databricks workspace URL. Defaults to environment or .env.",
    )
    parser.add_argument(
        "--model",
        help=(
            "Verified Databricks model ID. Defaults to DATABRICKS_SERVING_ENDPOINT, "
            "DATABRICKS_MODEL, .env, or databricks-claude-opus-5."
        ),
    )
    parser.add_argument(
        "--profile",
        default="claude-code",
        help="Databricks CLI OAuth profile name (default: claude-code).",
    )
    parser.add_argument(
        "--settings-path",
        type=Path,
        help="Override the destination settings path.",
    )
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=Path.cwd(),
        help="Project directory used with --scope project (default: cwd).",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path(".env"),
        help="Optional dotenv file used as a fallback (default: .env).",
    )
    return parser.parse_args()


def read_env_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}

    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[key] = value
    return values


def first_value(*values: str | None) -> str | None:
    return next((value for value in values if value), None)


def normalize_base_url(value: str) -> str:
    candidate = value.strip().rstrip("/")
    if candidate.endswith(ANTHROPIC_PATH):
        base_url = candidate
    else:
        base_url = f"{candidate}{ANTHROPIC_PATH}"

    parsed = urlparse(base_url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(
            "Workspace host must be an HTTPS URL, for example "
            "https://adb-1234567890123456.7.azuredatabricks.net"
        )
    return base_url


def normalize_model(value: str) -> str:
    model = value.strip()
    if not model or any(character.isspace() for character in model):
        raise ValueError("Model must be a non-empty ID without whitespace.")
    if model.endswith("[1m]") or model not in ONE_MILLION_MODEL_IDS:
        return model
    return f"{model}[1m]"


def resolve_settings_path(args: argparse.Namespace) -> Path:
    if args.settings_path:
        return args.settings_path.expanduser().resolve()
    if args.scope == "project":
        return (
            args.project_dir.expanduser().resolve() / ".claude" / "settings.local.json"
        )
    return Path.home() / ".claude" / "settings.json"


def load_settings(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path} contains invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object.")
    return value


def require_dict(settings: dict[str, object], key: str) -> dict[str, object]:
    value = settings.get(key)
    if value is None:
        result: dict[str, object] = {}
        settings[key] = result
        return result
    if not isinstance(value, dict):
        raise ValueError(f"Existing '{key}' setting must be a JSON object.")
    return value


def oauth_helper_command() -> str:
    scripts_dir = Path(__file__).resolve().parent
    if os.name == "nt":
        helper = scripts_dir / "Get-DatabricksOAuthToken.ps1"
        return f'powershell -NoProfile -File "{helper}"'
    return shlex.quote(str(scripts_dir / "get_databricks_oauth_token.sh"))


def merge_settings(
    existing: dict[str, object],
    *,
    base_url: str,
    model: str,
    auth: str,
    token: str | None,
    profile: str,
) -> tuple[dict[str, object], list[str]]:
    settings = copy.deepcopy(existing)
    removed_conflicts: list[str] = []

    permissions = require_dict(settings, "permissions")
    deny = permissions.get("deny")
    if deny is None:
        deny_list: list[object] = []
        permissions["deny"] = deny_list
    elif isinstance(deny, list):
        deny_list = deny
    else:
        raise ValueError("Existing 'permissions.deny' setting must be a JSON array.")
    if "WebSearch" not in deny_list:
        deny_list.append("WebSearch")

    env = require_dict(settings, "env")
    removable_keys = set(CONFLICTING_ENV_KEYS)
    removable_keys.update(
        key
        for key in env
        if key.startswith("ANTHROPIC_DEFAULT_")
        or key.startswith("ANTHROPIC_CUSTOM_MODEL_OPTION")
    )
    for key in removable_keys:
        if key in env:
            removed_conflicts.append(key)
            env.pop(key)

    env["ANTHROPIC_BASE_URL"] = base_url
    env["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] = "1"
    settings["model"] = model

    if auth == "pat":
        if not token:
            raise ValueError(
                "PAT mode requires DATABRICKS_TOKEN or ANTHROPIC_AUTH_TOKEN."
            )
        env["ANTHROPIC_AUTH_TOKEN"] = token
        env.pop("DATABRICKS_CONFIG_PROFILE", None)
        settings.pop("apiKeyHelper", None)
    else:
        env.pop("ANTHROPIC_AUTH_TOKEN", None)
        env["DATABRICKS_CONFIG_PROFILE"] = profile
        settings["apiKeyHelper"] = oauth_helper_command()

    return settings, sorted(removed_conflicts)


def restrict_permissions(path: Path) -> None:
    if os.name != "nt":
        path.chmod(0o600)
        return

    username = os.environ.get("USERNAME")
    if not username:
        raise ValueError("USERNAME is required to restrict Windows settings access.")
    result = subprocess.run(
        [
            "icacls",
            str(path),
            "/inheritance:r",
            "/grant:r",
            f"{username}:(M)",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ValueError(f"Failed to restrict access to {path}: {detail}")


def prune_backups(path: Path, keep: int = 1) -> None:
    backups = sorted(
        path.parent.glob(f"{path.name}.bak.*"),
        key=lambda backup: backup.stat().st_mtime_ns,
        reverse=True,
    )
    for backup in backups[keep:]:
        backup.unlink()


def write_settings(path: Path, settings: dict[str, object]) -> Path | None:
    rendered = json.dumps(settings, ensure_ascii=False, indent=2) + "\n"
    if path.exists() and path.read_text(encoding="utf-8") == rendered:
        return None

    path.parent.mkdir(parents=True, exist_ok=True)
    backup_path: Path | None = None
    if path.exists():
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f")
        backup_path = path.with_name(f"{path.name}.bak.{timestamp}")
        shutil.copy2(path, backup_path)
        restrict_permissions(backup_path)

    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent, text=True
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        if os.name != "nt":
            temporary_path.chmod(0o600)
        os.replace(temporary_path, path)
        restrict_permissions(path)
        prune_backups(path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()

    return backup_path


def main() -> int:
    args = parse_args()
    env_file = read_env_file(args.env_file)

    raw_host = first_value(
        args.host,
        os.environ.get("DATABRICKS_HOST"),
        os.environ.get("ANTHROPIC_BASE_URL"),
        env_file.get("DATABRICKS_HOST"),
        env_file.get("ANTHROPIC_BASE_URL"),
    )
    if not raw_host:
        raise SystemExit(
            "Workspace host is required. Set DATABRICKS_HOST or "
            "ANTHROPIC_BASE_URL, or pass --host."
        )

    token = first_value(
        os.environ.get("DATABRICKS_TOKEN"),
        os.environ.get("ANTHROPIC_AUTH_TOKEN"),
        env_file.get("DATABRICKS_TOKEN"),
        env_file.get("ANTHROPIC_AUTH_TOKEN"),
    )
    raw_model = first_value(
        args.model,
        os.environ.get("DATABRICKS_SERVING_ENDPOINT"),
        os.environ.get("DATABRICKS_MODEL"),
        env_file.get("DATABRICKS_SERVING_ENDPOINT"),
        env_file.get("DATABRICKS_MODEL"),
        DEFAULT_MODEL,
    )
    path = resolve_settings_path(args)

    try:
        base_url = normalize_base_url(raw_host)
        model = normalize_model(raw_model)
        existing = load_settings(path)
        settings, removed_conflicts = merge_settings(
            existing,
            base_url=base_url,
            model=model,
            auth=args.auth,
            token=token,
            profile=args.profile,
        )
        backup_path = write_settings(path, settings)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc

    print(f"Claude Code settings: {path}")
    print(f"Model: {model}")
    if backup_path:
        print(f"Backup: {backup_path}")
    if removed_conflicts:
        print(f"Removed conflicting settings: {', '.join(removed_conflicts)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
