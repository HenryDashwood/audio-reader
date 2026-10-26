import pytest
from lxml import html as lhtml

from audioreader.documents import maths, normalise


def prepare(equation):
    return normalise.prepare(
        {"html": "<p>Here is the equation.</p>" + equation + "<p>Continue reading here.</p>"}, "Maths", capped=False
    )[1:]


@pytest.mark.parametrize("display", ["inline", "block"])
def test_datalab_latex_becomes_native_mathml_with_structural_speech(display):
    html, speech = prepare(rf'<math display="{display}">\frac{{a}}{{\sqrt{{b_2}}}}</math>')
    page = lhtml.fromstring(html)
    assert len(page.xpath(".//math/mrow/mfrac")) == 1
    assert page.xpath(".//msqrt//msub")
    assert bool(page.xpath('.//span[@class="formula"]')) == (display == "block")
    assert "start fraction a divided by square root of b subscript 2 end subscript end root end fraction" in speech
    assert r"\frac" not in html
    assert "here." in speech


@pytest.mark.parametrize(
    "source", [r"\unknown{x}", r"\frac{a}{", r"\begin{unknown}x\end{unknown}", "{" * 65 + "x" + "}" * 65, "x" * 8193]
)
def test_unsupported_formula_keeps_visible_source_and_explicit_spoken_fallback(source):
    html, speech = prepare(f'<math display="block">{source}</math>')
    page = lhtml.fromstring(html)
    assert page.xpath(".//code")[0].text == source
    assert not page.xpath(".//math")
    assert maths.SPEECH_FALLBACK in speech
    assert source not in speech


def test_display_delimiters_and_aligned_rows():
    html, speech = prepare(r'<math display="block">$$\begin{aligned}a&amp;=b\\c&amp;=d\end{aligned}$$</math>')
    page = lhtml.fromstring(html)
    assert len(page.xpath(".//mtable/mtr")) == 2
    assert "&amp;" not in html
    assert maths.SPEECH_FALLBACK in speech  # No invented reading of aligned equations.


def test_existing_mathml_and_annotations_are_not_reconverted_or_flattened():
    html, speech = prepare(
        "<math><semantics><mfrac><mi>a</mi><mi>b</mi></mfrac>"
        "<annotation>private source</annotation></semantics></math>"
    )
    assert "<mfrac>" in html
    assert "start fraction a divided by b end fraction" in speech
    assert "private source" not in html + speech


def test_inline_spacing_and_existing_delimited_math():
    html, speech = prepare(
        r"<p>Let<math>x^2</math>equal<math>\frac{1}{2}</math>today.</p><p>Also $$\sqrt{a}$$ here.</p>"
    )
    assert "Let x superscript 2 end superscript equal start fraction 1 divided by 2 end fraction today." in speech
    assert "square root of a end root" in speech
    assert "<msqrt>" in html


def test_math_cannot_introduce_active_content():
    html, speech = prepare(
        r"<math>\text{&lt;script&gt;alert(1)&lt;/script&gt;}</math>"
        '<math><img src="https://tracker.example/x" onerror="evil()"></math>'
    )
    page = lhtml.fromstring(html)
    assert not page.xpath(".//script | .//img | .//*[@onerror]")
    assert "https://tracker.example" not in html
    assert maths.SPEECH_FALLBACK in speech


def test_complex_mathml_narration_is_explicit_not_flattened():
    html, speech = prepare("<math><munder><mo>∑</mo><mi>i</mi></munder><mi>x</mi></math>")
    assert "<munder>" in html
    assert maths.SPEECH_FALLBACK in speech
    assert "∑ix" not in speech


def test_real_arxiv_datalab_fixture_matches_both_native_reader_fixtures():
    from pathlib import Path

    root = Path(__file__).resolve().parents[2]
    source = (root / "backend/tests/fixtures/pdf/attention-datalab.html").read_text().strip()
    _, html, speech = normalise.prepare({"html": source}, "Attention", capped=False)
    page = lhtml.fromstring(html)
    assert len(page.xpath(".//mfrac")) == 1
    assert len(page.xpath(".//msqrt")) == 1
    assert len(page.xpath(".//msup")) == 1
    assert not page.xpath(f'.//span[@class="{maths.FALLBACK_CLASS}"]')
    assert "start fraction Q K superscript T end superscript" in speech
    for path in ["ios/HearfulTests/Fixtures/PDFMath.html", "android/app/src/androidTest/assets/pdf_math.html"]:
        assert (root / path).read_text().strip() == html


@pytest.mark.parametrize("body", ["<msqrt><mi>x</mi></msqrt>", "<mtable><mtr><mtd><mi>x</mi></mtd></mtr></mtable>"])
def test_real_mathml_with_root_or_table_is_preserved(body):
    html, _ = prepare(f"<math>{body}</math>")
    assert body in html
