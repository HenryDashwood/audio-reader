import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from audioreader.config import redacted_database_url, settings
from audioreader.db import SessionMaker
from audioreader.feeds.poller import poll_all_feeds
from audioreader.routers import auth, commands, feeds
from audioreader.settings_types import LLMProvider

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


async def _poll_forever(interval_seconds: int) -> None:
    # Sleep first: subscribing already ingests a feed's episodes, so there is
    # nothing to gain from polling at boot, and crash-looping deploys should
    # not hammer feed servers.
    while True:
        await asyncio.sleep(interval_seconds)
        try:
            async with SessionMaker() as session:
                summary = await poll_all_feeds(session)
            logger.info(
                "poll pass: %d ok, %d failed, %d new episodes",
                summary.polled,
                summary.failed,
                summary.episodes_added,
            )
        except Exception:
            logger.exception("poll pass crashed; will retry next interval")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    # First thing in the logs, so a misconfigured deployment is obvious
    # immediately rather than as a connection error further down.
    logger.info(
        "starting: database=%s llm=%s/%s poll=%ss",
        redacted_database_url(settings.database_url),
        settings.llm_provider,
        settings.openrouter_model
        if settings.llm_provider is LLMProvider.OPENROUTER
        else settings.llm_model,
        settings.poll_interval_seconds,
    )

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
    app.include_router(auth.router)
    app.include_router(feeds.router)
    app.include_router(feeds.episodes_router)
    app.include_router(commands.router)
    return app


app = create_app()
