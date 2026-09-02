"""Emails as newsletters actually send them, for the inbound tests."""

from email.message import EmailMessage
from email.policy import SMTP

#: The shape Bloomberg, Mailchimp and their peers all use: a hidden preview
#: line, nested layout tables, a "view in browser" link, the issue, a tracking
#: pixel and a footer of unsubscribe links and a postal address.
ISSUE_HTML = """
<html><head><title>Money Stuff</title><style>body { color: #000; }</style></head>
<body style="margin:0">
<div style="display:none;max-height:0px;overflow:hidden;mso-hide:all;">
Things happen. Preview text nobody should hear.</div>
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
<table width="600"><tr><td>
<p style="font-size:11px"><a href="https://newsletters.example.com/view/abc123">View in browser</a></p>
</td></tr>
<tr><td>
<h1>Things Happen</h1>
<p>Programming note: Money Stuff will be off tomorrow, back on Thursday. There is a general principle in finance
that if you can find a way to make a lot of money by doing something slightly strange, somebody has already done it,
and the interesting question is only what happened to them afterwards.</p>
<p>This is roughly the story of every trade that has ever been described as a sure thing. The sure thing is sure
right up until the moment when everyone has piled into it, at which point it becomes the opposite of a sure thing,
and the people who got in early are the people writing the memoirs.</p>
<p>Anyway, here is a company that did something slightly strange with its convertible bonds, and here is what
happened to it afterwards, which will not surprise you.</p>
<table><tr><td>Yesterday</td><td>Today</td></tr><tr><td>Up</td><td>Down</td></tr></table>
</td></tr>
<tr><td><img src="https://track.example.com/o.gif?u=1" width="1" height="1" alt=""></td></tr>
<tr><td style="font-size:11px">You are receiving this email because you signed up for Money Stuff.
<a href="https://example.com/unsubscribe">Unsubscribe</a> |
<a href="https://example.com/prefs">Manage your preferences</a><br>
Bloomberg L.P., 731 Lexington Avenue, New York, NY 10022</td></tr>
</table></td></tr></table>
</body></html>
"""

ISSUE_TEXT = """Things Happen

Programming note: Money Stuff will be off tomorrow, back on Thursday.
There is a general principle in finance that if you can find a way to
make a lot of money by doing something slightly strange, somebody has
already done it.

Unsubscribe: https://example.com/unsubscribe
"""


def build_email(
    *,
    subject: str = "Money Stuff: Things Happen",
    sender: str = "Matt Levine <noreply@mail.bloombergbusiness.com>",
    to: str = "someone@in.test",
    html: str | None = ISSUE_HTML,
    text: str | None = None,
    message_id: str | None = "<issue-1@mail.bloombergbusiness.com>",
    list_id: str | None = None,
    date: str | None = "Tue, 01 Sep 2026 12:00:00 +0000",
    delivered_to: str | None = None,
) -> bytes:
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = sender
    message["To"] = to
    if message_id:
        message["Message-ID"] = message_id
    if list_id:
        message["List-ID"] = list_id
    if date:
        message["Date"] = date
    if delivered_to:
        message["Delivered-To"] = delivered_to
    if text is not None and html is not None:
        message.set_content(text)
        message.add_alternative(html, subtype="html")
    elif html is not None:
        message.set_content(html, subtype="html")
    elif text is not None:
        message.set_content(text)
    return message.as_bytes(policy=SMTP)
