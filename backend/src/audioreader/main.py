from fastapi import FastAPI

from audioreader.routers import feeds


def create_app() -> FastAPI:
    app = FastAPI(title="audioreader")
    app.include_router(feeds.router)
    return app


app = create_app()
