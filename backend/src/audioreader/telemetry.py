"""Where the service reports what it is doing, and how well it is doing it.

Two questions are being asked here, and they want different answers. "Is the
service up, and what broke?" is answered by traces and the existing log lines,
which now go to Logfire as well as to stdout. "Did we understand her?" is not
visible in either, because a command that plays the wrong episode is a
completely successful HTTP request. That one is answered by the attributes on
the `command` span in `routers/commands.py`.

Nothing here is required for the app to run. With no `LOGFIRE_TOKEN` set —
tests, a laptop, a CI run — `send_to_logfire="if-token-present"` means spans
are created and dropped on the floor, and the service behaves exactly as it did
before any of this existed.
"""

import logging
import os

import logfire
from opentelemetry import trace

from audioreader.config import settings

#: The EU instance, which is where the project lives. Logfire's default is the
#: US one, and a token issued for one region is not accepted by the other, so
#: this has to be stated rather than inferred.
LOGFIRE_BASE_URL = "https://logfire-eu.pydantic.dev"


def configure(service_name: str) -> None:
    """Set telemetry up for this process. Call once, before anything else.

    `service_name` separates the two things that run: the API answering the
    phone, and the feed poller, which on a schedule-driven deployment is its
    own process entirely.
    """
    logfire.configure(
        service_name=service_name,
        # Railway injects the commit, so a regression can be pinned to a
        # deploy rather than to "some time last week".
        service_version=os.environ.get("RAILWAY_GIT_COMMIT_SHA"),
        environment=settings.environment,
        # No token, no export. This is what keeps `pytest` and `uvicorn` on a
        # laptop working with no configuration and no network.
        send_to_logfire="if-token-present",
        # Logfire's console exporter would print its own rendering of every
        # span to stdout, on top of the log lines already there. Railway's log
        # view is still the first place anyone looks; leave it as it was.
        console=False,
        # On top of the default patterns (passwords, tokens, keys). The ASGI
        # instrumentation records the caller's IP address on every request
        # span, which answers no question this telemetry exists to answer —
        # there is one user and one phone — and would otherwise be a paragraph
        # in the privacy policy earning nothing.
        scrubbing=logfire.ScrubbingOptions(extra_patterns=["peer.ip", "client.address"]),
        advanced=logfire.AdvancedOptions(base_url=LOGFIRE_BASE_URL),
    )

    # Added to the root logger rather than replacing its handlers: every
    # existing `logger.warning` in the codebase should keep reaching stdout,
    # and now also reach Logfire, without a single call site changing.
    logging.getLogger().addHandler(logfire.LogfireLoggingHandler())

    # Covers both LLM providers (the OpenRouter client is raw httpx) as well as
    # feed fetching, article extraction and the calls to Apple.
    logfire.instrument_httpx()

    # Imported here rather than at module scope: importing `db` builds the
    # engine, and that should stay a consequence of using the database rather
    # than of configuring telemetry.
    from audioreader import db

    # The async engine's synchronous core is what the instrumentation hooks
    # into. asyncpg is deliberately left alone — instrumenting it too would
    # wrap every statement in a second, near-identical span.
    logfire.instrument_sqlalchemy(engine=db.engine.sync_engine)

    # Process and host CPU/memory. Cheap, and the only thing that would show a
    # slow leak as a shape rather than as an eventual restart.
    logfire.instrument_system_metrics()


def annotate(**attributes: str | int | float | bool | None) -> None:
    """Attach attributes to whichever span is currently open.

    So that the pipeline can describe itself from the inside without every
    function having to be handed a span. Everything lands flat on the one
    `command` span, which is what makes it answerable in a single query —
    "how often did we reject the model's pick, and how many episodes had it
    been offered?" would otherwise be a join between a parent and a child.

    A no-op when no span is open, which is the case in most of the test suite.
    """
    span = trace.get_current_span()
    if not span.is_recording():
        return
    for key, value in attributes.items():
        if value is not None:
            span.set_attribute(key, value)


def instrument_app(app) -> None:
    """Trace every request to `app`.

    Kept apart from `configure` because the app is built per process *and* per
    test, while configuration happens once.
    """
    logfire.instrument_fastapi(app, request_attributes_mapper=_request_attributes)


def _request_attributes(request, attributes: dict) -> dict | None:
    """Record that a request failed validation, never what it contained.

    The default mapper attaches every parsed endpoint argument to the span.
    For `POST /command` those arguments are the spoken transcript and the
    `User` row itself — her words and her email address, uploaded on every
    request, whatever the transcript setting below says. So the values are
    dropped here and the interesting ones are re-attached deliberately, one at
    a time, in `routers/commands.py`.

    Validation errors are kept: a 422 from the app is a bug in the app, and
    that is exactly the case where the payload shape matters.
    """
    errors = attributes.get("errors")
    if not errors:
        return None
    return {"errors": errors}
