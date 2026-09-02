"""LaTeX in an article, set as MathML for the reader."""

from audioreader.feeds.articles import rendered, sanitised
from audioreader.latex import with_mathml


def read(html: str) -> str:
    """The article as the reader is given it. Never empty, for these."""
    result = rendered(html)
    assert result is not None
    return result


class TestFindingMaths:
    def test_display_maths_becomes_a_block_formula(self):
        html = with_mathml(r"<p>$$ \frac{QK^T}{\sqrt{d_k}} $$</p>")

        assert 'display="block"' in html
        assert "<mfrac>" in html
        assert "$" not in html

    def test_inline_maths_stays_in_its_sentence(self):
        html = with_mathml("<p>the embedding size $d$ is 4</p>")

        assert html.startswith("<p>the embedding size <math")
        assert html.endswith("</math> is 4</p>")
        assert 'display="inline"' in html

    def test_the_other_two_delimiters_are_understood(self):
        assert "<msup>" in with_mathml(r"<p>\(x^2\)</p>")
        assert 'display="block"' in with_mathml(r"<p>\[x^2\]</p>")

    def test_a_row_break_the_feed_ate_is_put_back(self):
        # The site's own page has `\\` here; its feed has `\`, and every row
        # of the equation lands on one unreadably long line.
        eaten = with_mathml(r"<p>$$ \begin{align*} a &amp;= b \ &amp;= c \end{align*} $$</p>")
        intact = with_mathml(r"<p>$$ \begin{align*} a &amp;= b \\ &amp;= c \end{align*} $$</p>")

        assert eaten.count("<mtr>") == 2
        assert eaten == intact

    def test_a_lone_backslash_outside_an_environment_is_left_alone(self):
        assert with_mathml(r"<p>$a \ b$</p>").count("<mtr>") == 0

    def test_entities_are_unescaped_before_the_conversion(self):
        # `&` aligns the rows of an align block, and reaches us as `&amp;`.
        html = with_mathml(r"<p>$$ \begin{align*} a &amp;= b \\ c &amp;= d \end{align*} $$</p>")

        assert "<mtable" in html
        assert "&amp;" not in html


class TestLeavingProseAlone:
    def test_prices_are_not_equations(self):
        text = "<p>It cost $5 and then $10 more.</p>"

        assert with_mathml(text) == text

    def test_dollars_in_code_are_left_alone(self):
        text = "<p>Run <code>echo $HOME $PATH</code> first.</p>"

        assert with_mathml(text) == text

    def test_a_lone_dollar_is_left_alone(self):
        text = "<p>A budget of $1,000 for the year.</p>"

        assert with_mathml(text) == text

    def test_a_sentence_between_two_prices_is_not_an_equation(self):
        # A real article: the closing `$` is preceded by a non-breaking
        # space, which the pattern cannot see as a space, and the whole
        # sentence was set as one MathML run too wide for the phone.
        text = (
            "<p>spent about $45M USD on data. Most of this was paid to Korean "
            "companies. The government offered each company&nbsp;$2M to buy data.</p>"
        )

        assert with_mathml(text) == text

    def test_a_sentence_between_two_prices_is_not_an_equation_without_the_entity(self):
        text = "<p>a $20M a year lab must negotiate. Second, ~$2M to buy data.</p>"

        assert with_mathml(text) == text

    def test_a_range_of_prices_is_not_an_equation(self):
        for text in [
            "<p>somewhere between $300M-$500M a year.</p>",
            "<p>somewhere between $300M–$500M a year.</p>",
            "<p>either $5/$10 a month.</p>",
            "<p>a $5$ note.</p>",
        ]:
            assert with_mathml(text) == text, text

    def test_short_maths_beginning_with_a_number_still_counts(self):
        assert "<math" in with_mathml(r"<p>for $2 \times 3$ cells</p>")
        assert "<msup>" in with_mathml(r"<p>about $10^{-3}$ of them</p>")
        assert "<math" in with_mathml("<p>the sum $1 + 1$ is</p>")

    def test_words_inside_a_text_command_are_still_maths(self):
        html = with_mathml(r"<p>so $\text{for all } x \in S$ holds</p>")

        assert "<math" in html
        assert "$" not in html

    def test_maths_the_converter_cannot_read_is_left_as_it_was(self):
        text = r"<p>$$ \begin{nonsense} \frac{ $$</p>"

        assert with_mathml(text) == text

    def test_an_article_without_maths_is_untouched(self):
        text = "<h2>A heading</h2><p>Prose with <strong>emphasis</strong>.</p>"

        assert with_mathml(text) == text


class TestRendering:
    def test_markup_smuggled_through_a_formula_does_not_survive(self):
        # Escaped in the document, as it would be by the time it is stored,
        # and unescaped again on its way into the converter — which passes
        # whatever it finds in a \text{} block straight through. So the
        # allowlist has to see the conversion's output as well as its input.
        html = read(r"<p>$\text{&lt;script&gt;steal()&lt;/script&gt;}$</p>")

        assert "<script" not in html
        assert "steal()" not in html
        assert "<math" in html

    def test_a_formula_survives_the_allowlist_intact(self):
        html = read(r"<p>$$ \frac{a}{b} $$</p>")

        assert '<math xmlns="http://www.w3.org/1998/Math/MathML" display="block">' in html
        assert "<mfrac>" in html and "<mi>a</mi>" in html

    def test_a_table_of_equations_keeps_its_alignment(self):
        html = read(r"<p>$$ \begin{align*} a &amp;= b \\ c &amp;= d \end{align*} $$</p>")

        assert "<mtable" in html
        assert "columnalign" in html

    def test_a_display_formula_gets_a_box_to_scroll_in(self):
        # WebKit will not scroll a <math> element however it is styled, so an
        # equation wider than the phone widens the whole article instead.
        assert read(r"<p>$$ \frac{a}{b} $$</p>").count('<span class="formula">') == 1

    def test_maths_in_a_sentence_is_left_in_the_run_of_it(self):
        assert 'class="formula"' not in read("<p>the embedding size $d$ is 4</p>")

    def test_mathml_a_feed_ships_itself_is_kept(self):
        html = sanitised("<p><math><mrow><mi>x</mi></mrow></math></p>")

        assert "<math><mrow><mi>x</mi></mrow></math>" in html

    def test_a_tex_annotation_is_not_left_behind_as_text(self):
        # Browsers hide it and a screen reader would read the TeX aloud.
        html = sanitised(
            "<p><math><semantics><mrow><mi>x</mi></mrow>"
            '<annotation encoding="application/x-tex">x_1</annotation></semantics></math></p>'
        )

        assert "x_1" not in html
        assert "<mi>x</mi>" in html

    def test_nothing_to_render_is_nothing(self):
        assert rendered(None) is None
        assert rendered("") is None
