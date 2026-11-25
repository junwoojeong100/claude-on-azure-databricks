import re
import unittest
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "docs" / "guide"
SITE_URL = "https://junwoojeong100.github.io/claude-on-azure-databricks/"
PAGES = ("index.html", "databricks-direct.html", "databricks-litellm.html")
EXTERNAL = ("http://", "https://", "mailto:", "data:")
# Documented, public Azure Databricks resource (application) ID used for OAuth scopes.
PUBLIC_GUIDS = {
    "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d",
    "00000000-0000-0000-0000-000000000000",
}
SECRET_PATTERNS = {
    "Databricks PAT": re.compile(r"dapi[0-9a-f]{16,}"),
    "API key": re.compile(r"sk-[A-Za-z0-9_-]{20,}"),
    "JWT": re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\."),
    "bearer token": re.compile(r"Bearer\s+[A-Za-z0-9._-]{24,}"),
    "workspace host": re.compile(r"adb-\d{6,}\.\d+\.azuredatabricks\.net"),
}
GUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.IGNORECASE
)


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: set[str] = set()
        self.refs: list[tuple[str, str, str]] = []
        self.meta: dict[str, str] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {key: value or "" for key, value in attrs}
        if values.get("id"):
            self.ids.add(values["id"])
        for attribute in ("src", "href", "poster"):
            if values.get(attribute):
                self.refs.append((tag, attribute, values[attribute]))
        if tag == "meta":
            key = values.get("property") or values.get("name")
            if key:
                self.meta[key] = values.get("content", "")


def parse(name: str) -> PageParser:
    parser = PageParser()
    parser.feed((SITE / name).read_text(encoding="utf-8"))
    return parser


def local_target(page: str, reference: str) -> tuple[Path, str] | None:
    if reference.startswith(EXTERNAL):
        return None
    parts = urlsplit(reference)
    path = (SITE / page) if not parts.path else (SITE / unquote(parts.path)).resolve()
    return path, parts.fragment


def used_assets() -> set[Path]:
    used: set[Path] = set()
    for name in PAGES:
        page = parse(name)
        for _, _, reference in page.refs:
            target = local_target(name, reference)
            if target:
                used.add(target[0])
        image = page.meta.get("og:image", "")
        if image.startswith(SITE_URL):
            used.add((SITE / image[len(SITE_URL):]).resolve())
    return used


class GuidePagesTests(unittest.TestCase):
    def test_site_root_has_index_and_both_guides(self) -> None:
        for name in PAGES:
            self.assertTrue((SITE / name).is_file(), f"{name} is missing")
        index_links = {reference for _, _, reference in parse("index.html").refs}
        self.assertIn("databricks-direct.html", index_links)
        self.assertIn("databricks-litellm.html", index_links)

    def test_existing_litellm_path_is_linked_from_every_entry_point(self) -> None:
        target = "databricks-litellm.html#existing"
        self.assertIn("existing", parse("databricks-litellm.html").ids)
        for name in ("index.html", "databricks-direct.html"):
            with self.subTest(page=name):
                references = {reference for _, _, reference in parse(name).refs}
                self.assertIn(target, references)
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn(SITE_URL + target, readme)

    def test_local_references_and_anchors_resolve(self) -> None:
        checked = 0
        for name in PAGES:
            for tag, attribute, reference in parse(name).refs:
                target = local_target(name, reference)
                if target is None:
                    continue
                checked += 1
                path, fragment = target
                with self.subTest(page=name, reference=reference):
                    self.assertTrue(path.is_file(), f"<{tag} {attribute}> target not found")
                    if fragment and path.suffix == ".html":
                        self.assertIn(
                            unquote(fragment),
                            parse(path.name).ids,
                            "anchor does not exist",
                        )
        self.assertGreater(checked, 0)

    def test_pages_load_nothing_from_third_parties(self) -> None:
        for name in PAGES:
            for tag, attribute, reference in parse(name).refs:
                if tag in {"script", "img", "source", "video"} or attribute == "poster":
                    with self.subTest(page=name, reference=reference):
                        self.assertFalse(
                            reference.startswith(("http://", "https://")),
                            f"<{tag}> must be served from the site itself",
                        )

    def test_open_graph_image_ships_with_the_site(self) -> None:
        for name in PAGES:
            image = parse(name).meta.get("og:image", "")
            with self.subTest(page=name):
                self.assertTrue(image.startswith(SITE_URL), "og:image must be an absolute Pages URL")
                self.assertTrue((SITE / image[len(SITE_URL):]).is_file(), "og:image file is missing")

    def test_every_asset_is_referenced(self) -> None:
        used = used_assets()
        for asset in sorted((SITE / "assets").rglob("*")):
            if asset.is_file() and not asset.name.startswith("."):
                with self.subTest(asset=asset.relative_to(SITE)):
                    self.assertIn(asset.resolve(), used, "asset is not used by any page")

    def test_pages_contain_no_credentials_or_resource_ids(self) -> None:
        for name in PAGES:
            text = (SITE / name).read_text(encoding="utf-8")
            for label, pattern in SECRET_PATTERNS.items():
                with self.subTest(page=name, kind=label):
                    self.assertIsNone(pattern.search(text), f"{label} found")
            with self.subTest(page=name, kind="GUID"):
                unexpected = {g.lower() for g in GUID_RE.findall(text)} - PUBLIC_GUIDS
                self.assertFalse(unexpected, "subscription/tenant IDs must not be published")

    def test_pages_workflow_publishes_the_site_directory(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "pages.yml").read_text(encoding="utf-8")
        match = re.search(r"^\s+path:\s*(\S+)\s*$", workflow, re.MULTILINE)
        self.assertIsNotNone(match, "upload path is missing")
        self.assertEqual((ROOT / match.group(1)).resolve(), SITE.resolve())
        self.assertRegex(workflow, r"push:\s*\n\s+branches:\s*\n\s+- main")
        self.assertIn("actions/deploy-pages@", workflow)


if __name__ == "__main__":
    unittest.main()
