"""Signing her address up to a newsletter, and recognising what comes back."""

from datetime import timedelta

import pytest
from sqlalchemy import select
from tests.newsletter_fixtures import build_email

from audioreader.commands import service as commands
from audioreader.commands.conversation import ConversationFinished, converse
from audioreader.commands.intents import Action
from audioreader.config import settings
from audioreader.llm.fake import FakeLLMClient
from audioreader.llm.openai_responses import ResponseCompleted
from audioreader.models import (
    APPROVAL_APPROVED,
    APPROVAL_PENDING,
    Episode,
    Feed,
    InboundMessage,
    NewsletterSignup,
    Subscription,
)
from audioreader.newsletters import service
from audioreader.newsletters.signup import (
    SignupUnsupported,
    confirmation_link,
    plan_signup,
    submit_signup,
)

ADDRESS = "hefty-prism-bolt@magpieinbox.com"

# The page's JSON blob names its own subdomain twice and a recommended
# publication's once, escaped the way Substack serves it.
SUBSTACK_PAGE = b"""<html><head><title>Understanding AI</title>
<meta property="og:site_name" content="Understanding AI"><link rel="preconnect" href="https://substackcdn.com">
</head><body><script src="https://substackcdn.com/x.js"></script><p>By Timothy B Lee</p>
<script>window._preloads = "{\\"pub\\":{\\"subdomain\\":\\"understandingai\\"},
\\"recs\\":[{\\"subdomain\\":\\"apricitas\\"}],
\\"again\\":{\\"subdomain\\":\\"understandingai\\"}}"</script>
</body></html>"""

SIGN_IN_EMAIL = """<html><body><p>Here is your verification code: <b>274513</b></p>
<p><a href="https://email.mg-tx1.substack.com/c/eJxck1FzqroX">Sign in to Substack</a></p>
<p><a href="https://substack.com/unsubscribe?x=1">Unsubscribe</a></p></body></html>"""

GHOST_PAGE = b"""<html><head><title>Slow Letters</title><meta name="generator" content="Ghost 6.62"></head>
<body><form data-members-form="subscribe"><input data-members-email type="email"></form></body></html>"""

MAILCHIMP_PAGE = b"""<html><head><title>Words from Anna</title></head><body>
<form action="https://anna.us6.list-manage.com/subscribe/post?u=abc123&amp;id=def456" method="post">
  <input type="email" name="EMAIL" placeholder="Email address">
  <input type="hidden" name="tags" value="42">
  <div style="position:absolute;left:-5000px"><input type="text" name="b_abc123_def456" value=""></div>
  <input type="submit" value="Subscribe">
</form></body></html>"""

BUTTONDOWN_PAGE = b"""<html><head><title>The Letter</title></head><body>
<form action="https://buttondown.com/api/emails/embed-subscribe/theletter" method="post">
  <input type="email" name="email"><input type="hidden" name="embed" value="1">
</form></body></html>"""

CAPTCHA_PAGE = b"""<html><head><title>Guarded</title></head><body>
<form action="/subscribe" method="post"><input type="email" name="email">
<div class="g-recaptcha" data-sitekey="abc"></div></form></body></html>"""

PLAIN_PAGE = b"<html><head><title>Just a site</title></head><body><p>No newsletter here.</p></body></html>"

SQUARESPACE_PAGE = b"""<html><head><title>Benedict Evans</title></head><body>
<form class="newsletter-form" method="post"><input type="email" name="email"></form></body></html>"""

TITLED_SUBSTACK_PAGE = b"""<html><head><title>Understanding AI | Timothy B. Lee | Substack</title>
<link rel="preconnect" href="https://substackcdn.com"></head><body></body></html>"""

CONFIRMATION_HTML = """<html><body><p>Almost finished... We need to confirm your email address.</p>
<p><a href="https://anna.us6.list-manage.com/subscribe/confirm?u=abc123&id=def456&e=xyz">
Yes, subscribe me to this list.</a></p>
<p><a href="https://anna.us6.list-manage.com/unsubscribe?u=abc123&id=def456">unsubscribe</a></p>
</body></html>"""


@pytest.fixture
def newsletters_enabled(monkeypatch):
    monkeypatch.setattr(settings, "inbound_email_domain", "magpieinbox.com")
    monkeypatch.setattr(settings, "inbound_email_secret", "secret")


class TestPlanning:
    async def test_substack(self, respx_mock):
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")

        plan = await plan_signup("https://www.understandingai.org")

        assert plan.platform == "substack"
        assert plan.publication == "Understanding AI"
        assert plan.submit_url == "https://www.understandingai.org/api/v1/free"
        assert plan.expected_senders == ("understandingai.org",)
        assert plan.publication_key == "understandingai"

    async def test_a_substack_dot_com_host_is_its_own_key(self, respx_mock):
        respx_mock.get("https://letters.substack.com/").respond(content=SUBSTACK_PAGE, content_type="text/html")

        plan = await plan_signup("https://letters.substack.com")

        assert plan.publication_key == "letters"

    async def test_a_bare_domain_is_enough(self, respx_mock):
        respx_mock.get("https://slowletters.test/").respond(content=GHOST_PAGE, content_type="text/html")

        plan = await plan_signup("slowletters.test")

        assert plan.platform == "ghost"
        assert plan.submit_url == "https://slowletters.test/members/api/send-magic-link/"

    async def test_a_mailchimp_form(self, respx_mock):
        respx_mock.get("https://anna.test/").respond(content=MAILCHIMP_PAGE, content_type="text/html")

        plan = await plan_signup("https://anna.test/")

        assert plan.platform == "mailchimp"
        assert plan.publication == "Words from Anna"
        assert plan.submit_url == "https://anna.us6.list-manage.com/subscribe/post?u=abc123&id=def456"
        assert plan.email_field == "EMAIL"
        # The hidden field keeps its value; the honeypot text field is sent empty.
        assert plan.form_fields == (("tags", "42"), ("b_abc123_def456", ""))
        assert plan.expected_senders == ("anna.test",)

    async def test_a_buttondown_form(self, respx_mock):
        respx_mock.get("https://theletter.test/").respond(content=BUTTONDOWN_PAGE, content_type="text/html")

        plan = await plan_signup("https://theletter.test/")

        assert plan.platform == "buttondown"
        assert plan.expected_senders == ("theletter.test", "buttondown.email")

    async def test_a_captcha_is_never_worked_around(self, respx_mock):
        respx_mock.get("https://guarded.test/").respond(content=CAPTCHA_PAGE, content_type="text/html")

        with pytest.raises(SignupUnsupported) as excinfo:
            await plan_signup("https://guarded.test/")
        assert excinfo.value.reason == "captcha"

    async def test_a_publisher_that_wants_an_account(self):
        with pytest.raises(SignupUnsupported) as excinfo:
            await plan_signup("https://www.bloomberg.com/account/newsletters/money-stuff")
        assert excinfo.value.reason == "account_required"

    async def test_a_form_without_a_destination_is_not_a_form(self, respx_mock):
        # Squarespace's newsletter block is submitted by a script; posting to
        # the page itself would do nothing and could look like success.
        respx_mock.get("https://www.ben-evans.test/newsletter").respond(
            content=SQUARESPACE_PAGE, content_type="text/html"
        )

        with pytest.raises(SignupUnsupported) as excinfo:
            await plan_signup("https://www.ben-evans.test/newsletter")
        assert excinfo.value.reason == "no_form"

    async def test_the_name_stops_at_the_title_separator(self, respx_mock):
        respx_mock.get("https://www.understandingai.org/").respond(
            content=TITLED_SUBSTACK_PAGE, content_type="text/html"
        )

        plan = await plan_signup("https://www.understandingai.org")

        assert plan.publication == "Understanding AI"

    async def test_a_site_with_no_form(self, respx_mock):
        respx_mock.get("https://plain.test/").respond(content=PLAIN_PAGE, content_type="text/html")

        with pytest.raises(SignupUnsupported) as excinfo:
            await plan_signup("https://plain.test/")
        assert excinfo.value.reason == "no_form"


class TestSubmitting:
    async def test_substack_posts_json_the_way_its_page_does(self, respx_mock):
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        route = respx_mock.post("https://www.understandingai.org/api/v1/free").respond(
            200, json={"email": ADDRESS, "prompt_to_login": False}
        )
        plan = await plan_signup("https://www.understandingai.org")

        await submit_signup(plan, ADDRESS)

        sent = route.calls[0].request
        assert b'"email": "hefty-prism-bolt@magpieinbox.com"' in sent.content.replace(b'":"', b'": "')
        assert b'"first_session_url"' in sent.content
        assert sent.headers["content-type"].startswith("application/json")
        assert sent.headers["accept"] == "application/json"
        assert sent.headers["origin"] == "https://www.understandingai.org"
        assert sent.headers["referer"] == "https://www.understandingai.org/"

    async def test_substack_asking_for_a_sign_in_gets_the_sign_in_email_requested(self, respx_mock):
        # What Substack answers for an address whose account is unverified:
        # 200, no subscriber made, "sign in instead". The sign-in email is
        # what verifies it, so ask for one.
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        respx_mock.post("https://www.understandingai.org/api/v1/free").respond(
            200, json={"email": ADDRESS, "prompt_to_login": True, "didSignup": False}
        )
        sign_in = respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})
        plan = await plan_signup("https://www.understandingai.org")

        requested = await submit_signup(plan, ADDRESS)

        assert requested is True
        sent = sign_in.calls[0].request
        assert b'"for_pub": "understandingai"' in sent.content.replace(b'":"', b'": "')
        assert sent.headers["origin"] == "https://substack.com"

    async def test_a_first_substack_always_gets_the_sign_in_email(self, respx_mock):
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        respx_mock.post("https://www.understandingai.org/api/v1/free").respond(200, json={"email": ADDRESS})
        sign_in = respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})
        plan = await plan_signup("https://www.understandingai.org")

        assert await submit_signup(plan, ADDRESS, request_sign_in=True) is True
        assert sign_in.call_count == 1

    async def test_a_verified_address_needs_no_sign_in_email(self, respx_mock):
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        respx_mock.post("https://www.understandingai.org/api/v1/free").respond(200, json={"email": ADDRESS})
        sign_in = respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})
        plan = await plan_signup("https://www.understandingai.org")

        assert await submit_signup(plan, ADDRESS, request_sign_in=False) is False
        assert sign_in.call_count == 0

    async def test_a_substack_redirect_is_not_a_signup(self, respx_mock):
        # What a bare POST gets: a redirect to the page, and no subscriber.
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        respx_mock.post("https://www.understandingai.org/api/v1/free").respond(
            302, headers={"Location": "https://www.understandingai.org/"}
        )
        plan = await plan_signup("https://www.understandingai.org")

        from audioreader.newsletters.signup import SignupFailed

        with pytest.raises(SignupFailed, match="redirect"):
            await submit_signup(plan, ADDRESS)

    async def test_a_form_posts_its_fields(self, respx_mock):
        respx_mock.get("https://anna.test/").respond(content=MAILCHIMP_PAGE, content_type="text/html")
        route = respx_mock.post("https://anna.us6.list-manage.com/subscribe/post").respond(
            200, content=b"<html>Almost finished... We need to confirm your email address.</html>"
        )
        plan = await plan_signup("https://anna.test/")

        await submit_signup(plan, ADDRESS)

        body = route.calls[0].request.content.decode()
        assert "EMAIL=hefty-prism-bolt%40magpieinbox.com" in body
        assert "tags=42" in body
        assert "b_abc123_def456=" in body

    async def test_a_refusal_is_reported(self, respx_mock):
        respx_mock.get("https://anna.test/").respond(content=MAILCHIMP_PAGE, content_type="text/html")
        respx_mock.post("https://anna.us6.list-manage.com/subscribe/post").respond(400, content=b"bad")
        plan = await plan_signup("https://anna.test/")

        from audioreader.newsletters.signup import SignupFailed

        with pytest.raises(SignupFailed):
            await submit_signup(plan, ADDRESS)

    async def test_a_captcha_demanded_on_reply(self, respx_mock):
        respx_mock.get("https://anna.test/").respond(content=MAILCHIMP_PAGE, content_type="text/html")
        respx_mock.post("https://anna.us6.list-manage.com/subscribe/post").respond(
            200, content=b"<html>Please complete the reCAPTCHA below to confirm</html>"
        )
        plan = await plan_signup("https://anna.test/")

        with pytest.raises(SignupUnsupported) as excinfo:
            await submit_signup(plan, ADDRESS)
        assert excinfo.value.reason == "captcha"


class TestConfirmationLink:
    def test_finds_the_yes_link_by_its_words(self):
        assert confirmation_link(CONFIRMATION_HTML, None) == (
            "https://anna.us6.list-manage.com/subscribe/confirm?u=abc123&id=def456&e=xyz"
        )

    def test_finds_it_by_its_address(self):
        html = '<a href="https://x.test/members/verify?token=1">Click here</a>'
        assert confirmation_link(html, None) == "https://x.test/members/verify?token=1"

    def test_never_an_unsubscribe_however_labelled(self):
        html = '<a href="https://x.test/unsubscribe?confirm=1">Confirm</a>'
        assert confirmation_link(html, None) is None

    def test_plain_text_mail(self):
        text = "Please confirm: https://x.test/confirm/abc . Or unsubscribe: https://x.test/unsubscribe/abc"
        assert confirmation_link(None, text) == "https://x.test/confirm/abc"

    def test_no_link(self):
        assert confirmation_link("<p>Welcome!</p>", "Welcome!") is None

    def test_a_sign_in_link_counts_only_in_a_sign_in_email(self):
        # A newsletter's footer says "sign in" too, and that is not a yes.
        assert confirmation_link(SIGN_IN_EMAIL, None) is None
        assert (
            confirmation_link(SIGN_IN_EMAIL, None, sign_in=True) == "https://email.mg-tx1.substack.com/c/eJxck1FzqroX"
        )


class TestSignUp:
    async def test_submits_and_remembers(self, session, user, respx_mock, newsletters_enabled):
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        respx_mock.post("https://www.understandingai.org/api/v1/free").respond(200, json={"email": ADDRESS})
        sign_in = respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})

        outcome = await service.sign_up(session, user, "https://www.understandingai.org")

        # Her first Substack: the sign-in email that verifies the address.
        assert sign_in.call_count == 1

        assert outcome.status == "submitted"
        assert outcome.publication == "Understanding AI"
        assert outcome.address is not None and outcome.address.endswith("@magpieinbox.com")
        assert outcome.spoken_response.startswith("I have asked Understanding AI to send its newsletter")
        signup = (await session.scalars(select(NewsletterSignup))).one()
        assert signup.platform == "substack" and signup.completed_at is None

    async def test_a_second_substack_skips_the_sign_in_once_verified(
        self, session, user, respx_mock, newsletters_enabled
    ):
        session.add(
            NewsletterSignup(
                user_id=user.id,
                site_url="https://first.substack.com",
                publication="First",
                platform="substack",
                expected_senders="first.substack.com",
                confirmed_at=service.utcnow(),
            )
        )
        await session.commit()
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        respx_mock.post("https://www.understandingai.org/api/v1/free").respond(200, json={"email": ADDRESS})
        sign_in = respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})

        outcome = await service.sign_up(session, user, "https://www.understandingai.org")

        assert outcome.status == "submitted"
        assert sign_in.call_count == 0

    async def test_asking_twice_does_not_submit_twice(self, session, user, respx_mock, newsletters_enabled):
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        route = respx_mock.post("https://www.understandingai.org/api/v1/free").respond(200, json={"email": ADDRESS})
        respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})
        await service.sign_up(session, user, "https://www.understandingai.org")

        outcome = await service.sign_up(session, user, "https://www.understandingai.org")

        assert outcome.status == "submitted"
        assert "already asked" in outcome.spoken_response
        assert route.call_count == 1

    async def test_an_account_gated_publisher_gets_the_manual_path(self, session, user, newsletters_enabled):
        outcome = await service.sign_up(session, user, "https://www.bloomberg.com/account/newsletters/money-stuff")

        assert outcome.status == "unsupported" and outcome.reason == "account_required"
        assert "needs an account" in outcome.spoken_response
        assert "Your newsletter address is" in outcome.spoken_response
        assert "with hyphens between the words" in outcome.spoken_response
        assert (await session.scalars(select(NewsletterSignup))).all() == []

    async def test_an_unreachable_site(self, session, user, respx_mock, newsletters_enabled):
        respx_mock.get("https://down.test/").respond(503)

        outcome = await service.sign_up(session, user, "https://down.test")

        assert outcome.status == "failed"
        assert "could not reach down.test" in outcome.spoken_response

    async def test_disabled(self, session, user):
        with pytest.raises(service.NewslettersDisabledError):
            await service.sign_up(session, user, "https://www.understandingai.org")


async def signed_up(session, user, publication="Words from Anna", expected="anna.test", **fields) -> NewsletterSignup:
    signup = NewsletterSignup(
        user_id=user.id,
        site_url="https://anna.test",
        publication=publication,
        platform="mailchimp",
        expected_senders=expected,
        **fields,
    )
    session.add(signup)
    await session.commit()
    return signup


class TestWhatComesBack:
    async def test_the_confirmation_is_followed_and_not_filed(self, session, user, respx_mock, newsletters_enabled):
        signup = await signed_up(session, user)
        confirm = respx_mock.get("https://anna.us6.list-manage.com/subscribe/confirm").respond(
            200, content=b"Confirmed"
        )
        raw = build_email(
            to=ADDRESS,
            sender="Anna <anna@anna.test>",
            subject="Please Confirm Subscription",
            html=CONFIRMATION_HTML,
            message_id="<confirm@anna.test>",
        )

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "confirmed"
        assert confirm.call_count == 1
        assert signup.confirmed_at is not None
        assert (await session.scalars(select(Episode))).all() == []
        assert (await session.scalars(select(Feed))).all() == []

    async def test_the_first_issue_is_already_followed(self, session, user, newsletters_enabled):
        signup = await signed_up(session, user, confirmed_at=service.utcnow())
        raw = build_email(
            to=ADDRESS, sender="Anna <anna@anna.test>", subject="Words from Anna: Issue 1", message_id="<1@anna.test>"
        )

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "delivered"
        feed = (await session.scalars(select(Feed))).one()
        assert feed.approval == APPROVAL_APPROVED
        assert (await session.scalars(select(Subscription).where(Subscription.feed_id == feed.id))).one()
        assert signup.completed_at is not None and signup.feed_id == feed.id
        assert await service.pending_senders(session, user) == []

    async def test_a_newsletter_with_no_confirmation_step(self, session, user, newsletters_enabled):
        # Substack sends the first issue straight away; nothing to click.
        # Matched by the publication's name: Substack's From address is on
        # substack.com, not the site's domain.
        await signed_up(session, user, publication="Understanding AI", expected="understandingai.org")
        raw = build_email(
            to=ADDRESS,
            sender="Understanding AI <understandingai@substack.com>",
            subject="Welcome!",
            message_id="<w@substack.com>",
        )

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "delivered"
        assert (await session.scalars(select(Feed))).one().approval == APPROVAL_APPROVED

    async def test_matched_by_publication_name_when_the_domain_differs(self, session, user, newsletters_enabled):
        await signed_up(session, user, publication="Words from Anna", expected="anna.test")
        raw = build_email(
            to=ADDRESS, sender="Words from Anna <hello@sendgrid-relay.test>", message_id="<2@relay.test>"
        )

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "delivered"

    async def test_mailchimps_confirmed_notice_is_not_an_issue(self, session, user, newsletters_enabled):
        await signed_up(session, user, confirmed_at=service.utcnow())
        raw = build_email(
            to=ADDRESS, sender="Anna <anna@anna.test>", subject="Subscription Confirmed", message_id="<n@anna.test>"
        )

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "confirmed"
        assert (await session.scalars(select(Episode))).all() == []

    async def test_substacks_sign_in_email_is_followed_whoever_sent_it(
        self, session, user, respx_mock, newsletters_enabled
    ):
        signup = NewsletterSignup(
            user_id=user.id,
            site_url="https://www.understandingai.org",
            publication="Understanding AI",
            platform="substack",
            expected_senders="understandingai.org",
        )
        session.add(signup)
        await session.commit()
        followed = respx_mock.get("https://email.mg-tx1.substack.com/c/eJxck1FzqroX").respond(200, content=b"ok")
        raw = build_email(
            to=ADDRESS,
            sender="Matthew Yglesias <matthewyglesias@substack.com>",
            subject="274513 is your Substack verification code",
            html=SIGN_IN_EMAIL,
            message_id="<signin@substack.com>",
        )

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "confirmed"
        assert followed.call_count == 1
        assert signup.confirmed_at is not None and signup.completed_at is None
        assert (await session.scalars(select(Feed))).all() == []

    async def test_a_code_with_no_link_is_left_for_her_and_completes_nothing(self, session, user, newsletters_enabled):
        signup = await signed_up(session, user, publication="Understanding AI", expected="understandingai.org")
        signup.platform = "substack"
        await session.commit()
        raw = build_email(
            to=ADDRESS,
            sender="Ben Southwood <bensouthwood@substack.com>",
            subject="756893 is your Substack verification code",
            html="<p>Your code is 756893.</p>",
            message_id="<code@substack.com>",
        )

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "skipped"
        assert signup.completed_at is None and signup.confirmed_at is None
        # A code is not an issue of anything, so nothing is filed for it.
        assert (await session.scalars(select(Feed))).all() == []
        record = (await session.scalars(select(InboundMessage))).one()
        assert record.error == "a sign-up step; not an issue"

    async def test_a_code_never_sits_on_top_of_a_newsletter_she_follows(self, session, user, newsletters_enabled):
        # Substack sends its codes from a publication's address, List-ID and
        # all, so one used to land as the newest issue of that publication.
        issue = build_email(
            to=ADDRESS,
            sender="Ben Southwood from Baldwin <bensouthwood@substack.com>",
            subject="On growth",
            html="<p>An issue.</p>",
            message_id="<issue@substack.com>",
            list_id="<bensouthwood.substack.com>",
        )
        await service.receive(session, user, issue)
        feed = (await session.scalars(select(Feed))).one()
        await service.approve(session, user, feed.id)
        code = build_email(
            to=ADDRESS,
            sender="Ben Southwood from Baldwin <bensouthwood@substack.com>",
            subject="756893 is your Substack verification code",
            html="<p>Your code is 756893.</p>",
            message_id="<code@substack.com>",
            list_id="<bensouthwood.substack.com>",
        )

        delivery = await service.receive(session, user, code)

        assert delivery.status == "skipped"
        titles = (await session.scalars(select(Episode.title).where(Episode.feed_id == feed.id))).all()
        assert titles == ["On growth"]

    def test_an_issue_about_signing_in_is_still_an_issue(self):
        for subject in ("Why you should sign in to democracy", "The log-in to nowhere", "Confirm your priors"):
            assert not service._TRANSACTIONAL.search(subject), subject
        for subject in (
            "Sign in to Baldwin",
            "Please log in to Substack",
            "Your secure sign-in link for Works in Progress",
            "756893 is your Substack verification code",
            "Please confirm your subscription to Money Stuff",
        ):
            assert service._TRANSACTIONAL.search(subject), subject

    async def test_a_stranger_still_waits(self, session, user, newsletters_enabled):
        await signed_up(session, user)
        raw = build_email(to=ADDRESS, sender="Someone Else <news@elsewhere.test>", message_id="<3@elsewhere.test>")

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "pending"
        assert (await session.scalars(select(Feed))).one().approval == APPROVAL_PENDING

    async def test_an_old_signup_no_longer_vouches(self, session, user, newsletters_enabled):
        signup = await signed_up(session, user)
        signup.created_at = service.utcnow() - timedelta(days=settings.newsletter_signup_window_days + 1)
        await session.commit()
        raw = build_email(to=ADDRESS, sender="Anna <anna@anna.test>", message_id="<late@anna.test>")

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "pending"

    async def test_a_confirmation_that_cannot_be_followed_is_left_for_her(
        self, session, user, respx_mock, newsletters_enabled
    ):
        await signed_up(session, user)
        respx_mock.get("https://anna.us6.list-manage.com/subscribe/confirm").respond(500)
        raw = build_email(
            to=ADDRESS, sender="Anna <anna@anna.test>", html=CONFIRMATION_HTML, message_id="<c2@anna.test>"
        )

        delivery = await service.receive(session, user, raw)

        # Filed like any first message from a followed signup: she can open it
        # and use the link herself.
        assert delivery.status == "delivered"
        assert len((await session.scalars(select(Episode))).all()) == 1

    async def test_stale_signups_are_pruned(self, session, user, newsletters_enabled):
        await signed_up(session, user)

        summary = await service.prune_newsletters(
            session, now=service.utcnow() + timedelta(days=settings.newsletter_pending_retention_days + 1)
        )

        assert summary.stale_signups == 1
        assert (await session.scalars(select(NewsletterSignup))).all() == []


class TestEndpoint:
    async def test_sign_up(self, client, respx_mock, newsletters_enabled):
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        respx_mock.post("https://www.understandingai.org/api/v1/free").respond(200, json={"email": ADDRESS})
        respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})

        response = await client.post("/newsletters/signups", json={"url": "https://www.understandingai.org"})

        assert response.status_code == 200, response.text
        body = response.json()
        assert body["status"] == "submitted"
        assert body["publication"] == "Understanding AI"
        assert body["platform"] == "substack"
        assert body["spoken_response"].startswith("I have asked Understanding AI")

    async def test_unsupported_is_still_a_200_with_advice(self, client, newsletters_enabled):
        response = await client.post("/newsletters/signups", json={"url": "https://www.bloomberg.com/x"})

        assert response.status_code == 200
        assert response.json()["status"] == "unsupported"
        assert response.json()["reason"] == "account_required"

    async def test_not_configured(self, client):
        response = await client.post("/newsletters/signups", json={"url": "https://www.understandingai.org"})

        assert response.status_code == 503


class TestByVoice:
    async def test_a_spoken_site_with_no_feed_is_signed_up(
        self, session, user, respx_mock, newsletters_enabled, monkeypatch
    ):
        # Discovery finds no feed on the site; the signup form is there.
        async def nothing_found(*_args, **_kwargs):
            return None

        monkeypatch.setattr(commands, "find_feed_by_name", nothing_found)
        respx_mock.get("https://itunes.apple.com/search").respond(200, json={"results": []})
        respx_mock.get("https://anna.test/").respond(content=MAILCHIMP_PAGE, content_type="text/html")
        for path in (
            "/feed",
            "/feed/",
            "/rss",
            "/rss/",
            "/feed.xml",
            "/rss.xml",
            "/atom.xml",
            "/index.xml",
            "/feed.json",
        ):
            respx_mock.get(f"https://anna.test{path}").respond(404)
        respx_mock.get("https://www.anna.test/").respond(404)
        respx_mock.post("https://anna.us6.list-manage.com/subscribe/post").respond(200, content=b"Almost finished")
        llm = FakeLLMClient({"action": "subscribe", "search_query": "anna.test", "spoken_response": ""})

        result = await commands.interpret(session, llm, user=user, transcript="subscribe to anna dot test")

        assert result.action is Action.UNKNOWN
        assert result.spoken_response.startswith("I have asked Words from Anna to send its newsletter")
        assert (await session.scalars(select(NewsletterSignup))).one().platform == "mailchimp"

    async def test_the_streamed_conversation_has_the_tool(self, session, user, respx_mock, newsletters_enabled):
        respx_mock.get("https://www.understandingai.org/").respond(content=SUBSTACK_PAGE, content_type="text/html")
        respx_mock.post("https://www.understandingai.org/api/v1/free").respond(200, json={"email": ADDRESS})
        respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})

        class Scripted:
            def __init__(self):
                self.requests = []

            async def stream(self, *, instructions, input_items, tools=None):
                self.requests.append((instructions, list(input_items), list(tools or [])))
                yield ResponseCompleted(
                    {
                        "output": [
                            {
                                "type": "function_call",
                                "name": "sign_up_for_newsletter",
                                "call_id": "c1",
                                "arguments": '{"url":"https://www.understandingai.org"}',
                            }
                        ]
                    }
                )

        client = Scripted()
        events = [e async for e in converse(session, client, transcript="follow understanding ai", user=user)]

        finished = next(e for e in events if isinstance(e, ConversationFinished))
        assert finished.result.spoken_response.startswith("I have asked Understanding AI")
        assert "sign_up_for_newsletter" in client.requests[0][0]
        assert any(tool.get("name") == "sign_up_for_newsletter" for tool in client.requests[0][2])


class TestWhatASignupMayClaim:
    async def test_forwarded_mail_answers_no_signup(self, session, user, newsletters_enabled):
        signup = await signed_up(session, user, publication="Understanding AI", expected="understandingai.org")
        raw = build_email(
            sender="Astral Codex Ten <astralcodexten@substack.com>",
            to="henry@gmail.com",
            list_id="<astralcodexten.substack.com>",
            message_id="<acx@substack.com>",
        )
        raw = raw.replace(b"Subject:", b"X-Forwarded-To: hefty-prism-bolt@magpieinbox.com\r\nSubject:", 1)

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "pending"
        assert signup.completed_at is None and signup.feed_id is None

    async def test_a_shared_mail_domain_an_old_signup_expected_vouches_for_nobody(
        self, session, user, newsletters_enabled
    ):
        signup = await signed_up(
            session, user, publication="Understanding AI", expected="understandingai.org, substack.com"
        )
        raw = build_email(
            sender="Astral Codex Ten <astralcodexten@substack.com>",
            to=ADDRESS,
            list_id="<astralcodexten.substack.com>",
            message_id="<acx@substack.com>",
        )

        delivery = await service.receive(session, user, raw)

        assert delivery.status == "pending"
        assert signup.completed_at is None
