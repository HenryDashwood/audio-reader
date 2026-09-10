import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_shipped_safari_script_matches_reviewed_sources():
    spec = importlib.util.spec_from_file_location(
        "safari_bundle", ROOT / "scripts/build_safari_capture.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert (ROOT / "ios/HearfulShare/CapturePage.js").read_text() == module.bundle()
    assert (ROOT / "ios/HearfulShare/Readability-LICENSE.txt").read_text() == (
        ROOT / "scripts/vendor/readability/LICENSE.md"
    ).read_text()
