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
