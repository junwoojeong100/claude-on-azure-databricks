import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_SETUP = ROOT / "scripts" / "setup_databricks_claude.sh"


def run_workspace_setup_without_venv():
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
            'url=""\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  case "$1" in\n'
            '    -o) output="$2"; shift 2 ;;\n'
            '    http://*|https://*) url="$1"; shift ;;\n'
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            'case "$url" in\n'
            "  */api/2.0/token/create)\n"
            "    printf '%s\\n' '{\"token_value\":\"dapi-test-token\"}' ;;\n"
            "  */api/2.0/serving-endpoints)\n"
            "    printf '%s\\n' "
            '\'{"endpoints":[{"name":"databricks-claude-opus-4-8",'
            '"state":{"ready":"READY"}}]}\' ;;\n'
            "  */serving-endpoints/chat/completions)\n"
            '    printf \'%s\\n\' \'{"choices":[{"message":{"content":"OK"}}]}\' '
            '>"$output"\n'
            '    printf "%s" "200" ;;\n'
            "  */serving-endpoints/anthropic/v1/messages)\n"
            '    printf \'%s\\n\' \'{"type":"message"}\' >"$output"\n'
            '    printf "%s" "200" ;;\n'
            '  *) printf "unexpected curl URL: %s\\n" "$url" >&2; exit 1 ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
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
        return result, env_text


class WorkspaceSetupTests(unittest.TestCase):
    def test_agent_sample_remains_opt_in(self) -> None:
        script = WORKSPACE_SETUP.read_text(encoding="utf-8")

        self.assertIn('RUN_AGENT="${RUN_AGENT:-0}"', script)
        self.assertIn("set RUN_AGENT=1 to run the optional sample", script)

    def test_setup_does_not_require_venv_by_default(self) -> None:
        result, env_text = run_workspace_setup_without_venv()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(env_text)
        self.assertIn("DATABRICKS_TOKEN=dapi-test-token", env_text)


if __name__ == "__main__":
    unittest.main()
