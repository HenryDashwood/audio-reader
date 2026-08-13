"""A small in-process rate limiter, used to bound what /command can cost.

Every spoken command is an LLM call, and finding an unknown publication's feed
can add a web-search call with a two-minute timeout on top. A client stuck in a
retry loop — or a microphone button being jabbed by someone who cannot see that
it is already listening — would otherwise run up a bill with nobody watching.

In-process on purpose: this deployment runs a single replica, and a limiter
that needed Redis would be one more thing between her and playing a podcast.
With several replicas the effective limit multiplies by replica count, which
still bounds the damage; swap in a shared store if that day comes.
"""

import time
from collections import defaultdict, deque
from dataclasses import dataclass


@dataclass(frozen=True)
class Decision:
    allowed: bool
    #: Whole seconds until the caller could succeed. Zero when allowed.
    retry_after: int


class SlidingWindow:
    """Allows `limit` hits per `window_seconds`, counted per key."""

    def __init__(self, limit: int, window_seconds: float) -> None:
        self.limit = limit
        self.window_seconds = window_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def check(self, key: str, now: float | None = None) -> Decision:
        """Record a hit and say whether it is allowed.

        A rejected hit is not recorded: being over the limit must not extend
        the wait every time she tries again.
        """
        now = time.monotonic() if now is None else now
        hits = self._hits[key]
        cutoff = now - self.window_seconds
        while hits and hits[0] <= cutoff:
            hits.popleft()

        if len(hits) >= self.limit:
            # The oldest hit is the one whose expiry frees a slot.
            retry_after = max(1, int(hits[0] + self.window_seconds - now) + 1)
            return Decision(allowed=False, retry_after=retry_after)

        hits.append(now)
        return Decision(allowed=True, retry_after=0)

    def prune(self, now: float | None = None) -> None:
        """Drop keys with no live hits, so an unbounded user base does not
        become an unbounded dict. Cheap enough to run on every check."""
        now = time.monotonic() if now is None else now
        cutoff = now - self.window_seconds
        for key in [key for key, hits in self._hits.items() if not hits or hits[-1] <= cutoff]:
            del self._hits[key]
