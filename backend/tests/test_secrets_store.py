"""Encryption of the provider tokens we have to keep verbatim."""

import pytest
from cryptography.fernet import Fernet

from audioreader import secrets_store
from audioreader.config import settings


@pytest.fixture
def key(monkeypatch) -> str:
    generated = Fernet.generate_key().decode()
    monkeypatch.setattr(settings, "apple_token_encryption_key", generated)
    return generated


@pytest.fixture
def no_key(monkeypatch) -> None:
    monkeypatch.setattr(settings, "apple_token_encryption_key", "")


class TestRoundTrip:
    def test_encrypt_then_decrypt(self, key):
        assert secrets_store.decrypt(secrets_store.encrypt("r.token")) == "r.token"

    def test_the_stored_form_is_not_the_token(self, key):
        stored = secrets_store.encrypt("r.token")
        assert "r.token" not in stored

    def test_each_encryption_differs(self, key):
        # Fernet includes a nonce, so identical tokens do not produce identical
        # ciphertext — two users with the same value are not visibly linked.
        assert secrets_store.encrypt("same") != secrets_store.encrypt("same")


class TestWithoutAKey:
    def test_values_pass_through(self, no_key):
        assert secrets_store.encrypt("r.token") == "r.token"
        assert secrets_store.decrypt("r.token") == "r.token"

    def test_an_encrypted_value_is_unreadable_rather_than_fatal(self, key, monkeypatch):
        # Somebody removed the key from the environment after tokens were
        # written. Deletion must still work; only the notifying is lost.
        stored = secrets_store.encrypt("r.token")
        monkeypatch.setattr(settings, "apple_token_encryption_key", "")
        assert secrets_store.decrypt(stored) is None


class TestDegradation:
    def test_a_changed_key_yields_none(self, key, monkeypatch):
        stored = secrets_store.encrypt("r.token")
        monkeypatch.setattr(settings, "apple_token_encryption_key", Fernet.generate_key().decode())
        assert secrets_store.decrypt(stored) is None

    def test_a_malformed_key_yields_none(self, key, monkeypatch):
        stored = secrets_store.encrypt("r.token")
        monkeypatch.setattr(settings, "apple_token_encryption_key", "not-a-fernet-key")
        assert secrets_store.decrypt(stored) is None

    def test_a_malformed_key_does_not_crash_encryption(self, monkeypatch):
        # A deployment typo must not stop anybody signing in.
        monkeypatch.setattr(settings, "apple_token_encryption_key", "not-a-fernet-key")
        assert secrets_store.encrypt("r.token") == "r.token"

    def test_rows_written_before_encryption_still_read(self, key):
        # No prefix means it predates encryption being switched on.
        assert secrets_store.decrypt("plain-old-token") == "plain-old-token"

    def test_none_stays_none(self, key):
        assert secrets_store.decrypt(None) is None
