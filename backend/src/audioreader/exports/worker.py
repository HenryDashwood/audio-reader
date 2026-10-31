"""Local-file-only renderer child. Receives no remote image-fetching work."""

import json
import sys
from pathlib import Path

from audioreader.exports import assets
from audioreader.exports.html_to_typst import convert, quote
from audioreader.exports.service import MAX_PDF_BYTES


def limits() -> None:
    import resource

    resource.setrlimit(resource.RLIMIT_CPU, (18, 18))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_PDF_BYTES, MAX_PDF_BYTES))
    if sys.platform == "linux":
        # One Rayon thread keeps address-space use predictable. Limiting the
        # child protects the API from an unexpectedly expensive layout.
        resource.setrlimit(resource.RLIMIT_AS, (768 * 1024 * 1024, 768 * 1024 * 1024))


def run(root: Path) -> int:
    import typst

    payload = json.loads((root / "input.json").read_text())
    body, asset_warnings = assets.prepare(
        payload["html"], payload.get("link") or "", payload["downloads"], root, payload["title"]
    )
    converted = convert(body, asset_root=root)
    package = Path(__file__).parent
    preamble = (package / "article.typ").read_text()
    title = payload["title"][:500]
    preamble += "\n#set document(title: " + quote(title) + ")\n#heading(level: 1, " + quote(title) + ")\n"
    byline = list(
        dict.fromkeys(p for p in [payload.get("author"), payload.get("publication"), payload.get("published")] if p)
    )
    if byline:
        preamble += '#par(text(size: 9pt, fill: rgb("#555555"), ' + quote(" · ".join(byline)) + "))\n"
    if link := assets.web_link(payload.get("link")):
        preamble += "#par(link(" + quote(link) + ', text(size:9pt, "Original source")))\n'
    input_file = root / "article.typ"
    input_file.write_text(preamble + converted.source)
    pdf, diagnostics = typst.compile_with_warnings(
        str(input_file),
        root=str(root),
        font_paths=[str(package / "fonts")],
        ignore_system_fonts=True,
        package_path=str(root),
        package_cache_path=str(root),
    )
    if not isinstance(pdf, bytes) or len(pdf) > MAX_PDF_BYTES:
        raise ValueError("Invalid export size")
    (root / "article.pdf").write_bytes(pdf)
    return asset_warnings + len(converted.warnings) + len(diagnostics)


def main() -> None:
    try:
        limits()
        warnings = run(Path(sys.argv[1]))
        print(json.dumps({"warnings": warnings}))
    except Exception:
        # Rich compiler errors can contain the private article. The parent
        # receives a failure code and supplies a safe, actionable message.
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
