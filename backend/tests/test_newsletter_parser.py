from datetime import UTC, datetime

import pytest
from tests.newsletter_fixtures import ISSUE_HTML, ISSUE_TEXT, build_email

from audioreader.newsletters.parser import NewsletterParseError, parse_newsletter, text_as_html


class TestParseNewsletter:
    def test_reads_the_headers_that_identify_an_issue(self):
        message = parse_newsletter(build_email())

        assert message.message_id == "issue-1@mail.bloombergbusiness.com"
        assert message.subject == "Money Stuff: Things Happen"
        assert message.sender.address == "noreply@mail.bloombergbusiness.com"
        assert message.sender.name == "Matt Levine"
        assert message.recipient == "someone@in.test"
        assert message.sent_at == datetime(2026, 9, 1, 12, tzinfo=UTC)

    def test_prefers_the_html_part_and_keeps_the_text_one(self):
        message = parse_newsletter(build_email(html=ISSUE_HTML, text=ISSUE_TEXT))

        assert message.html is not None and "Things Happen" in message.html
        assert message.text is not None and "Programming note" in message.text

    def test_text_only_mail_has_no_html(self):
        message = parse_newsletter(build_email(html=None, text=ISSUE_TEXT))

        assert message.html is None
        assert message.text is not None

    def test_the_sender_is_the_from_address_and_name_when_there_is_no_list(self):
        # Bloomberg sends every newsletter from one address with no List-ID;
        # only the display name says which one this is.
        message = parse_newsletter(build_email())
        other = parse_newsletter(build_email(sender="Bloomberg Opinion <noreply@mail.bloombergbusiness.com>"))

        assert message.sender.key == "noreply@mail.bloombergbusiness.com/matt-levine"
        assert other.sender.key == "noreply@mail.bloombergbusiness.com/bloomberg-opinion"
        assert parse_newsletter(build_email(sender="noreply@mail.bloombergbusiness.com")).sender.key == (
            "noreply@mail.bloombergbusiness.com"
        )

    def test_the_list_id_tells_newsletters_from_one_publisher_apart(self):
        # Bloomberg sends every newsletter from one address.
        message = parse_newsletter(build_email(list_id="Money Stuff <moneystuff.list-id.bloomberg.com>"))

        assert message.sender.key == "moneystuff.list-id.bloomberg.com"
        assert message.sender.name == "Money Stuff"

    def test_an_opaque_list_description_is_not_a_name(self):
        mailchimp = "b98e2de85f03865f1d38de74fmc list <b98e2de85f03865f1d38de74f.52809a9e4b.list-id.mcsv.net>"
        message = parse_newsletter(build_email(sender="Benedict Evans <news@ben-evans.com>", list_id=mailchimp))

        assert message.sender.key == "b98e2de85f03865f1d38de74f.52809a9e4b.list-id.mcsv.net"
        assert message.sender.name == "Benedict Evans"

    def test_a_nameless_sender_is_called_by_its_local_part(self):
        message = parse_newsletter(build_email(sender="moneystuff@example.com"))

        assert message.sender.name == "moneystuff"

    def test_the_bytes_stand_in_for_a_missing_message_id(self):
        raw = build_email(message_id=None)

        assert parse_newsletter(raw).message_id.startswith("sha256:")
        assert parse_newsletter(raw).message_id == parse_newsletter(raw).message_id

    def test_delivered_to_beats_the_to_header(self):
        message = parse_newsletter(build_email(to="list@example.com", delivered_to="Her <abc@in.test>"))

        assert message.recipient == "abc@in.test"

    def test_a_missing_or_unreadable_date_is_none(self):
        assert parse_newsletter(build_email(date=None)).sent_at is None
        assert parse_newsletter(build_email(date="not a date")).sent_at is None

    def test_a_blank_subject_is_untitled(self):
        assert parse_newsletter(build_email(subject="   ")).subject == "Untitled"

    def test_refuses_mail_with_no_sender(self):
        raw = build_email().replace(b"From: Matt Levine <noreply@mail.bloombergbusiness.com>\r\n", b"")

        with pytest.raises(NewsletterParseError, match="no sender"):
            parse_newsletter(raw)

    def test_refuses_mail_with_no_body(self):
        with pytest.raises(NewsletterParseError, match="no readable body"):
            parse_newsletter(build_email(html=None, text="   "))

    def test_refuses_things_that_are_not_mail(self):
        with pytest.raises(NewsletterParseError):
            parse_newsletter(b"\x00\x01 not an email at all")


class TestTextAsHtml:
    def test_blank_lines_become_paragraphs_and_wrapping_is_undone(self):
        html = text_as_html("First line\nof one paragraph.\n\nSecond <paragraph> & more.\n")

        assert html == "<p>First line of one paragraph.</p>\n<p>Second &lt;paragraph&gt; &amp; more.</p>"

    def test_windows_line_endings(self):
        assert text_as_html("a\r\n\r\nb") == "<p>a</p>\n<p>b</p>"


class TestHowToStop:
    def test_the_web_address_is_taken_and_one_click_noted(self):
        message = parse_newsletter(
            build_email(unsubscribe="<mailto:stop@news.test?subject=x>, <https://news.test/stop?t=1>", one_click=True)
        )

        assert message.unsubscribe_url == "https://news.test/stop?t=1"
        assert message.unsubscribe_post == "List-Unsubscribe=One-Click"

    def test_a_link_without_the_post_header_is_a_page_to_open(self):
        message = parse_newsletter(build_email(unsubscribe="<https://news.test/stop?t=1>"))

        assert (message.unsubscribe_url, message.unsubscribe_post) == ("https://news.test/stop?t=1", None)

    def test_mail_only_or_nothing_gives_nothing(self):
        assert parse_newsletter(build_email(unsubscribe="<mailto:stop@news.test>")).unsubscribe_url is None
        assert parse_newsletter(build_email()).unsubscribe_url is None
