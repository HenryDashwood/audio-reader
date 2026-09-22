"""Calendar interpretation and ordering performed by code, not model arithmetic."""

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")


def date_bounds(day: str | None, timezone: str, now: datetime):
    if day is None:
        return None, None
    day = day.strip().casefold()
    zone = ZoneInfo(timezone)
    today = now.astimezone(zone).date()
    if day == "today":
        target = today
    elif day == "yesterday":
        target = today - timedelta(days=1)
    elif day in WEEKDAYS:
        target = today - timedelta(days=(today.weekday() - WEEKDAYS.index(day)) % 7)
    else:
        target = date.fromisoformat(day)
    # Construct each midnight separately: daylight-saving days can be 23 or 25 hours.
    return (
        datetime.combine(target, time.min, zone).astimezone(UTC),
        datetime.combine(target + timedelta(days=1), time.min, zone).astimezone(UTC),
    )


def ordered(candidates, *, latest=True):
    dated = [item for item in candidates if item.published_at is not None]
    return sorted(
        dated,
        key=lambda item: (
            item.published_at.replace(tzinfo=UTC) if item.published_at.tzinfo is None else item.published_at,
            item.id,
        ),
        reverse=latest,
    )


def requested_day(transcript: str) -> str | None:
    """Recognise explicit day references without treating a title as a date."""
    import re

    weekdays = "|".join(WEEKDAYS)
    text = transcript.casefold()
    match = re.search(rf"\b({weekdays})['’]s\b|\b(?:on|from) ({weekdays})\b|\b(today|yesterday)\b", text)
    return next((value for value in match.groups() if value), None) if match else None
