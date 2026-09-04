import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse

from audioreader import telemetry
from audioreader.auth import service as auth_service
from audioreader.config import redacted_database_url, settings
from audioreader.db import SessionMaker
from audioreader.feeds.poller import poll_all_feeds, poll_lock, prune_orphaned_feeds
from audioreader.newsletters.companions import attach_missing_companions
from audioreader.newsletters.service import prune_newsletters, tell_left_senders
from audioreader.routers import auth, commands, events, feeds, inbound, newsletters
from audioreader.settings_types import LLMProvider

logging.basicConfig(level=logging.INFO)
# Before the app is built, so the instrumentation is in place by the time
# anything it hooks into runs. Without a token this does nothing observable.
telemetry.configure(service_name="audioreader-api")
logger = logging.getLogger(__name__)

STATIC_DIR = Path(__file__).parent / "static"


async def _poll_forever(interval_seconds: int) -> None:
    # Sleep first: subscribing already ingests a feed's episodes, so there is
    # nothing to gain from polling at boot, and crash-looping deploys should
    # not hammer feed servers.
    while True:
        await asyncio.sleep(interval_seconds)
        try:
            async with SessionMaker() as session, poll_lock(session) as acquired:
                if not acquired:
                    # Another replica is already polling. Nothing is wrong;
                    # doing it again would just double the load on other
                    # people's feed servers.
                    logger.info("poll pass skipped: another replica holds the lock")
                    continue
                summary = await poll_all_feeds(session, spacing_seconds=settings.feed_poll_spacing_seconds)
                # Under the same lock, and after polling: cleanup is the least
                # urgent thing here and must never delay new episodes.
                await prune_orphaned_feeds(session)
                await prune_newsletters(session)
                # Newsletters whose feed on the web has not been found yet.
                # After the poll, like the cleanups: it fetches other people's
                # sites and must never delay new episodes.
                await attach_missing_companions(session)
                # Senders she left or blocked that have not yet accepted.
                await tell_left_senders(session)
            logger.info(
                "poll pass: %d ok, %d failed (%d throttled), %d new episodes",
                summary.polled,
                summary.failed,
                summary.throttled,
                summary.episodes_added,
            )
            if summary.failing:
                logger.error("feeds needing attention: %s", ", ".join(summary.failing))
        except Exception:
            logger.exception("poll pass crashed; will retry next interval")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    # First thing in the logs, so a misconfigured deployment is obvious
    # immediately rather than as a connection error further down.
    if settings.llm_provider is LLMProvider.OPENROUTER:
        model = settings.openrouter_model
    elif settings.llm_provider is LLMProvider.OPENAI:
        model = settings.openai_model
    else:
        model = settings.llm_model
    logger.info(
        "starting: database=%s llm=%s/%s poll=%ss",
        redacted_database_url(settings.database_url),
        settings.llm_provider,
        model,
        settings.poll_interval_seconds,
    )

    if settings.development_auth_enabled:
        async with SessionMaker() as session:
            await auth_service.development_user(session)
        logger.warning("development authentication is enabled for local clients")

    poll_task = None
    if settings.poll_interval_seconds > 0:
        poll_task = asyncio.create_task(_poll_forever(settings.poll_interval_seconds))
    yield
    if poll_task is not None:
        poll_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await poll_task


def create_app() -> FastAPI:
    app = FastAPI(title="audioreader", lifespan=lifespan)
    telemetry.instrument_app(app)

    @app.get("/health", tags=["health"])
    async def health() -> dict[str, str]:
        """Liveness, deliberately without touching the database.

        The platform restarts the service when this fails, so it must answer
        the question "is this process able to serve?" and nothing else. Folding
        a database check in here would turn a thirty-second Postgres blip into
        a restart loop, taking down an app that would otherwise have recovered
        on its own. Database trouble surfaces as failing requests and in the
        startup log line, which is where it belongs.
        """
        return {"status": "ok"}

    @app.get("/privacy", include_in_schema=False)
    async def privacy() -> FileResponse:
        """The privacy policy, at a stable public URL.

        Served from the API rather than hosted separately because App Store
        Connect and TestFlight both require a link that keeps working — one
        fewer thing to renew, forget, or let lapse. Plain semantic HTML, since
        the people most likely to read it will be doing so with a screen
        reader.
        """
        return FileResponse(STATIC_DIR / "privacy.html", media_type="text/html")

    @app.get("/support", include_in_schema=False)
    async def support() -> FileResponse:
        """Public help and contact details for the App Store listing."""
        return FileResponse(STATIC_DIR / "support.html", media_type="text/html")

    app.include_router(auth.router)
    app.include_router(feeds.router)
    app.include_router(feeds.episodes_router)
    app.include_router(feeds.search_router)
    app.include_router(commands.router)
    app.include_router(events.router)
    app.include_router(newsletters.router)
    app.include_router(inbound.router)
    return app


app = create_app()
