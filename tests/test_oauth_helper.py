import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OAUTH_HELPER = ROOT / "scripts" / "get_databricks_oauth_token.sh"


@unittest.skipUnless(
    shutil.which("bash") and shutil.which("python3"),
    "bash and Python 3 are required",
)
class OAuthHelperTests(unittest.TestCase):
    def run_helper(self, token_response: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            fake_bin = Path(temp_dir)
            fake_databricks = fake_bin / "databricks"
            fake_databricks.write_text(
                "#!/usr/bin/env bash\n"
                "set -eu\n"
                'test "$*" = "auth token --profile test-profile --output json"\n'
                f"printf '%s\\n' '{token_response}'\n",
                encoding="utf-8",
            )
            fake_databricks.chmod(0o755)

            environment = os.environ.copy()
            environment.update(
                {
                    "DATABRICKS_CONFIG_PROFILE": "test-profile",
                    "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                }
            )
            return subprocess.run(
                ["bash", str(OAUTH_HELPER)],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )

    def test_prints_only_access_token(self) -> None:
        result = self.run_helper(
            '{"access_token":"oauth-test-token","token_type":"Bearer"}'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "oauth-test-token\n")

    def test_fails_when_access_token_is_missing(self) -> None:
        result = self.run_helper('{"token_type":"Bearer"}')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not return access_token", result.stderr)


if __name__ == "__main__":
    unittest.main()
