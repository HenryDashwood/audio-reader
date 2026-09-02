"""Signing her address up to a newsletter, so nobody has to type it.

Given a publication's web page, work out how it takes signups and submit her
address the way its own form would. Three shapes cover most of the world:
Substack and Ghost have a JSON endpoint behind their button; everything
built on Mailchimp, Buttondown, Kit or a site's own newsletter block is a
plain HTML form that can be posted. What is left — Bloomberg wants an
account, some sites put a CAPTCHA in front — is reported honestly so the
app can offer the address for a person to enter instead. A CAPTCHA is never
worked around.

The other half is recognising the reply. A confirmation email carries one
link that completes the signup; `confirmation_link` finds it, and never an
unsubscribe or preferences link, so following it can only ever say yes.
"""

import json
import logging
import re
from dataclasses import dataclass
from html import unescape
from urllib.parse import urljoin, urlsplit

from lxml import html as lxml_html

from audioreader.feeds.fetcher import MAX_ARTICLE_BYTES, FeedFetchError, fetch_public_bytes, post_public

logger = logging.getLogger(__name__)

SUBSTACK = "substack"
GHOST = "ghost"
MAILCHIMP = "mailchimp"
BUTTONDOWN = "buttondown"
KIT = "kit"
BEEHIIV = "beehiiv"
FORM = "form"

#: Publishers whose newsletters need an account first. Their forms exist, but
#: posting to them signs nobody up; the honest answer is the manual path.
_ACCOUNT_REQUIRED = ("bloomberg.com", "nytimes.com", "ft.com", "wsj.com", "economist.com", "washingtonpost.com")

_CAPTCHA = re.compile(r"g-recaptcha|h-captcha|cf-turnstile|data-sitekey|recaptcha/api|hcaptcha\.com", re.IGNORECASE)
_CAPTCHA_REPLY = re.compile(r"captcha|turnstile", re.IGNORECASE)
_EMAIL_FIELD = re.compile(r"e-?mail", re.IGNORECASE)

#: Link text that completes a signup.
_CONFIRM_TEXT = re.compile(
    r"confirm|verify|activate|yes,? (?:subscribe|sign me up|add me)|complete (?:your )?(?:sign[- ]?up|subscription)"
    r"|click here to (?:subscribe|confirm)|subscribe me",
    re.IGNORECASE,
)
#: Link addresses that complete a signup.
_CONFIRM_HREF = re.compile(
    r"confirm|verify|activat|validate|magic[-_]?link|double[-_]?opt|optin|subscribe/(?:confirm|verify)",
    re.IGNORECASE,
)
#: Links that must never be followed on her behalf, whatever they say.
#: Checked against a link's path and query, never its host: Mailchimp's
#: confirmation links live on list-manage.com.
_NEVER_FOLLOW = re.compile(r"unsub|opt[-_]?out|preferences|manage|remove|delete|cancel|report", re.IGNORECASE)
_WHITESPACE = re.compile(r"\s+")


class SignupUnsupported(Exception):
    """This site cannot be signed up to automatically. `reason` says why:
    account_required, captcha, or no_form."""

    def __init__(self, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


class SignupFailed(Exception):
    """The site was asked and said no, or did not answer."""


@dataclass(frozen=True)
class SignupPlan:
    platform: str
    publication: str
    site_url: str
    submit_url: str
    #: For a form: the fields to send besides the address, and the address
    #: field's name. Empty for the JSON platforms.
    form_fields: tuple[tuple[str, str], ...] = ()
    email_field: str = "email"
    #: Domains and addresses its mail is expected from.
    expected_senders: tuple[str, ...] = ()


def normalised_site(url: str) -> str:
    candidate = url.strip()
    if not candidate.lower().startswith(("http://", "https://")):
        candidate = "https://" + candidate
    parts = urlsplit(candidate)
    if not parts.hostname:
        raise SignupUnsupported("no_form", "that is not a web address")
    return candidate


def site_domain(url: str) -> str:
    host = (urlsplit(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


async def plan_signup(url: str) -> SignupPlan:
    """Fetch the page and work out how it takes signups."""
    site = normalised_site(url)
    domain = site_domain(site)
    if any(domain == known or domain.endswith("." + known) for known in _ACCOUNT_REQUIRED):
        raise SignupUnsupported("account_required", f"{domain} needs an account before it will send its newsletter")

    raw, final_url = await fetch_public_bytes(site, max_bytes=MAX_ARTICLE_BYTES)
    html = raw.decode("utf-8", errors="replace")
    domain = site_domain(final_url)
    origin = f"{urlsplit(final_url).scheme}://{urlsplit(final_url).netloc}"
    try:
        document = lxml_html.document_fromstring(html)
    except Exception as exc:  # noqa: BLE001 - lxml's parser errors are a long list
        raise SignupUnsupported("no_form", "the page could not be read") from exc
    publication = _publication_title(document, domain)

    if "substackcdn.com" in html or domain.endswith("substack.com") or "/api/v1/free" in html:
        # Only the site's own domain: Substack's transactional mail — a
        # verification code, say — comes from whichever publication's
        # address it likes, and "anything at substack.com" would have
        # let one of those pass for the newsletter's first issue.
        return SignupPlan(
            platform=SUBSTACK,
            publication=publication,
            site_url=origin,
            submit_url=origin + "/api/v1/free",
            expected_senders=(domain,),
        )

    generator = document.head.find(".//meta[@name='generator']") if document.head is not None else None
    generated_by = (generator.get("content") or "") if generator is not None else ""
    if generated_by.lower().startswith("ghost") or "data-members-form" in html:
        return SignupPlan(
            platform=GHOST,
            publication=publication,
            site_url=origin,
            submit_url=origin + "/members/api/send-magic-link/",
            expected_senders=(domain,),
        )

    plan = _form_plan(document, final_url, publication, domain)
    if plan is not None:
        return plan
    raise SignupUnsupported("no_form", f"no signup form was found on {domain}")


_TITLE_SEPARATOR = re.compile(r"\s+[|–—·]\s+|\s+-\s+")


def _publication_title(document: lxml_html.HtmlElement, domain: str) -> str:
    """The publication's name, as the page states it.

    A page title runs on — "Understanding AI | Timothy B. Lee | Substack" —
    and the name is the part before the first separator. The site name in
    the page's metadata is already just the name, when a page carries one.
    """
    for selector in (".//meta[@property='og:site_name']", ".//meta[@property='og:title']", ".//title"):
        element = document.find(selector)
        value = (element.get("content") if element is not None and selector != ".//title" else None) or (
            element.text if element is not None and selector == ".//title" else None
        )
        if value and value.strip():
            name = _TITLE_SEPARATOR.split(_WHITESPACE.sub(" ", value).strip(), maxsplit=1)[0].strip()
            if name:
                return name[:200]
    return domain


def _form_plan(document: lxml_html.HtmlElement, page_url: str, publication: str, domain: str) -> SignupPlan | None:
    for form in document.iter("form"):
        email_input = next(
            (
                element
                for element in form.iter("input")
                if (element.get("type") or "").lower() == "email" or _EMAIL_FIELD.search(element.get("name") or "")
            ),
            None,
        )
        if email_input is None or not email_input.get("name"):
            continue
        if _CAPTCHA.search(lxml_html.tostring(form, encoding="unicode")):
            raise SignupUnsupported("captcha", f"{domain} asks people to solve a CAPTCHA before signing up")
        if not (form.get("action") or "").strip():
            # No destination means a script submits it — Squarespace's
            # newsletter block, for one. Posting to the page would achieve
            # nothing and might look like success.
            continue
        action = urljoin(page_url, form.get("action").strip())
        if (form.get("method") or "post").lower() != "post":
            continue
        fields: list[tuple[str, str]] = []
        for element in form.iter("input"):
            name = element.get("name")
            if not name or element is email_input:
                continue
            kind = (element.get("type") or "text").lower()
            if kind in {"submit", "button", "image", "reset", "file", "password"}:
                continue
            if kind in {"checkbox", "radio"} and element.get("checked") is None:
                continue
            # Text fields other than the address are usually a honeypot,
            # which is sent empty on purpose; hidden fields keep their value.
            fields.append((name, element.get("value") or "" if kind == "hidden" else ""))
        platform, extra = _form_platform(action)
        return SignupPlan(
            platform=platform,
            publication=publication,
            site_url=page_url,
            submit_url=action,
            form_fields=tuple(fields),
            email_field=email_input.get("name") or "email",
            expected_senders=(domain, *extra),
        )
    return None


def _form_platform(action: str) -> tuple[str, tuple[str, ...]]:
    host = site_domain(action)
    if host.endswith("list-manage.com"):
        return MAILCHIMP, ()
    if host.endswith("buttondown.com") or host.endswith("buttondown.email"):
        return BUTTONDOWN, ("buttondown.email",)
    if host.endswith("kit.com") or host.endswith("convertkit.com"):
        return KIT, ()
    if "beehiiv" in host:
        return BEEHIIV, ("beehiiv.com",)
    return FORM, ()


async def submit_signup(plan: SignupPlan, address: str) -> None:
    """Send her address the way the site's own button would."""
    try:
        if plan.platform == SUBSTACK:
            # Substack only acts on a request shaped like its own page's: the
            # page's origin and referer, JSON asked for in return, and the
            # full set of fields its form sends. Anything less gets a
            # redirect and no subscription — which is what a bare POST got
            # in testing, while looking for all the world like success.
            page = plan.site_url.rstrip("/") + "/"
            reply = await post_public(
                plan.submit_url,
                json={
                    "email": address,
                    "first_url": page,
                    "first_referrer": "",
                    "current_url": page,
                    "current_referrer": "",
                    "first_session_url": page,
                    "first_session_referrer": "",
                    "referral_code": "",
                    "source": "subscribe_page",
                    "referring_pub_id": "",
                    "additional_referring_pub_ids": "",
                },
                headers={"Accept": "application/json", "Origin": plan.site_url, "Referer": page},
            )
            if 300 <= reply.status_code < 400:
                raise SignupFailed(f"{plan.publication} answered with a redirect rather than accepting the signup")
            if reply.status_code < 300 and not _substack_signed_up(reply.content):
                # The address already has a Substack account, and Substack
                # will only subscribe it from a logged-in session. Seen when
                # an earlier attempt created the account: the subscription
                # exists, but a second run must not claim to have made it.
                raise SignupFailed(f"{plan.publication} already knows this address and asked it to sign in instead")
        elif plan.platform == GHOST:
            reply = await post_public(plan.submit_url, json={"email": address, "emailType": "subscribe"})
        else:
            reply = await post_public(plan.submit_url, data={**dict(plan.form_fields), plan.email_field: address})
    except FeedFetchError as exc:
        raise SignupFailed(f"{plan.publication} could not be reached: {exc}") from exc

    body = reply.content.decode("utf-8", errors="replace")
    if _CAPTCHA_REPLY.search(body) and (reply.status_code >= 400 or "captcha" in body[:20_000].lower()):
        raise SignupUnsupported("captcha", f"{plan.publication} asks people to solve a CAPTCHA before signing up")
    if reply.status_code >= 400:
        logger.info("signup to %s refused with HTTP %s: %s", plan.submit_url, reply.status_code, body[:300])
        raise SignupFailed(f"{plan.publication} did not accept the signup (HTTP {reply.status_code})")


def _substack_signed_up(body: bytes) -> bool:
    """Substack's JSON says whether it made a subscriber. A body it did not
    write as JSON is taken as a yes: the field only exists to catch the
    known no."""
    try:
        reply = json.loads(body.decode("utf-8", errors="replace") or "{}")
    except ValueError:
        return True
    if not isinstance(reply, dict):
        return True
    return reply.get("didSignup", True) is not False


def confirmation_link(html: str | None, text: str | None) -> str | None:
    """The one link in a confirmation email that says yes.

    Looked for by what the link says first, then by what its address says.
    Anything that could mean no — unsubscribe, preferences, remove — is
    refused however it is labelled.
    """
    if html:
        try:
            document = lxml_html.document_fromstring(html)
        except Exception:  # noqa: BLE001
            document = None
        if document is not None:
            anchors = [
                (_WHITESPACE.sub(" ", anchor.text_content()).strip(), (anchor.get("href") or "").strip())
                for anchor in document.iter("a")
            ]
            anchors = [(label, href) for label, href in anchors if href.lower().startswith(("http://", "https://"))]
            for label, href in anchors:
                if _CONFIRM_TEXT.search(label) and not _says_no(href) and not _NEVER_FOLLOW.search(label):
                    return href[:4_096]
            for _, href in anchors:
                if _CONFIRM_HREF.search(_path_and_query(href)) and not _says_no(href):
                    return href[:4_096]
    if text:
        for match in re.finditer(r"https?://[^\s<>\"']+", unescape(text)):
            href = match.group(0).rstrip(".,;)")
            if _CONFIRM_HREF.search(_path_and_query(href)) and not _says_no(href):
                return href[:4_096]
    return None


def _path_and_query(href: str) -> str:
    parts = urlsplit(href)
    return f"{parts.path}?{parts.query}"


def _says_no(href: str) -> bool:
    return bool(_NEVER_FOLLOW.search(_path_and_query(href)))
