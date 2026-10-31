"""Semantic conversion regressions, using only synthetic source documents."""

import unittest
from pathlib import Path

import typst

from audioreader.exports.html_to_typst import convert


class ConverterChecks(unittest.TestCase):
    def compile(self, source):
        result = convert(source)
        pdf = typst.compile(("#set text(size:11pt)\n" + result.source).encode(), ignore_system_fonts=True)
        self.assertTrue(pdf.startswith(b"%PDF"))
        return result

    def test_source_text_is_literal(self):
        self.compile('<p>#panic("This must be text") $x$ [brackets] @label \\backslash</p>')

    def test_inline_links_and_marks(self):
        result = self.compile(
            '<p>One <strong>bold</strong> <em>italic</em><br><a href="https://example.com?a=1'
            '&amp;b=2">reference</a> x<sup>2</sup> H<sub>2</sub>O</p>'
        )
        self.assertEqual(result.counts["links"], 1)

    def test_nested_lists_and_quoted_code(self):
        self.compile(
            '<blockquote><p>Quote</p></blockquote><ol start="3"><li>Third<ul><li>nested</li><'
            '/ul></li><li>Fourth</li></ol><pre>print("a")\n#panic("literal")</pre>'
        )

    def test_table_spans(self):
        self.compile(
            '<table><thead><tr><th colspan="2">Heading</th></tr></thead><tbody><tr><td rowspa'
            'n="2">A</td><td>B</td></tr><tr><td>C</td></tr></tbody></table>'
        )

    def test_equations(self):
        self.compile(
            '<math display="block"><mrow><mi>x</mi><mo>=</mo><mfrac><mroot><mi>y</mi><mn>3</m'
            "n></mroot><msqrt><mn>2</mn></msqrt></mfrac><mo>+</mo><msubsup><mi>a</mi><mi>i</m"
            "i><mn>2</mn></msubsup></mrow></math>"
        )

    def test_matrix_and_limits(self):
        self.compile(
            "<math><mrow><munderover><mo>∑</mo><mn>0</mn><mi>n</mi></munderover><mtable><mtr>"
            "<mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr><mtr><mtd><mi>c</mi></mtd><mtd><"
            "mi>d</mi></mtd></mtr></mtable></mrow></math>"
        )

    def test_unknown_content_is_preserved_and_reported(self):
        result = convert("<article><custom>Visible words</custom></article>")
        self.assertIn("Visible words", result.source)
        self.assertTrue(result.warnings)

    def test_images_cannot_read_other_files(self):
        result = convert('<p><img src="../../secret" alt="Chart"></p>')
        self.assertEqual(result.counts.get("images", 0), 0)
        self.assertTrue(result.warnings)

    def test_unsafe_link_is_not_emitted(self):
        result = convert('<a href="javascript:alert(1)">Visible</a>')
        self.assertNotIn("link(", result.source)
        self.assertIn("Visible", result.source)

    def test_svg_viewbox_survives_html_parsing(self):
        result = self.compile(
            '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 -25 1'
            '00 50"><path d="M0,-20 L50,20" stroke="black"/></svg>'
        )
        self.assertIn("viewBox", result.source)
        self.assertNotIn("viewbox", result.source)


class BroaderChecks(unittest.TestCase):
    def test_adjacent_blocks_have_separate_baselines(self):
        from io import BytesIO

        from pypdf import PdfReader

        source = convert("<p>BEFOREBLOCK</p><div>FIRSTBLOCK</div><div>SECONDBLOCK</div>")
        data = typst.compile(
            ("#set text(size:11pt)\n#set par(leading:8pt,spacing:9pt)\n" + source.source).encode(),
            ignore_system_fonts=True,
        )
        positions = {}

        def baseline(text, cm, tm, font, size):
            if text.strip() in {"BEFOREBLOCK", "FIRSTBLOCK", "SECONDBLOCK"}:
                positions[text.strip()] = tm[4] * cm[1] + tm[5] * cm[3] + cm[5]

        PdfReader(BytesIO(data)).pages[0].extract_text(visitor_text=baseline)
        self.assertGreater(positions["BEFOREBLOCK"] - positions["FIRSTBLOCK"], 11)
        self.assertGreater(positions["FIRSTBLOCK"] - positions["SECONDBLOCK"], 11)

    def pdf(self, source):
        from io import BytesIO

        from pypdf import PdfReader

        converted = convert(source)
        data, warnings = typst.compile_with_warnings(converted.source.encode(), ignore_system_fonts=True)
        self.assertFalse(warnings)
        return PdfReader(BytesIO(data)), converted

    def test_definition_list_retains_all_words_and_links(self):
        pdf, _ = self.pdf(
            '<dl><dt>Term one</dt><dd>Definition with <a href="https://example.com">reference</a></dd></dl>'
        )
        text = " ".join(p.extract_text() for p in pdf.pages)
        for token in ["Term one", "Definition", "reference"]:
            self.assertIn(token, text)
        self.assertTrue(
            any(
                a.get_object().get("/A", {}).get("/URI") == "https://example.com"
                for p in pdf.pages
                for a in p.get("/Annots", [])
            )
        )

    def test_internal_links_become_pdf_destinations(self):
        pdf, _ = self.pdf('<p id="note">Footnote</p><p><a href="#note">Jump</a></p>')
        self.assertTrue(any(a.get_object().get("/Dest") for p in pdf.pages for a in p.get("/Annots", [])))

    def test_missing_target_warns_without_dropping_link_text(self):
        pdf, c = self.pdf('<p><a href="#missing">Visible words</a></p>')
        self.assertIn("Visible words", pdf.pages[0].extract_text())
        self.assertTrue(c.warnings)

    def test_hidden_content_excluded(self):
        pdf, _ = self.pdf(
            '<p>VISIBLE</p><p hidden>SECRET1</p><div style="display: none">SECRET2</div><script>SECRET3</script>'
        )
        text = pdf.pages[0].extract_text()
        self.assertIn("VISIBLE", text)
        self.assertNotIn("SECRET", text)

    def test_malformed_numeric_attribute_does_not_abort(self):
        pdf, c = self.pdf('<ol start="wrong"><li>First</li></ol><table><tr><td colspan="wrong">Cell</td></tr></table>')
        self.assertTrue(c.warnings)
        self.assertIn("Cell", pdf.pages[0].extract_text())

    def test_list_numbering_and_reversal(self):
        pdf, _ = self.pdf(
            '<ol start="0"><li>Zero</li><li value="5">Five</li><li>Six</li></ol><ol reversed '
            'start="4"><li>Four</li><li>Three</li></ol>'
        )
        text = pdf.pages[0].extract_text()
        for word in ["0. Zero", "5. Five", "6. Six", "4. Four", "3. Three"]:
            self.assertIn(word, text)

    def test_missing_asset_is_visible_fallback(self):
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as folder:
            c = convert('<p><img src="assets/missing.png" alt="Important chart"></p>', asset_root=Path(folder))
        self.assertTrue(c.warnings)
        self.assertIn("Important chart", c.source)
        self.assertEqual(c.counts.get("images", 0), 0)

    def test_symlink_cannot_escape_bundle(self):
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "assets").mkdir()
            (root / "outside").write_text("private sample")
            (root / "assets/image.png").symlink_to(root / "outside")
            c = convert('<img src="assets/image.png" alt="Restricted">', asset_root=root)
        self.assertTrue(c.warnings)
        self.assertEqual(c.counts.get("images", 0), 0)

    def test_bad_image_data_keeps_later_content(self):
        pdf, c = self.pdf('<img src="data:image/png;base64,invalid" alt="Chart"><p>AFTER</p>')
        text = pdf.pages[0].extract_text()
        self.assertIn("Chart", text)
        self.assertIn("AFTER", text)
        self.assertTrue(c.warnings)

    def test_bcp47_language_tag_compiles(self):
        self.pdf('<p lang="en-GB">English content</p>')

    def test_formula_fences_variants_and_cancellation(self):
        self.pdf(
            '<math><mfenced open="[" close="]"><mi>x</mi><mi>y</mi></mfenced><menclose notati'
            'on="updiagonalstrike"><mi>z</mi></menclose><mi mathvariant="double-struck">R</mi'
            "></math>"
        )

    def test_mathml_bold_is_upright_and_bold_italic_stays_italic(self):
        pdf, _ = self.pdf(
            '<math><mstyle mathvariant="bold"><mi>x</mi></mstyle><mi mathvariant="bold-italic">y</mi></math>'
        )
        text = pdf.pages[0].extract_text()
        self.assertIn("𝐱", text)
        self.assertIn("𝒚", text)

    def test_deep_html_and_math_fail_boundedly(self):
        for source in [
            "<div>" * 105 + "text" + "</div>" * 105,
            "<math>" + "<mrow>" * 105 + "<mi>x</mi>" + "</mrow>" * 105 + "</math>",
        ]:
            with self.assertRaises(ValueError):
                convert(source)

    def test_oversized_html_rejected(self):
        with self.assertRaises(ValueError):
            convert("x" * (8 * 1024 * 1024 + 1))

    def test_multirow_header_and_irregular_rowspan(self):
        self.pdf(
            '<table><thead><tr><th rowspan="2">A</th><th colspan="2">B</th></tr><tr><th>C</th'
            '><th>D</th></tr></thead><tr><td rowspan="2">E</td><td>F</td></tr><tr><td>G</td><'
            "td>H</td></tr></table>"
        )
