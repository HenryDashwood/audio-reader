from fastapi import APIRouter, Depends, Request

from audioreader.imports import opml, service
from audioreader.routers.feeds import CurrentUser, Session, check_feed_operation_limit

router = APIRouter(prefix="/subscription-imports", tags=["subscription-imports"])


@router.post("/preview", response_model=service.JobRead, dependencies=[Depends(check_feed_operation_limit)])
async def preview(request: Request, session: Session, user: CurrentUser):
    raw = bytearray()
    async for chunk in request.stream():
        if len(raw) + len(chunk) > opml.MAX_BYTES:
            raise service.problem("Choose an OPML file smaller than 5 MiB.", 413)
        raw.extend(chunk)
    try:
        parsed = opml.parse(bytes(raw))
    except opml.InvalidOPML as exc:
        raise service.problem(str(exc), 422) from exc
    job = await service.preview(session, user, parsed)
    return await service.read(session, job)


@router.get("/current", response_model=service.JobRead | None)
async def current(session: Session, user: CurrentUser):
    job = await service.current(session, user)
    return await service.read(session, job) if job else None


@router.get("/{job_id}", response_model=service.JobRead)
async def get(job_id: str, session: Session, user: CurrentUser):
    return await service.read(session, await service.owned(session, user, job_id))


@router.post(
    "/{job_id}/start",
    response_model=service.JobRead,
    status_code=202,
    dependencies=[Depends(check_feed_operation_limit)],
)
async def start(job_id: str, body: service.Start, session: Session, user: CurrentUser):
    job = await service.start(session, user, await service.owned(session, user, job_id), body)
    return await service.read(session, job)


@router.post("/{job_id}/stop", response_model=service.JobRead)
async def stop(job_id: str, session: Session, user: CurrentUser):
    return await service.read(session, await service.stop(session, await service.owned(session, user, job_id)))


@router.post(
    "/{job_id}/retry",
    response_model=service.JobRead,
    status_code=202,
    dependencies=[Depends(check_feed_operation_limit)],
)
async def retry(job_id: str, body: service.Retry, session: Session, user: CurrentUser):
    job = await service.retry(session, user, await service.owned(session, user, job_id), body)
    return await service.read(session, job)
