"""Encryption for the few third-party credentials we have to keep verbatim.

Most secrets here are only ever compared, never replayed, so they are stored
as hashes — that is what `auth.service` does with session tokens. Apple refresh
tokens are the exception: revoking an account with Apple means sending the
token back, so the real value has to survive in the database.

Encrypting it means a leaked dump is not a pile of usable credentials. It is
not a defence against someone who already has the deployment's environment,
since the key lives there too — the threat it covers is a backup, a snapshot,
or read access to the database on its own.

Every failure here is deliberately soft. A token that cannot be decrypted (key
rotated, key lost, row written before encryption existed) costs the ability to
notify Apple of one deletion. It must never cost the deletion itself.
"""

import logging

from cryptography.fernet import Fernet, InvalidToken

from audioreader.config import settings

logger = logging.getLogger(__name__)

#: Marks a value this module encrypted, so rows written before encryption was
#: switched on are still readable rather than being mistaken for corrupt ones.
PREFIX = "enc:v1:"


def _cipher() -> Fernet | None:
    if not settings.apple_token_encryption_key:
        return None
    try:
        return Fernet(settings.apple_token_encryption_key.encode())
    except (ValueError, TypeError):
        # A malformed key is a deployment mistake worth shouting about, but not
        # one that should stop anybody signing in.
        logger.error("AUDIOREADER_APPLE_TOKEN_ENCRYPTION_KEY is not a valid Fernet key")
        return None


def encrypt(value: str) -> str:
    """Encrypt for storage, or return the value unchanged if no key is set."""
    cipher = _cipher()
    if cipher is None:
        return value
    return PREFIX + cipher.encrypt(value.encode()).decode()


def decrypt(value: str | None) -> str | None:
    """Reverse `encrypt`. Returns None when the value cannot be recovered."""
    if value is None:
        return None
    if not value.startswith(PREFIX):
        # Written before encryption was turned on. Still usable.
        return value

    cipher = _cipher()
    if cipher is None:
        logger.warning("an encrypted token was stored but no key is configured to read it")
        return None
    try:
        return cipher.decrypt(value.removeprefix(PREFIX).encode()).decode()
    except InvalidToken:
        logger.warning("stored token could not be decrypted; the key has probably changed")
        return None
