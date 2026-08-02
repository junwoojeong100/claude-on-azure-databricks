import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIGURATOR = ROOT / "scripts" / "configure_claude_code.py"


class ConfigureClaudeCodeTests(unittest.TestCase):
    def run_configurator(
        self,
        temp_path: Path,
        *arguments: str,
        token: str | None = "dapi-test-token",
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        for key in (
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "DATABRICKS_HOST",
            "DATABRICKS_TOKEN",
        ):
            environment.pop(key, None)
        environment["DATABRICKS_HOST"] = (
            "https://adb-1234567890123456.7.azuredatabricks.net"
        )
        if token is not None:
            environment["DATABRICKS_TOKEN"] = token

        return subprocess.run(
            [sys.executable, str(CONFIGURATOR), *arguments],
            cwd=temp_path,
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )

    def test_creates_single_verified_model_pat_settings(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            settings_path = temp_path / "settings.json"

            result = self.run_configurator(
                temp_path, "--settings-path", str(settings_path)
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(settings["model"], "databricks-claude-opus-5[1m]")
            self.assertEqual(
                settings["env"]["ANTHROPIC_BASE_URL"],
                "https://adb-1234567890123456.7.azuredatabricks.net"
                "/serving-endpoints/anthropic",
            )
            self.assertEqual(settings["env"]["ANTHROPIC_AUTH_TOKEN"], "dapi-test-token")
            self.assertFalse(
                any(
                    key.startswith("ANTHROPIC_DEFAULT_")
                    for key in settings["env"]
                )
            )
            self.assertNotIn("ANTHROPIC_CUSTOM_MODEL_OPTION", settings["env"])
            self.assertIn("WebSearch", settings["permissions"]["deny"])
            self.assertNotIn("dapi-test-token", result.stdout + result.stderr)
            if os.name != "nt":
                self.assertEqual(
                    stat.S_IMODE(settings_path.stat().st_mode),
                    0o600,
                )

    def test_merges_existing_settings_and_creates_one_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            settings_path = temp_path / "settings.json"
            settings_path.write_text(
                json.dumps(
                    {
                        "customSetting": True,
                        "permissions": {
                            "allow": ["Bash(git status)"],
                            "deny": ["Bash(rm -rf *)"],
                        },
                        "env": {
                            "CUSTOM_ENV": "preserved",
                            "CLAUDE_CODE_USE_BEDROCK": "1",
                            "ANTHROPIC_DEFAULT_FABLE_MODEL": (
                                "databricks-claude-opus-4-8[1m]"
                            ),
                            "ANTHROPIC_CUSTOM_MODEL_OPTION": (
                                "databricks-claude-sonnet-4-6[1m]"
                            ),
                        },
                    }
                ),
                encoding="utf-8",
            )

            result = self.run_configurator(
                temp_path, "--settings-path", str(settings_path)
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertTrue(settings["customSetting"])
            self.assertEqual(
                settings["permissions"]["allow"],
                ["Bash(git status)"],
            )
            self.assertIn("Bash(rm -rf *)", settings["permissions"]["deny"])
            self.assertEqual(settings["env"]["CUSTOM_ENV"], "preserved")
            self.assertNotIn("CLAUDE_CODE_USE_BEDROCK", settings["env"])
            self.assertNotIn("ANTHROPIC_DEFAULT_FABLE_MODEL", settings["env"])
            self.assertNotIn("ANTHROPIC_CUSTOM_MODEL_OPTION", settings["env"])
            backups = list(temp_path.glob("settings.json.bak.*"))
            self.assertEqual(len(backups), 1)
            self.assertIn("Removed conflicting settings", result.stdout)

            second_result = self.run_configurator(
                temp_path, "--settings-path", str(settings_path)
            )

            self.assertEqual(second_result.returncode, 0, second_result.stderr)
            self.assertEqual(len(list(temp_path.glob("settings.json.bak.*"))), 1)

            rotated_result = self.run_configurator(
                temp_path,
                "--settings-path",
                str(settings_path),
                token="dapi-rotated-token",
            )

            self.assertEqual(rotated_result.returncode, 0, rotated_result.stderr)
            self.assertEqual(len(list(temp_path.glob("settings.json.bak.*"))), 1)
            rotated_settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(
                rotated_settings["env"]["ANTHROPIC_AUTH_TOKEN"],
                "dapi-rotated-token",
            )

    def test_configures_oauth_helper_without_static_token(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            settings_path = temp_path / "settings.json"
            settings_path.write_text(
                json.dumps(
                    {
                        "env": {
                            "ANTHROPIC_AUTH_TOKEN": "old-static-token",
                        }
                    }
                ),
                encoding="utf-8",
            )

            result = self.run_configurator(
                temp_path,
                "--auth",
                "oauth",
                "--profile",
                "workspace-oauth",
                "--settings-path",
                str(settings_path),
                token=None,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertNotIn("ANTHROPIC_AUTH_TOKEN", settings["env"])
            self.assertEqual(
                settings["env"]["DATABRICKS_CONFIG_PROFILE"],
                "workspace-oauth",
            )
            helper_name = (
                "Get-DatabricksOAuthToken.ps1"
                if os.name == "nt"
                else "get_databricks_oauth_token.sh"
            )
            self.assertIn(helper_name, settings["apiKeyHelper"])

    def test_project_scope_writes_local_settings(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)

            result = self.run_configurator(
                temp_path,
                "--scope",
                "project",
                "--project-dir",
                str(temp_path),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((temp_path / ".claude" / "settings.local.json").is_file())

    def test_uses_explicit_verified_model(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            settings_path = temp_path / "settings.json"

            result = self.run_configurator(
                temp_path,
                "--model",
                "databricks-claude-haiku-4-5",
                "--settings-path",
                str(settings_path),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(settings["model"], "databricks-claude-haiku-4-5")

    def test_adds_1m_selector_to_known_model(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            settings_path = temp_path / "settings.json"

            result = self.run_configurator(
                temp_path,
                "--model",
                "databricks-claude-sonnet-5",
                "--settings-path",
                str(settings_path),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(
                settings["model"],
                "databricks-claude-sonnet-5[1m]",
            )

    def test_reads_workspace_credentials_from_dotenv(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            settings_path = temp_path / "settings.json"
            (temp_path / ".env").write_text(
                "DATABRICKS_HOST=https://adb-1234567890123456.7.azuredatabricks.net\n"
                "DATABRICKS_TOKEN=dapi-dotenv-token\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            for key in (
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
                "DATABRICKS_HOST",
                "DATABRICKS_TOKEN",
            ):
                environment.pop(key, None)

            result = subprocess.run(
                [
                    sys.executable,
                    str(CONFIGURATOR),
                    "--settings-path",
                    str(settings_path),
                ],
                cwd=temp_path,
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(
                settings["env"]["ANTHROPIC_AUTH_TOKEN"],
                "dapi-dotenv-token",
            )

    def test_invalid_existing_json_is_not_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            settings_path = temp_path / "settings.json"
            settings_path.write_text("{invalid", encoding="utf-8")

            result = self.run_configurator(
                temp_path, "--settings-path", str(settings_path)
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contains invalid JSON", result.stderr)
            self.assertEqual(settings_path.read_text(encoding="utf-8"), "{invalid")
            self.assertEqual(list(temp_path.glob("settings.json.bak.*")), [])


if __name__ == "__main__":
    unittest.main()
