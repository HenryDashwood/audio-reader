"""Newsletters that arrive by email, delivered to a private address per user.

Most publications the app follows are feeds. Some — Bloomberg's Money Stuff,
anything sent through Mailchimp with its archive switched off — exist only as
email. For those, each listener has one inbound address of her own. The
newsletter is subscribed to that address, the mail arrives here, and each
issue becomes an item in a private feed that is otherwise exactly like any
other article feed: it is read aloud, searched, and filed the same way.

Per-user addresses rather than one shared inbox on purpose. A shared inbox
would make the service the subscriber and the listeners its audience, which is
republishing. With her own address she is the subscriber, and the app is her
mail reader.
"""
