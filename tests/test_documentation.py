import html
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
MARKDOWN_FILES = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]
LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")
TAG_RE = re.compile(r"<[^>]+>")


def github_slug(text: str) -> str:
    text = TAG_RE.sub("", html.unescape(text)).strip().lower()
    characters = [
        character
        for character in text
        if character.isalnum() or character in {"_", "-", " "}
    ]
    return "".join(characters).replace(" ", "-")


def markdown_anchors(path: Path) -> set[str]:
    counts: dict[str, int] = {}
    anchors: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if not match:
            continue
        base = github_slug(match.group(1))
        count = counts.get(base, 0)
        counts[base] = count + 1
        anchors.add(base if count == 0 else f"{base}-{count}")
    return anchors


def fenced_blocks(path: Path) -> list[tuple[str, str, int]]:
    blocks: list[tuple[str, str, int]] = []
    language: str | None = None
    start_line = 0
    lines: list[str] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if line.startswith("```"):
            if language is None:
                language = line[3:].strip().lower()
                start_line = line_number
                lines = []
            else:
                blocks.append((language, "\n".join(lines) + "\n", start_line))
                language = None
                lines = []
            continue
        if language is not None:
            lines.append(line)

    if language is not None:
        raise AssertionError(
            f"{path.relative_to(ROOT)}:{start_line}: unclosed code fence"
        )
    return blocks


class DocumentationTests(unittest.TestCase):
    def test_readme_leads_with_existing_workspace_quickstart(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        quickstart_heading = "## 1. 5분 연결: 기존 workspace에 Claude Code 연결"
        workspace_heading = "## 2. Workspace가 없다면"

        self.assertIn(quickstart_heading, readme)
        self.assertIn(workspace_heading, readme)
        self.assertLess(
            readme.index(quickstart_heading), readme.index(workspace_heading)
        )
        self.assertLess(
            readme.index("### 1. Databricks API부터 확인"),
            readme.index("### 2. Claude Code에서 확인"),
        )
        self.assertLess(
            readme.index("### 2. Claude Code에서 확인"),
            readme.index("### 3. 다중 모델 설정 저장"),
        )

    def test_all_guides_are_linked_from_readme(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        docs_dir = (ROOT / "docs").resolve()
        linked_guides = set()

        for raw_target in LINK_RE.findall(readme):
            target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            file_part = target.partition("#")[0]
            linked_path = (ROOT / unquote(file_part)).resolve()
            if linked_path.parent == docs_dir and linked_path.suffix.lower() == ".md":
                linked_guides.add(linked_path)

        self.assertEqual(linked_guides, set(docs_dir.glob("*.md")))

    def test_claude_guide_covers_required_configuration(self) -> None:
        guide_path = ROOT / "docs" / "claude-code-databricks.md"
        guide = guide_path.read_text(encoding="utf-8")

        for required_text in (
            "~/.claude/settings.json",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
            "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
            "ANTHROPIC_CUSTOM_MODEL_OPTION",
            "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
            "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
            "WebSearch",
            "apiKeyHelper",
            "scripts/get_databricks_oauth_token.sh",
            "Get-DatabricksOAuthToken.ps1",
            "claudeCode.environmentVariables",
            "/status",
            "Opus 5 (1M context)",
            "Opus 4.8 (1M context)",
            "Sonnet 5 (1M context)",
            "Sonnet 4.6 (1M context)",
            "Haiku 4.5 (200K context)",
            "## 2. Databricks API부터 검증",
            "## 4. 다중 모델 영구 설정",
            "## 5. 선택: 단일 모델 최소 설정",
        ):
            self.assertIn(required_text, guide)

        json_settings = [
            json.loads(code)
            for language, code, _ in fenced_blocks(guide_path)
            if language == "json"
        ]
        settings = next(
            value
            for value in json_settings
            if value.get("model") == "databricks-claude-sonnet-5[1m]"
        )
        self.assertNotIn("availableModels", settings)
        self.assertNotIn("enforceAvailableModels", settings)
        self.assertNotIn("modelOverrides", settings)
        self.assertEqual(
            settings["env"]["ANTHROPIC_DEFAULT_OPUS_MODEL"],
            "databricks-claude-opus-5[1m]",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"],
            "Opus 5 (1M context)",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_DEFAULT_FABLE_MODEL"],
            "databricks-claude-opus-4-8[1m]",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"],
            "Opus 4.8 (1M context)",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_DEFAULT_SONNET_MODEL"],
            "databricks-claude-sonnet-5[1m]",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_CUSTOM_MODEL_OPTION"],
            "databricks-claude-sonnet-4-6[1m]",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"],
            "Sonnet 4.6 (1M context)",
        )

        minimal_settings = next(
            value
            for value in json_settings
            if value.get("model") == "databricks-claude-sonnet-4-6[1m]"
            and "ANTHROPIC_DEFAULT_OPUS_MODEL" not in value.get("env", {})
        )
        self.assertEqual(
            set(minimal_settings["env"]),
            {
                "ANTHROPIC_BASE_URL",
                "ANTHROPIC_AUTH_TOKEN",
                "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
            },
        )

    def test_claude_guide_validates_before_persisting(self) -> None:
        guide = (ROOT / "docs" / "claude-code-databricks.md").read_text(
            encoding="utf-8"
        )

        api_heading = "## 2. Databricks API부터 검증"
        cli_heading = "## 3. Claude Code에서 임시 검증"
        settings_heading = "## 4. 다중 모델 영구 설정"

        self.assertLess(guide.index(api_heading), guide.index(cli_heading))
        self.assertLess(guide.index(cli_heading), guide.index(settings_heading))

    def test_local_links_and_anchors_resolve(self) -> None:
        anchor_cache = {path: markdown_anchors(path) for path in MARKDOWN_FILES}
        checked = 0

        for path in MARKDOWN_FILES:
            for raw_target in LINK_RE.findall(path.read_text(encoding="utf-8")):
                target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
                if target.startswith(("http://", "https://", "mailto:")):
                    continue

                checked += 1
                file_part, separator, fragment = target.partition("#")
                linked_path = (
                    path
                    if not file_part
                    else (path.parent / unquote(file_part)).resolve()
                )
                with self.subTest(path=path.relative_to(ROOT), target=target):
                    self.assertTrue(linked_path.exists(), "link target does not exist")
                    if separator and fragment and linked_path.suffix.lower() == ".md":
                        anchors = anchor_cache.setdefault(
                            linked_path, markdown_anchors(linked_path)
                        )
                        self.assertIn(
                            unquote(fragment).lower(),
                            anchors,
                            "Markdown anchor does not exist",
                        )
        self.assertGreater(checked, 0)

    def test_python_and_json_snippets_parse(self) -> None:
        checked = 0
        for path in MARKDOWN_FILES:
            for language, code, line_number in fenced_blocks(path):
                with self.subTest(
                    path=path.relative_to(ROOT),
                    line=line_number,
                    language=language,
                ):
                    if language in {"python", "py"}:
                        checked += 1
                        compile(code, f"{path}:{line_number}", "exec")
                    elif language == "json":
                        checked += 1
                        json.loads(code)
        self.assertGreater(checked, 0)

    @unittest.skipUnless(shutil.which("bash"), "bash is required")
    def test_bash_snippets_parse(self) -> None:
        checked = 0
        for path in MARKDOWN_FILES:
            for language, code, line_number in fenced_blocks(path):
                if language not in {"bash", "sh", "shell"}:
                    continue
                checked += 1
                result = subprocess.run(
                    ["bash", "-n"],
                    input=code,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                with self.subTest(path=path.relative_to(ROOT), line=line_number):
                    self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(checked, 0)


if __name__ == "__main__":
    unittest.main()
