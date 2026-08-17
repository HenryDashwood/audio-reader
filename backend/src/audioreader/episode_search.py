"""Matching words against an episode's title and description.

One definition, two callers: the voice path scores a spoken phrase against the
whole library, and a show's page filters one feed by what was typed into a
search box. They must agree about what a word looks like and where it may
start, or the same three letters would find an episode by voice and not by
hand — a difference nobody could explain and nobody would report.
"""

from sqlalchemy import func, or_, select

from audioreader.models import Episode
from audioreader.text import search_key


def mentions(word: str):
    """Does an episode use this word, or one starting with it?

    Anchored to a word boundary rather than matched anywhere in the string.
    A mis-transcribed "In Our Time" arrived as "in our stand", which searched
    for "stand" — a bare substring of "understanding", and so a match against
    a hundred and seventy episodes of In Our Time, filling the list with
    noise. Prefixes are still matched, because English inflects at the end
    and "volcano" ought to find "volcanoes".

    Searched against the folded `search_text`, so "Rubaiyat" finds
    "Rubáiyát". Rows written before that column existed fall back to their
    title, which still finds most things while a backfill catches up.
    """
    haystack = func.coalesce(Episode.search_text, func.lower(Episode.title))
    return or_(
        haystack.startswith(word, autoescape=True),
        haystack.contains(f" {word}", autoescape=True),
    )


def matching(query: str, statement=None):
    """Narrow a select to episodes answering to every word in `query`.

    Every word, not the best few: this is a search box, and someone who types
    a second word is narrowing what they meant, not adding an alternative.
    Nothing is dropped for being short or common either — the voice path
    discards those because a transcript is full of filler, but a person who
    types "ai" has said exactly what they mean.

    Returns the statement unchanged when the query folds down to nothing, so
    an empty box is the whole feed rather than no results.
    """
    statement = select(Episode) if statement is None else statement
    for word in search_key(query).split():
        statement = statement.where(mentions(word))
    return statement
