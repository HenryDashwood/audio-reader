from tests.newsletter_fixtures import ISSUE_HTML

from audioreader.feeds.articles import sanitised
from audioreader.newsletters.cleaning import clean_newsletter_html
from audioreader.text import article_paragraphs


def spoken(html: str) -> list[str]:
    """What the reader would actually say, after the same allowlist as any feed."""
    return article_paragraphs(sanitised(html))


class TestCleanNewsletterHtml:
    def test_keeps_the_writing(self):
        cleaned = clean_newsletter_html(ISSUE_HTML)
        paragraphs = spoken(cleaned.html)

        assert paragraphs[0] == "Things Happen"
        assert paragraphs[1].startswith("Programming note: Money Stuff will be off tomorrow")
        assert any(paragraph.startswith("Anyway, here is a company") for paragraph in paragraphs)

    def test_drops_the_hidden_preview_line(self):
        cleaned = clean_newsletter_html(ISSUE_HTML)

        assert "Preview text nobody should hear" not in cleaned.html

    def test_drops_the_footer_but_not_the_issue(self):
        cleaned = clean_newsletter_html(ISSUE_HTML)
        text = " ".join(spoken(cleaned.html))

        assert "Unsubscribe" not in text
        assert "Manage your preferences" not in text
        assert "731 Lexington Avenue" not in text
        assert "View in browser" not in text
        assert "sure thing" in text

    def test_drops_the_tracking_pixel(self):
        cleaned = clean_newsletter_html(ISSUE_HTML)

        assert "track.example.com" not in cleaned.html
        assert "<img" not in cleaned.html

    def test_keeps_a_real_picture(self):
        cleaned = clean_newsletter_html('<p>Look:</p><img src="https://cdn.example.com/chart.png" width="600">')

        assert 'src="https://cdn.example.com/chart.png"' in cleaned.html

    def test_finds_the_web_copy(self):
        cleaned = clean_newsletter_html(ISSUE_HTML)

        assert cleaned.browser_url == "https://newsletters.example.com/view/abc123"

    def test_no_web_copy_is_none(self):
        assert clean_newsletter_html("<p>Just words.</p>").browser_url is None

    def test_layout_tables_do_not_run_cells_together(self):
        cleaned = clean_newsletter_html(ISSUE_HTML)
        text = " ".join(spoken(cleaned.html))

        assert "<table" not in cleaned.html
        assert "Yesterday Today" in text
        assert "YesterdayToday" not in text

    def test_removes_styles_and_scripts(self):
        cleaned = clean_newsletter_html("<style>p{}</style><script>alert(1)</script><p>Hi</p>")

        assert cleaned.html == "<p>Hi</p>"

    def test_a_short_issue_is_not_mistaken_for_a_footer(self):
        # A wrapper that contains both the writing and the footer must keep
        # the writing, however short the whole thing is.
        html = '<table><tr><td><p>One good sentence.</p><p><a href="https://x.test/u">Unsubscribe</a></p></td></tr></table>'
        cleaned = clean_newsletter_html(html)

        assert "One good sentence." in cleaned.html
        assert "Unsubscribe" not in cleaned.html

    def test_keeps_the_preview_line_as_the_summary(self):
        cleaned = clean_newsletter_html(ISSUE_HTML)

        assert cleaned.preview_text == "Things happen. Preview text nobody should hear."

    def test_the_preview_line_loses_its_invisible_padding(self):
        html = '<div style="display:none">A deep dive into robots.\u034f \u200c \u034f \u200c</div><p>Words.</p>'

        assert clean_newsletter_html(html).preview_text == "A deep dive into robots."

    def test_a_padding_only_hidden_block_is_not_a_preview(self):
        assert clean_newsletter_html('<div style="display:none">\u034f \u034f</div><p>Words.</p>').preview_text is None

    def test_the_title_is_not_read_twice(self):
        # Substack and Beehiiv open the body with the post title, which is
        # already the item's title.
        html = "<h1>Why robots are slow</h1><p>A deck line.</p><p>The body.</p>"
        cleaned = clean_newsletter_html(html, subject="Why robots are slow")

        assert spoken(cleaned.html) == ["A deck line.", "The body."]

    def test_a_heading_that_is_not_the_title_stays(self):
        cleaned = clean_newsletter_html("<h1>Second price</h1><p>The body.</p>", subject="Money Stuff: Auctions")

        assert spoken(cleaned.html) == ["Second price", "The body."]

    def test_the_title_link_stands_in_for_a_web_copy(self):
        html = '<a href="https://example.test/p/robots">Why robots are slow</a><p>The body.</p>'

        assert (
            clean_newsletter_html(html, subject="Why robots are slow").browser_url == "https://example.test/p/robots"
        )

    def test_labels_and_lone_punctuation_go_wherever_they_are(self):
        html = "<p>READ IN APP</p><p>The body of the issue.</p><p>|</p><p>Share</p><p>More body.</p>"

        assert spoken(clean_newsletter_html(html).html) == ["The body of the issue.", "More body."]

    def test_the_closing_lines_come_off_the_end(self):
        html = (
            "<p>A paragraph the writer wrote, which is long enough to be one.</p>"
            "<p>Like</p><p>© 2026 Timothy B Lee</p>"
            "<p>548 Market Street PMB 72296, San Francisco, CA 94104</p>"
            "<p>Powered by beehiiv</p>"
        )

        assert spoken(clean_newsletter_html(html).html) == [
            "A paragraph the writer wrote, which is long enough to be one."
        ]

    def test_a_copyright_in_the_middle_is_left_alone(self):
        html = "<p>Para one.</p><figcaption>Photo © Reuters</figcaption><p>Para two.</p>"

        assert spoken(clean_newsletter_html(html).html) == ["Para one.", "Photo © Reuters", "Para two."]

    def test_curly_apostrophes_count(self):
        html = "<p>The body.</p><p>Before it’s here, it’s on the Bloomberg Terminal. Find out more.</p>"

        assert spoken(clean_newsletter_html(html).html) == ["The body."]

    def test_empty_input(self):
        assert clean_newsletter_html("").html == ""
        assert clean_newsletter_html("   ").html == ""

    def test_text_after_a_removed_element_survives(self):
        cleaned = clean_newsletter_html(
            '<p>Before <img src="https://t.test/open.gif" width="1" height="1"> after.</p>'
        )

        assert spoken(cleaned.html) == ["Before after."]


class TestForwardingChrome:
    def test_the_lines_a_mail_app_adds_above_a_forward_go(self):
        html = (
            "<div>---------- Forwarded message ---------</div>"
            "<div>From: <b>Matt Levine</b> &lt;noreply@mail.bloombergbusiness.com&gt;</div>"
            "<div>Date: Tue, 1 Sep 2026 at 12:00</div><div>Subject: Money Stuff</div>"
            "<div>To: &lt;henry@gmail.com&gt;</div>"
            "<p>Things happened today, and from the look of it they will again.</p>"
        )

        cleaned = clean_newsletter_html(html)

        assert "Forwarded message" not in cleaned.html and "henry@gmail.com" not in cleaned.html
        assert "Things happened today" in cleaned.html

    def test_a_sentence_that_starts_with_to_is_writing(self):
        html = "<p>To be fair to the regulators, this was never going to be simple, and the filing shows why.</p>"

        assert "To be fair" in clean_newsletter_html(html).html
