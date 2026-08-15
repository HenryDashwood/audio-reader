"""Sign in with Apple: verifying identities, and revoking them.

Signing in needs no secret of ours. The app hands us the JWT Apple issued
on-device; we check its signature against Apple's published keys and its
audience against our bundle id.

Revoking does need one — a JWT signed with a Sign in with Apple private key —
which is why the second half of this module is inert unless the deployment has
been given that key. Signing in works either way.
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


#: Apple caps client secrets at six months. Ours are minted per request and
#: thrown away, so this only has to outlive the call it is made for.
CLIENT_SECRET_TTL_SECONDS = 300


class AppleRevoker:
    """Tells Apple when an account has gone.

    Guideline 5.1.1(v) asks that deleting an account also revokes the Sign in
    with Apple grant. That takes a token, which takes an authorization code
    exchanged at sign-in — so this class covers both ends of that.

    Nothing here is allowed to raise into a request. Sign-in must not fail
    because the exchange did, and deletion must not fail because Apple was
    unreachable: her data goes either way, and an un-revoked grant is a loose
    end to retry, not a reason to keep her account alive.
    """

    def __init__(
        self,
        *,
        client_id: str,
        team_id: str,
        key_id: str,
        private_key: str,
        token_url: str,
        revoke_url: str,
    ) -> None:
        self.client_id = client_id
        self.team_id = team_id
        self.key_id = key_id
        self.private_key = private_key
        self.token_url = token_url
        self.revoke_url = revoke_url

    def client_secret(self, now: int | None = None) -> str:
        """The short-lived JWT Apple accepts in place of a client secret.

        Signed ES256 with the .p8, which is why the key itself is what the
        deployment holds rather than a pre-made secret: these expire.
        """
        issued = now if now is not None else int(time.time())
        return jwt.encode(
            {
                "iss": self.team_id,
                "iat": issued,
                "exp": issued + CLIENT_SECRET_TTL_SECONDS,
                "aud": APPLE_ISSUER,
                "sub": self.client_id,
            },
            self.private_key,
            algorithm="ES256",
            headers={"kid": self.key_id},
        )

    async def exchange_code(self, authorization_code: str) -> str | None:
        """Trade the app's one-time code for a refresh token to keep.

        The code is single-use and expires within minutes of the sign-in that
        produced it, so this happens during login or not at all.
        """
        payload = {
            "grant_type": "authorization_code",
            "code": authorization_code,
            "client_id": self.client_id,
            "client_secret": self.client_secret(),
        }
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                response = await client.post(self.token_url, data=payload)
                response.raise_for_status()
                return response.json().get("refresh_token")
        except httpx.HTTPError as exc:
            logger.warning("Apple code exchange failed: %s", exc)
            return None
        except ValueError:
            logger.warning("Apple code exchange returned something that was not JSON")
            return None
        except Exception:
            # Broad on purpose. Everything this method exists for is optional;
            # nothing it can do wrong is worth failing a sign-in over.
            logger.exception("unexpected failure exchanging an Apple authorization code")
            return None

    async def revoke(self, refresh_token: str) -> bool:
        """Revoke the grant. True when Apple accepted it."""
        payload = {
            "token": refresh_token,
            "token_type_hint": "refresh_token",
            "client_id": self.client_id,
            "client_secret": self.client_secret(),
        }
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                response = await client.post(self.revoke_url, data=payload)
                response.raise_for_status()
        except httpx.HTTPError as exc:
            logger.warning("Apple revocation failed: %s", exc)
            return False
        except Exception:
            # Broad on purpose, and it matters more here than above: this runs
            # inside account deletion, and no failure of ours may leave her
            # account standing after she asked for it to be gone.
            logger.exception("unexpected failure revoking an Apple grant")
            return False
        return True


_revoker: AppleRevoker | None = None


def get_revoker() -> AppleRevoker | None:
    """FastAPI dependency. None when the deployment holds no Apple key, which
    is the ordinary state in development and in the tests."""
    global _revoker
    if not settings.apple_revocation_configured:
        return None
    if _revoker is None:
        _revoker = AppleRevoker(
            client_id=settings.apple_bundle_id,
            team_id=settings.apple_team_id,
            key_id=settings.apple_key_id,
            private_key=settings.apple_private_key,
            token_url=settings.apple_token_url,
            revoke_url=settings.apple_revoke_url,
        )
    return _revoker


_verifier: AppleTokenVerifier | None = None


def get_verifier() -> AppleTokenVerifier:
    """FastAPI dependency; a module-level singleton so the JWKS cache lives
    across requests. Tests override this dependency."""
    global _verifier
    if _verifier is None:
        _verifier = AppleTokenVerifier(audience=settings.apple_bundle_id, jwks_url=settings.apple_jwks_url)
    return _verifier
