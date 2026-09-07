from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import joinedload

from audioreader import saved
from audioreader.models import Episode, SavedArticle
from audioreader.routers.feeds import CurrentUser, Session, check_feed_operation_limit, episodes_read
from audioreader.schemas import EpisodeRead

router = APIRouter(prefix="/saved", tags=["saved"])


@router.get("")
async def list_saved(session: Session, user: CurrentUser) -> list[EpisodeRead]:
    episodes = list(
        await session.scalars(
            select(Episode)
            .join(SavedArticle)
            .options(joinedload(Episode.feed))
            .where(SavedArticle.user_id == user.id, SavedArticle.saved_at.is_not(None))
            .order_by(SavedArticle.saved_at.desc(), Episode.id.desc())
        )
    )
    return await episodes_read(session, user, episodes)


@router.post("", dependencies=[Depends(check_feed_operation_limit)])
async def save_article(body: saved.SaveRequest, session: Session, user: CurrentUser) -> EpisodeRead:
    episode = await saved.save(session, user, body)
    return (await episodes_read(session, user, [episode]))[0]


@router.post("/{episode_id}/retry", dependencies=[Depends(check_feed_operation_limit)])
async def retry(episode_id: int, session: Session, user: CurrentUser) -> EpisodeRead:
    record = await saved.selection(session, user, episode_id)
    if record is None or record.saved_at is None:
        raise HTTPException(404, detail="saved article not found")
    episode = await saved.save(session, user, saved.SaveRequest(episode_id=episode_id))
    return (await episodes_read(session, user, [episode]))[0]


@router.delete("/{episode_id}", status_code=204)
async def remove(episode_id: int, session: Session, user: CurrentUser) -> None:
    record = await saved.selection(session, user, episode_id)
    if record is not None:
        record.saved_at = None
        await session.commit()
