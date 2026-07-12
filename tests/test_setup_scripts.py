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


def embedded_python_blocks() -> list[str]:
    return PYTHON_HEREDOC.findall(BASH_SETUP.read_text(encoding="utf-8"))


def native_response_check() -> str:
    script = BASH_SETUP.read_text(encoding="utf-8")
    marker = 'printf "%s" "$NATIVE_BODY" | "$PYTHON" -c \''
    start = script.index(marker) + len(marker)
    end = script.index("\n'", start)
    return script[start:end].lstrip("\n")


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
        ):
            self.assertNotIn(removed_key, env)


if __name__ == "__main__":
    unittest.main()
