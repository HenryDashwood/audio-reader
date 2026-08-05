from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.commands import service
from audioreader.db import get_session
from audioreader.llm.client import LLMClient, LLMError
from audioreader.llm.provider import get_llm_client
from audioreader.schemas import CommandRequest, CommandResponse, EpisodeRead

router = APIRouter(tags=["commands"])

Session = Annotated[AsyncSession, Depends(get_session)]
LLM = Annotated[LLMClient, Depends(get_llm_client)]

# Even failures must give the app something to say: an error tone alone tells
# a blind user nothing about what went wrong or what to do next.
OUTAGE_RESPONSE = "Sorry, I cannot reach my assistant right now. Please try again in a moment."


@router.post("/command")
async def command(body: CommandRequest, session: Session, llm: LLM) -> CommandResponse:
    try:
        result = await service.interpret(session, llm, transcript=body.transcript)
    except LLMError as exc:
        raise HTTPException(
            status_code=503,
            detail={"spoken_response": OUTAGE_RESPONSE, "error": str(exc)},
        ) from exc

    return CommandResponse(
        action=result.action.value,
        spoken_response=result.spoken_response,
        episode=EpisodeRead.model_validate(result.episode) if result.episode else None,
    )
