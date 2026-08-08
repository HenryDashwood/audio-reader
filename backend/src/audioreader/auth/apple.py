"""Verification of Sign in with Apple identity tokens.

The app hands us the JWT Apple issued on-device; we check its signature
against Apple's published keys and its audience against our bundle id.
There is no Apple-side secret involved.
"""

import logging
import time
from dataclasses import dataclass

import httpx
import jwt

from audioreader.config import settings

logger = logging.getLogger(__name__)

APPLE_ISSUER = "https://appleid.apple.com"

# Apple rotates keys rarely; a day-long cache means sign-in does not depend on
# an Apple round-trip. An unknown kid still forces a refetch immediately.
JWKS_CACHE_TTL_SECONDS = 86400


class AppleVerificationError(Exception):
    pass


@dataclass(frozen=True)
class AppleIdentity:
    subject: str
    email: str | None


class AppleTokenVerifier:
    def __init__(self, audience: str, jwks_url: str) -> None:
        self.audience = audience
        self.jwks_url = jwks_url
        self._keys: dict[str, jwt.PyJWK] = {}
        self._fetched_at: float = 0.0

    async def verify(self, identity_token: str) -> AppleIdentity:
        try:
            header = jwt.get_unverified_header(identity_token)
        except jwt.InvalidTokenError as exc:
            raise AppleVerificationError(f"malformed token: {exc}") from exc

        kid = header.get("kid")
        if not isinstance(kid, str):
            raise AppleVerificationError("token header has no kid")

        key = await self._key_for(kid)
        try:
            claims = jwt.decode(
                identity_token,
                key,
                algorithms=["RS256"],
                audience=self.audience,
                issuer=APPLE_ISSUER,
            )
        except jwt.InvalidTokenError as exc:
            raise AppleVerificationError(f"token rejected: {exc}") from exc

        return AppleIdentity(subject=claims["sub"], email=claims.get("email"))

    async def _key_for(self, kid: str) -> jwt.PyJWK:
        stale = time.monotonic() - self._fetched_at > JWKS_CACHE_TTL_SECONDS
        if kid not in self._keys or stale:
            await self._fetch_keys()
        try:
            return self._keys[kid]
        except KeyError:
            raise AppleVerificationError(f"no Apple key with kid {kid!r}") from None

    async def _fetch_keys(self) -> None:
        # httpx rather than PyJWKClient: the latter fetches with blocking
        # urllib, which would stall the event loop and dodge respx in tests.
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                response = await client.get(self.jwks_url)
                response.raise_for_status()
                payload = response.json()
        except httpx.HTTPError as exc:
            raise AppleVerificationError(f"could not fetch Apple keys: {exc}") from exc

        keys = {}
        for entry in payload.get("keys", []):
            try:
                keys[entry["kid"]] = jwt.PyJWK.from_dict(entry)
            except (KeyError, jwt.PyJWKError):
                logger.warning("skipping unusable Apple JWK entry")
        self._keys = keys
        self._fetched_at = time.monotonic()


_verifier: AppleTokenVerifier | None = None


def get_verifier() -> AppleTokenVerifier:
    """FastAPI dependency; a module-level singleton so the JWKS cache lives
    across requests. Tests override this dependency."""
    global _verifier
    if _verifier is None:
        _verifier = AppleTokenVerifier(
            audience=settings.apple_bundle_id, jwks_url=settings.apple_jwks_url
        )
    return _verifier
