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
    def test_readme_leads_with_connection_flows(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        flows_heading = "## 1. 연결 흐름 선택"
        quickstart_heading = "## 2. 5분 연결: 기존 Databricks workspace"
        workspace_heading = "## 3. Databricks workspace가 없다면"

        self.assertIn(flows_heading, readme)
        self.assertIn(quickstart_heading, readme)
        self.assertIn(workspace_heading, readme)
        self.assertLess(
            readme.index(flows_heading), readme.index(quickstart_heading)
        )
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
        self.assertIn("scripts/configure_claude_code.py", readme)

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

    def test_readme_exposes_two_claude_code_connection_flows(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        flows = readme[readme.index("## 1. 연결 흐름 선택") :]

        expected_order = (
            "### Azure Databricks Claude",
            "docs/claude-code-databricks.md",
            "docs/existing-litellm-databricks.md",
            "### Microsoft Foundry GPT-5.6",
            "docs/claude-code-foundry-local.md",
            "docs/existing-litellm-foundry.md",
        )
        positions = [flows.index(value) for value in expected_order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn(
            "로컬과 기존 서버 흐름 모두 LiteLLM의 Anthropic Messages 변환을 사용합니다",
            flows,
        )
        self.assertIn(
            "개인 PC의 LiteLLM을 통해 Foundry를 호출",
            flows,
        )
        self.assertIn(
            "조직의 LiteLLM 서버를 통해 Foundry를 호출",
            flows,
        )
        self.assertIn(
            "각 backend에서 필요한 선택지 하나만 실행합니다",
            flows,
        )
        self.assertIn(
            "`env` 값은 shell 환경변수보다 우선",
            flows,
        )

    def test_core_guides_have_explicit_scope_and_completion(self) -> None:
        guides = {
            "claude-code-databricks.md": (
                "# Claude Code를 Azure Databricks Claude에 직접 연결하기"
            ),
            "existing-litellm-databricks.md": (
                "# 기존 LiteLLM을 통해 Claude Code를 Azure Databricks에 연결하기"
            ),
            "claude-code-foundry-local.md": (
                "# 로컬 LiteLLM을 통해 Claude Code를 Microsoft Foundry GPT-5.6에 연결하기"
            ),
            "existing-litellm-foundry.md": (
                "# 기존 LiteLLM을 통해 Claude Code를 Microsoft Foundry GPT-5.6에 연결하기"
            ),
        }

        for filename, title in guides.items():
            guide = (ROOT / "docs" / filename).read_text(encoding="utf-8")
            with self.subTest(filename=filename):
                self.assertTrue(guide.startswith(title))
                self.assertIn("**완료 기준:**", guide)

        for filename in (
            "claude-code-databricks.md",
            "claude-code-foundry-local.md",
        ):
            guide = (ROOT / "docs" / filename).read_text(encoding="utf-8")
            with self.subTest(filename=filename):
                self.assertIn("shell 환경변수보다 우선", guide)

        for filename in (
            "claude-code-foundry-local.md",
            "existing-litellm-foundry.md",
        ):
            guide = (ROOT / "docs" / filename).read_text(encoding="utf-8")
            with self.subTest(filename=filename):
                self.assertIn("**필수 경로:**", guide)

    def test_claude_guide_covers_required_configuration(self) -> None:
        guide_path = ROOT / "docs" / "claude-code-databricks.md"
        guide = guide_path.read_text(encoding="utf-8")

        for required_text in (
            "~/.claude/settings.json",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
            "WebSearch",
            "apiKeyHelper",
            "scripts/configure_claude_code.py",
            "scripts/get_databricks_oauth_token.sh",
            "Get-DatabricksOAuthToken.ps1",
            "claudeCode.environmentVariables",
            "/status",
            "--scope project",
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
            if value.get("model") == "databricks-claude-opus-5[1m]"
            and "ANTHROPIC_DEFAULT_OPUS_MODEL" in value.get("env", {})
        )
        self.assertNotIn("availableModels", settings)
        self.assertNotIn("enforceAvailableModels", settings)
        self.assertNotIn("modelOverrides", settings)
        self.assertEqual(
            settings["env"]["ANTHROPIC_DEFAULT_OPUS_MODEL"],
            "databricks-claude-opus-5[1m]",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_DEFAULT_FABLE_MODEL"],
            "databricks-claude-opus-4-8[1m]",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_DEFAULT_SONNET_MODEL"],
            "databricks-claude-sonnet-5[1m]",
        )
        self.assertEqual(
            settings["env"]["ANTHROPIC_CUSTOM_MODEL_OPTION"],
            "databricks-claude-sonnet-4-6[1m]",
        )
        minimal_settings = next(
            value
            for value in json_settings
            if value.get("model") == "databricks-claude-opus-5[1m]"
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
        oauth_heading = "## 7. PAT 대신 OAuth U2M"
        vscode_heading = "## 8. VS Code extension 사용 시"
        troubleshooting_heading = "## 문제 해결"

        self.assertLess(guide.index(api_heading), guide.index(cli_heading))
        self.assertLess(guide.index(cli_heading), guide.index(settings_heading))
        self.assertLess(guide.index(oauth_heading), guide.index(vscode_heading))
        self.assertLess(
            guide.index(vscode_heading), guide.index(troubleshooting_heading)
        )
        self.assertLess(
            guide.index("scripts/configure_claude_code.py"),
            guide.index('"ANTHROPIC_DEFAULT_OPUS_MODEL"'),
        )

    def test_default_model_is_opus_5_across_guides_and_setup(self) -> None:
        paths = (
            ROOT / ".env.example",
            ROOT / "README.md",
            ROOT / "docs" / "azure-databricks-setup.md",
            ROOT / "scripts" / "setup_databricks_claude.sh",
        )

        for path in paths:
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertIn("databricks-claude-opus-5", text)
                self.assertNotIn(
                    "DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8",
                    text,
                )

    def test_powershell_bootstrap_covers_full_customer_path(self) -> None:
        script = (ROOT / "scripts" / "Setup-DatabricksClaude.ps1").read_text(
            encoding="utf-8"
        )

        for required_text in (
            "databricks-claude-opus-5",
            "'databricks', 'workspace', 'create'",
            "/api/2.0/token/create",
            "/serving-endpoints/anthropic/v1/messages",
            "anthropic-version",
            "Protect-File",
            "configure_claude_code.py",
            "'project'",
            "multi-model settings configured",
            "Claude Code is ready",
        ):
            self.assertIn(required_text, script)

    def test_existing_litellm_databricks_separates_auth_methods(self) -> None:
        guide = (
            ROOT / "docs" / "existing-litellm-databricks.md"
        ).read_text(encoding="utf-8")

        for required_text in (
            "이 리포에는 `config.yaml`이 없습니다",
            "고객의 기존 LiteLLM",
            "서버가 실제로 읽는 설정 파일",
            "새 `config.yaml`을 만들지 말고",
            "다음 두 방식 중 **하나만** 선택",
            "### 방법 A: OAuth M2M",
            "### 방법 B: PAT",
            "OAuth M2M → PAT → Databricks SDK 기본 인증",
            "Route-optimized endpoint는",
            "`system.ai` schema 또는 대상 모델의 `EXECUTE`",
            "endpoint의 `CAN QUERY`",
            "M2M과 PAT 모두 아래 YAML을 그대로 사용",
            "YAML에 `api_key`를 추가할 필요가 없습니다",
            "서로 다른 workspace credential을 섞지",
        ):
            self.assertIn(required_text, guide)

        self.assertEqual(guide.count("DATABRICKS_API_KEY=<databricks-pat>"), 1)
        self.assertNotIn(
            "api_key: os.environ/DATABRICKS_API_KEY",
            guide,
        )
        self.assertNotIn(
            "master_key: os.environ/LITELLM_MASTER_KEY",
            guide,
        )

    def test_existing_litellm_uses_managed_identity_for_foundry(self) -> None:
        guide = (ROOT / "docs" / "existing-litellm-foundry.md").read_text(
            encoding="utf-8"
        )
        local_guide = (ROOT / "docs" / "claude-code-foundry-local.md").read_text(
            encoding="utf-8"
        )

        for required_text in (
            "## 2. LiteLLM host에 managed identity 연결",
            "Cognitive Services OpenAI User",
            "FOUNDRY_GPT_AZURE_SCOPE=https://ai.azure.com/.default",
            "enable_azure_ad_token_refresh: true",
            "ManagedIdentityCredential",
            "managed identity token acquired",
            "LiteLLM process 전체에",
            "AZURE_OPENAI_API_KEY",
            "922,000 tokens",
            "CLAUDE_CODE_USE_FOUNDRY",
            "ANTHROPIC_FOUNDRY_RESOURCE",
            "이 리포는 LiteLLM이나 Foundry resource를 설치하지 않습니다",
            "`scripts/configure_claude_code.py`는 Databricks workspace URL",
            '"model": "foundry-gpt-5.6-sol"',
            "claudeCode.environmentVariables",
            "claude-code-foundry-local.md",
        ):
            self.assertIn(required_text, guide)

        for required_text in (
            "Claude Code는 Foundry GPT-5.6의 OpenAI Responses API를 직접 호출하지 않습니다",
            "Cognitive Services OpenAI User",
            'AZURE_CREDENTIAL="AzureCliCredential"',
            "enable_azure_ad_token_refresh: true",
            "azure/responses/<sol-deployment-name>",
            "ANTHROPIC_BASE_URL",
            "secrets.token_urlsafe(32)",
            "foundry-gpt-5.6-terra",
            "foundry-gpt-5.6-luna",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
            "claude --model",
            "existing-litellm-foundry.md",
        ):
            self.assertIn(required_text, local_guide)

        json_settings = [
            json.loads(code)
            for language, code, _ in fenced_blocks(
                ROOT / "docs" / "existing-litellm-foundry.md"
            )
            if language == "json"
        ]
        gateway_env = json_settings[0]["env"]
        self.assertEqual(json_settings[0]["model"], "foundry-gpt-5.6-sol")
        self.assertIn("ANTHROPIC_BASE_URL", gateway_env)
        self.assertIn("ANTHROPIC_AUTH_TOKEN", gateway_env)
        self.assertNotIn("CLAUDE_CODE_USE_FOUNDRY", gateway_env)
        self.assertNotIn("ANTHROPIC_FOUNDRY_RESOURCE", gateway_env)
        self.assertNotIn("ANTHROPIC_FOUNDRY_BASE_URL", gateway_env)

        self.assertNotIn(
            "api_key: os.environ/FOUNDRY_GPT_API_KEY",
            guide,
        )
        self.assertNotIn(
            "client_secret: os.environ/AZURE_CLIENT_SECRET",
            guide,
        )
        self.assertNotIn("Azure OpenAI", guide)
        self.assertNotIn("Azure Foundry", guide)

        databricks_guide = (
            ROOT / "docs" / "existing-litellm-databricks.md"
        ).read_text(encoding="utf-8")
        self.assertNotIn("Microsoft Foundry", databricks_guide)
        self.assertNotIn("foundry-gpt-5.6", databricks_guide)
        self.assertGreaterEqual(guide.count("LITELLM_KEY"), 4)
        self.assertGreaterEqual(databricks_guide.count("LITELLM_KEY"), 3)

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
