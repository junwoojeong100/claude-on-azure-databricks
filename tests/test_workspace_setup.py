import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_SETUP = ROOT / "scripts" / "setup_databricks_claude.sh"
CLAUDE_CONFIGURATOR = ROOT / "scripts" / "configure_claude_code.py"


def run_workspace_setup_without_venv(
    native_status="200",
    existing_env=None,
    existing_settings=None,
    pat_validation_status="200",
    configure_claude_code="1",
):
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)
        script_dir = temp_path / "scripts"
        fake_bin = temp_path / "bin"
        script_dir.mkdir()
        fake_bin.mkdir()

        copied_setup = script_dir / WORKSPACE_SETUP.name
        copied_setup.write_text(
            WORKSPACE_SETUP.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        copied_setup.chmod(0o755)
        copied_configurator = script_dir / CLAUDE_CONFIGURATOR.name
        copied_configurator.write_text(
            CLAUDE_CONFIGURATOR.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        if existing_env is not None:
            (temp_path / ".env").write_text(existing_env, encoding="utf-8")
        if existing_settings is not None:
            settings_path = temp_path / "home" / ".claude" / "settings.json"
            settings_path.parent.mkdir(parents=True)
            settings_path.write_text(existing_settings, encoding="utf-8")

        fake_az = fake_bin / "az"
        fake_az.write_text(
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            'case "$*" in\n'
            '  "account show --query name -o tsv") printf "%s\\n" "test-subscription" ;;\n'
            '  "account show"|"extension show --name databricks") printf "%s\\n" "{}" ;;\n'
            '  group\\ show\\ -n\\ *) printf "%s\\n" "{}" ;;\n'
            "  databricks\\ workspace\\ show\\ *--query\\ workspaceUrl\\ -o\\ tsv)\n"
            '    printf "%s\\n" "adb-1234567890123456.7.azuredatabricks.net" ;;\n'
            '  databricks\\ workspace\\ show\\ *) printf "%s\\n" "{}" ;;\n'
            "  account\\ get-access-token\\ --resource\\ *\\ --query\\ accessToken\\ -o\\ tsv)\n"
            '    printf "%s\\n" "aad-token" ;;\n'
            '  *) printf "unexpected az call: %s\\n" "$*" >&2; exit 1 ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        fake_az.chmod(0o755)

        fake_curl = fake_bin / "curl"
        fake_curl.write_text(
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            'output=""\n'
            'write_out=""\n'
            'url=""\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  case "$1" in\n'
            '    -o) output="$2"; shift 2 ;;\n'
            '    -w) write_out="$2"; shift 2 ;;\n'
            '    http://*|https://*) url="$1"; shift ;;\n'
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            'case "$url" in\n'
            "  */api/2.0/token/create)\n"
            "    printf '%s\\n' '{\"token_value\":\"dapi-test-token\"}' ;;\n"
            "  */api/2.0/serving-endpoints)\n"
            "    payload='"
            '{"endpoints":[{"name":"databricks-claude-opus-5",'
            '"state":{"ready":"READY"}}]}'
            "'\n"
            '    if [ "$write_out" = "%{http_code}" ]; then\n'
            '      status="${FAKE_PAT_VALIDATION_STATUS:-200}"\n'
            '      if [ -n "$output" ]; then printf \'%s\\n\' "$payload" >"$output"; fi\n'
            '      printf "%s" "$status"\n'
            '    elif [ -n "$output" ]; then\n'
            '      printf \'%s\\n\' "$payload" >"$output"\n'
            "    else\n"
            "      printf '%s\\n' \"$payload\"\n"
            "    fi ;;\n"
            "  */serving-endpoints/chat/completions)\n"
            '    printf \'%s\\n\' \'{"choices":[{"message":{"content":"OK"}}]}\' '
            '>"$output"\n'
            '    printf "%s" "200" ;;\n'
            "  */serving-endpoints/anthropic/v1/messages)\n"
            '    if [ "${FAKE_NATIVE_STATUS:-200}" = "200" ]; then\n'
            '      printf \'%s\\n\' \'{"type":"message"}\' >"$output"\n'
            "    else\n"
            '      printf \'%s\\n\' \'{"message":"native route failed"}\' >"$output"\n'
            "    fi\n"
            '    printf "%s" "${FAKE_NATIVE_STATUS:-200}" ;;\n'
            '  *) printf "unexpected curl URL: %s\\n" "$url" >&2; exit 1 ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                "FAKE_NATIVE_STATUS": native_status,
                "FAKE_PAT_VALIDATION_STATUS": pat_validation_status,
                "CONFIGURE_CLAUDE_CODE": configure_claude_code,
                "HOME": str(temp_path / "home"),
                "RUN_AGENT": "0",
            }
        )
        environment.pop("PYTHON", None)

        result = subprocess.run(
            ["bash", str(copied_setup)],
            cwd=temp_path,
            capture_output=True,
            text=True,
            env=environment,
        )
        env_text = (
            (temp_path / ".env").read_text(encoding="utf-8")
            if (temp_path / ".env").exists()
            else None
        )
        settings_path = temp_path / "home" / ".claude" / "settings.json"
        settings_text = (
            settings_path.read_text(encoding="utf-8")
            if settings_path.exists()
            else None
        )
        return result, env_text, settings_text


class WorkspaceSetupTests(unittest.TestCase):
    def test_agent_sample_remains_opt_in(self) -> None:
        script = WORKSPACE_SETUP.read_text(encoding="utf-8")

        self.assertIn('RUN_AGENT="${RUN_AGENT:-0}"', script)
        self.assertIn("set RUN_AGENT=1 to run the optional sample", script)

    def test_setup_does_not_require_venv_by_default(self) -> None:
        result, env_text, settings_text = run_workspace_setup_without_venv()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(env_text)
        self.assertIn("DATABRICKS_TOKEN=dapi-test-token", env_text)
        self.assertIsNotNone(settings_text)
        self.assertIn(
            '"model": "databricks-claude-opus-5[1m]"',
            settings_text,
        )
        self.assertIn("Claude Code is ready", result.stdout)

    def test_native_failure_does_not_report_claude_code_ready(self) -> None:
        result, env_text, settings_text = run_workspace_setup_without_venv(
            native_status="400"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(env_text)
        self.assertIsNone(settings_text)
        self.assertIn("Claude Code is not ready for this model", result.stdout)

    def test_existing_pat_is_reused_through_serving_api_validation(self) -> None:
        existing_env = (
            "DATABRICKS_HOST=https://adb-1234567890123456.7.azuredatabricks.net\n"
            "DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-5\n"
            "DATABRICKS_TOKEN=dapi-existing-token\n"
        )

        result, env_text, _ = run_workspace_setup_without_venv(
            existing_env=existing_env
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(env_text)
        self.assertIn("DATABRICKS_TOKEN=dapi-existing-token", env_text)
        self.assertIn("reusing the valid PAT already stored in .env", result.stdout)

    def test_invalid_existing_pat_is_replaced(self) -> None:
        existing_env = (
            "DATABRICKS_HOST=https://adb-1234567890123456.7.azuredatabricks.net\n"
            "DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-5\n"
            "DATABRICKS_TOKEN=dapi-expired-token\n"
        )

        result, env_text, _ = run_workspace_setup_without_venv(
            existing_env=existing_env,
            pat_validation_status="401",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(env_text)
        self.assertIn("DATABRICKS_TOKEN=dapi-test-token", env_text)
        self.assertIn(
            "the PAT in .env is invalid or expired; creating a replacement",
            result.stdout,
        )

    def test_unexpected_pat_validation_failure_stops_setup(self) -> None:
        existing_env = (
            "DATABRICKS_HOST=https://adb-1234567890123456.7.azuredatabricks.net\n"
            "DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-5\n"
            "DATABRICKS_TOKEN=dapi-existing-token\n"
        )

        result, _, _ = run_workspace_setup_without_venv(
            existing_env=existing_env,
            pat_validation_status="503",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not verify the PAT in .env (HTTP 503)", result.stderr)

    def test_pat_reuse_validation_uses_serving_api(self) -> None:
        script = WORKSPACE_SETUP.read_text(encoding="utf-8")

        self.assertIn('"$HOST/api/2.0/serving-endpoints"', script)
        self.assertNotIn("/api/2.0/preview/scim/v2/Me", script)

    def test_claude_code_configuration_can_be_disabled(self) -> None:
        result, _, settings_text = run_workspace_setup_without_venv(
            configure_claude_code="0"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(settings_text)
        self.assertIn("CONFIGURE_CLAUDE_CODE=0", result.stdout)

    def test_invalid_claude_settings_report_partial_completion(self) -> None:
        result, env_text, settings_text = run_workspace_setup_without_venv(
            existing_settings="{invalid"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIsNotNone(env_text)
        self.assertEqual(settings_text, "{invalid")
        self.assertIn("Done. Workspace:", result.stdout)
        self.assertIn(
            "workspace and model are ready, but Claude Code settings",
            result.stdout,
        )
        self.assertIn(
            "Fix the existing Claude Code settings",
            result.stderr,
        )


if __name__ == "__main__":
    unittest.main()
