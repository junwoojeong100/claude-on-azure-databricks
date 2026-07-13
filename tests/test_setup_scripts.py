from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASH_SETUP = ROOT / "scripts" / "setup_claude_code_databricks.sh"
PYTHON_HEREDOC = re.compile(r"<<'PY'\n(.*?)\nPY", re.DOTALL)
CONFLICTING_CLAUDE_VARIABLES = (
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_FABLE_MODEL",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_MANTLE",
    "CLAUDE_CODE_USE_ANTHROPIC_AWS",
)


def embedded_python_blocks() -> list[str]:
    return PYTHON_HEREDOC.findall(BASH_SETUP.read_text(encoding="utf-8"))


def native_response_check() -> str:
    script = BASH_SETUP.read_text(encoding="utf-8")
    marker = 'printf "%s" "$NATIVE_BODY" | "$PYTHON" -c \''
    start = script.index(marker) + len(marker)
    end = script.index("\n'", start)
    return script[start:end].lstrip("\n")


def run_bash_setup(
    extra_environment: dict[str, str] | None = None,
    legacy_environment: str | None = None,
    use_ambient_config_dir: bool = False,
    initial_settings: dict | None = None,
    runs: int = 1,
):
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)
        home = temp_path / "home"
        fake_bin = temp_path / "bin"
        home.mkdir()
        fake_bin.mkdir()

        fake_curl = fake_bin / "curl"
        fake_curl.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n%s' '{\"type\":\"message\",\"content\":[]}' '200'\n",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)

        fake_claude = fake_bin / "claude"
        fake_claude.write_text(
            "#!/usr/bin/env bash\n"
            'if [ "${1:-}" = "--version" ]; then\n'
            "  printf '%s\\n' '2.1.207'\n"
            "else\n"
            '  printf \'%s\\n\' \'{"is_error":false,"result":"DIRECT OK"}\'\n'
            "fi\n",
            encoding="utf-8",
        )
        fake_claude.chmod(0o755)

        for command_name, command_body in (
            ("uname", "printf '%s\\n' 'TestOS'"),
            ("launchctl", "exit 0"),
            ("systemctl", "exit 0"),
            ("date", "printf '%s\\n' '20260713000000'"),
        ):
            fake_command = fake_bin / command_name
            fake_command.write_text(
                f"#!/usr/bin/env bash\n{command_body}\n",
                encoding="utf-8",
            )
            fake_command.chmod(0o755)

        env_file = temp_path / ".env"
        env_file.write_text(
            "DATABRICKS_HOST=https://adb-1234567890123456.7.azuredatabricks.net\n"
            "DATABRICKS_TOKEN=test-token\n",
            encoding="utf-8",
        )
        config_dir = (
            home / ".claude-databricks-config"
            if use_ambient_config_dir
            else home / ".claude"
        )
        settings_path = config_dir / "settings.json"
        state_dir = home / ".claude-databricks"
        if initial_settings is not None:
            config_dir.mkdir(parents=True)
            settings_path.write_text(json.dumps(initial_settings), encoding="utf-8")
        if legacy_environment is not None:
            state_dir.mkdir()
            (state_dir / ".env").write_text(legacy_environment, encoding="utf-8")
            (state_dir / "config.yaml").write_text("model_list: []\n", encoding="utf-8")

        environment = os.environ.copy()
        for name in (
            *CONFLICTING_CLAUDE_VARIABLES,
            "DATABRICKS_HOST",
            "DATABRICKS_TOKEN",
        ):
            environment.pop(name, None)
        environment.pop("CLAUDE_CONFIG_DIR", None)
        environment.pop("CLAUDE_SETTINGS", None)
        environment.update(
            {
                "HOME": str(home),
                "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                "ENV_FILE": str(env_file),
                "STATE_DIR": str(state_dir),
            }
        )
        if use_ambient_config_dir:
            environment["CLAUDE_CONFIG_DIR"] = str(config_dir)
        else:
            environment["CLAUDE_SETTINGS"] = str(settings_path)
        if extra_environment:
            environment.update(extra_environment)

        result = None
        for _ in range(runs):
            result = subprocess.run(
                ["bash", str(BASH_SETUP)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                env=environment,
            )
            if result.returncode:
                break
        assert result is not None
        settings = (
            json.loads(settings_path.read_text(encoding="utf-8"))
            if settings_path.exists()
            else None
        )
        legacy_backup_path = state_dir / "legacy-state-backups" / ".env.pre-direct"
        legacy_backup = (
            legacy_backup_path.read_text(encoding="utf-8")
            if legacy_backup_path.exists()
            else None
        )
        settings_backups = sorted(config_dir.glob("settings.json.bak.*"))
        return result, settings, legacy_backup, settings_backups


class SetupScriptTests(unittest.TestCase):
    def test_embedded_python_blocks_compile(self) -> None:
        blocks = embedded_python_blocks()
        self.assertGreaterEqual(len(blocks), 2)

        for index, block in enumerate(blocks):
            compile(block, f"{BASH_SETUP}:python-block-{index}", "exec")
        compile(native_response_check(), f"{BASH_SETUP}:native-response-check", "exec")

    def test_native_response_requires_top_level_message_type(self) -> None:
        check = native_response_check()

        for body, expected_code in (
            ('{"type":"message"}', 0),
            ('{"result":{"type":"message"}}', 1),
            ('{"type":"error"}', 1),
            ("not-json", 1),
        ):
            result = subprocess.run(
                [sys.executable, "-c", check],
                input=body,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, expected_code, body)
            self.assertEqual(result.stderr, "", body)

    def test_bash_setup_does_not_reject_internal_base_url(self) -> None:
        result, settings, _, _ = run_bash_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(settings)
        self.assertEqual(
            settings["env"]["ANTHROPIC_BASE_URL"],
            "https://adb-1234567890123456.7.azuredatabricks.net/"
            "serving-endpoints/anthropic",
        )

    def test_bash_setup_rejects_provider_selector(self) -> None:
        result, settings, _, _ = run_bash_setup({"CLAUDE_CODE_USE_FOUNDRY": "1"})

        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(settings)
        self.assertIn("CLAUDE_CODE_USE_* provider selectors", result.stderr)

    def test_bash_setup_uses_ambient_config_directory(self) -> None:
        result, settings, _, _ = run_bash_setup(use_ambient_config_dir=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(settings)

    def test_bash_setup_backs_up_complete_legacy_environment(self) -> None:
        legacy_environment = (
            "DATABRICKS_API_KEY=legacy-key\n"
            "DATABRICKS_API_BASE=https://legacy.example\n"
            "LITELLM_MASTER_KEY=legacy-master\n"
        )
        result, _, legacy_backup, _ = run_bash_setup(
            legacy_environment=legacy_environment
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(legacy_backup, legacy_environment)

    def test_bash_setup_does_not_backup_direct_environment_as_legacy(self) -> None:
        result, _, legacy_backup, _ = run_bash_setup(
            legacy_environment="DATABRICKS_TOKEN=already-direct\n"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(legacy_backup)
        self.assertIn("no restorable legacy environment backup", result.stdout)

    def test_bash_setup_uses_unique_settings_backup_names(self) -> None:
        result, settings, _, settings_backups = run_bash_setup(
            initial_settings={"custom": {"keep": True}},
            runs=2,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(settings)
        self.assertEqual(len(settings_backups), 2)
        self.assertEqual(len({path.name for path in settings_backups}), 2)

    def test_settings_merge_preserves_unrelated_values(self) -> None:
        merge_block = next(
            block
            for block in embedded_python_blocks()
            if 'data["availableModels"]' in block
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            settings_path = Path(temp_dir) / "settings.json"
            settings_path.write_text(
                json.dumps(
                    {
                        "custom": {"keep": True},
                        "apiKeyHelper": "old-helper",
                        "env": {
                            "KEEP_ME": "yes",
                            "ANTHROPIC_AUTH_TOKEN": "old-token",
                            "ANTHROPIC_API_KEY": "old-key",
                            "ANTHROPIC_MODEL": "old-model",
                            "ANTHROPIC_SMALL_FAST_MODEL": "old-fast-model",
                            "ANTHROPIC_DEFAULT_OPUS_MODEL": "old-opus",
                            "CLAUDE_CODE_USE_FOUNDRY": "1",
                            "CLAUDE_CODE_USE_BEDROCK": "1",
                            "CLAUDE_CODE_USE_VERTEX": "1",
                            "CLAUDE_CODE_USE_MANTLE": "1",
                            "CLAUDE_CODE_USE_ANTHROPIC_AWS": "1",
                        },
                        "permissions": {
                            "deny": ["Bash(rm:*)", "WebSearch"],
                        },
                        "availableModels": ["old-model"],
                        "enforceAvailableModels": False,
                    }
                ),
                encoding="utf-8",
            )

            helper_path = str(Path(temp_dir) / "helper with spaces" / "get-token.sh")
            environment = os.environ.copy()
            environment.update(
                {
                    "CLAUDE_SETTINGS": str(settings_path),
                    "TOKEN_HELPER": helper_path,
                    "ANTHROPIC_BASE_URL": (
                        "https://adb-1234567890123456.7.azuredatabricks.net/"
                        "serving-endpoints/anthropic"
                    ),
                    "ENDPOINT": "databricks-claude-opus-4-8",
                    "FAST_ENDPOINT": "databricks-claude-haiku-4-5",
                    "VALID_MODELS": (
                        "databricks-claude-opus-4-8 "
                        "databricks-claude-haiku-4-5 "
                        "databricks-claude-sonnet-5 "
                        "databricks-claude-opus-4-8"
                    ),
                    "DEFAULT_OPUS": "databricks-claude-opus-4-8",
                    "DEFAULT_SONNET": "databricks-claude-sonnet-5",
                    "DEFAULT_HAIKU": "databricks-claude-haiku-4-5",
                    "DEFAULT_FABLE": "",
                }
            )

            for _ in range(2):
                subprocess.run(
                    [sys.executable, "-c", merge_block],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=environment,
                )

            result = json.loads(settings_path.read_text(encoding="utf-8"))

        self.assertEqual(result["custom"], {"keep": True})
        self.assertEqual(result["apiKeyHelper"], shlex.quote(helper_path))
        self.assertTrue(result["enforceAvailableModels"])
        self.assertEqual(
            result["availableModels"],
            [
                "opus",
                "sonnet",
                "haiku",
                "databricks-claude-opus-4-8",
                "databricks-claude-haiku-4-5",
                "databricks-claude-sonnet-5",
            ],
        )
        self.assertEqual(result["permissions"]["deny"], ["Bash(rm:*)", "WebSearch"])

        env = result["env"]
        self.assertEqual(env["KEEP_ME"], "yes")
        self.assertEqual(
            env["ANTHROPIC_BASE_URL"],
            "https://adb-1234567890123456.7.azuredatabricks.net/"
            "serving-endpoints/anthropic",
        )
        self.assertEqual(
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"],
            "databricks-claude-opus-4-8",
        )
        self.assertEqual(
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"],
            "databricks-claude-sonnet-5",
        )
        self.assertEqual(
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"],
            "databricks-claude-haiku-4-5",
        )
        self.assertEqual(env["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"], "1")
        self.assertEqual(env["CLAUDE_CODE_API_KEY_HELPER_TTL_MS"], "900000")

        for removed_key in (
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_USE_FOUNDRY",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_MANTLE",
            "CLAUDE_CODE_USE_ANTHROPIC_AWS",
        ):
            self.assertNotIn(removed_key, env)


if __name__ == "__main__":
    unittest.main()
