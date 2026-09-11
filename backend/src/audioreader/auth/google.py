"""Verify Google ID tokens against the configured web/server OAuth client ID."""

import time
from dataclasses import dataclass

import httpx
import jwt

from audioreader.config import settings


class GoogleVerificationError(Exception):
    pass


@dataclass(frozen=True)
class GoogleIdentity:
    subject: str
    email: str | None


class GoogleTokenVerifier:
    def __init__(self, audience: str, jwks_url: str = "https://www.googleapis.com/oauth2/v3/certs") -> None:
        self.audience = audience
        self.jwks_url = jwks_url
        self._keys: dict[str, jwt.PyJWK] = {}
        self._expires_at = 0.0

    async def verify(self, identity_token: str) -> GoogleIdentity:
        if not self.audience:
            raise GoogleVerificationError("Google sign-in is not configured")
        try:
            header = jwt.get_unverified_header(identity_token)
            kid = header.get("kid")
            if header.get("alg") != "RS256" or not isinstance(kid, str) or not kid:
                raise GoogleVerificationError("Invalid Google token header")
            if kid not in self._keys or time.monotonic() >= self._expires_at:
                await self._fetch_keys()
            key = self._keys.get(kid)
            if key is None:
                raise GoogleVerificationError("Unknown Google signing key")
            claims = jwt.decode(
                identity_token,
                key,
                algorithms=["RS256"],
                audience=self.audience,
                issuer=["https://accounts.google.com", "accounts.google.com"],
                options={"require": ["sub", "aud", "iss", "iat", "exp"]},
            )
            subject = claims["sub"]
            if not isinstance(subject, str) or not subject.strip():
                raise GoogleVerificationError("Missing Google subject")
            # Email is metadata, never an account lookup or linking key.
            email = claims.get("email") if claims.get("email_verified") is True else None
            return GoogleIdentity(subject, email if isinstance(email, str) else None)
        except jwt.InvalidTokenError as exc:
            raise GoogleVerificationError("Invalid Google identity token") from exc

    async def _fetch_keys(self) -> None:
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                response = await client.get(self.jwks_url)
                response.raise_for_status()
            payload = response.json()
            keys = {entry["kid"]: jwt.PyJWK.from_dict(entry) for entry in payload["keys"]}
            if not keys:
                raise ValueError("empty key set")
            lifetime = 3600
            for directive in response.headers.get("cache-control", "").split(","):
                if directive.strip().startswith("max-age="):
                    lifetime = max(0, min(int(directive.split("=", 1)[1]), 86400))
            self._keys = keys
            self._expires_at = time.monotonic() + lifetime
        except (httpx.HTTPError, ValueError, KeyError, TypeError, jwt.PyJWKError) as exc:
            raise GoogleVerificationError("Could not verify Google sign-in; please try again") from exc


_verifier: GoogleTokenVerifier | None = None


def get_google_verifier() -> GoogleTokenVerifier:
    global _verifier
    if _verifier is None or _verifier.audience != settings.google_client_id:
        _verifier = GoogleTokenVerifier(settings.google_client_id)
    return _verifier
