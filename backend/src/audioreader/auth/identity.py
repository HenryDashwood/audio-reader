from typing import Protocol


class VerifiedIdentity(Protocol):
    @property
    def subject(self) -> str: ...

    @property
    def email(self) -> str | None: ...
