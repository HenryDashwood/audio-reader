"""The fixed world every eval case runs against.

Real feeds move under you: In Our Time publishes weekly, a blog posts whenever
it likes, and an eval whose right answer drifts is worse than no eval at all.
So the library here is synthetic, but shaped like hers — one long-running
weekly podcast with a deep back catalogue, two chattier ones, and a blog that
posts often enough to crowd the top of any newest-first list. That crowding is
the point: it is what a real subscription list does to a candidate window.

Dates count back from a reference date (today, unless pinned), so "the latest"
and "Tuesday's one" keep meaning what they mean whenever the corpus is run.

Nothing here touches the network. `stub_world()` serves the podcast directory
and every feed from these definitions, and lets only the LLM host through.
"""

import logging
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, time, timedelta
from urllib.parse import urlparse
from xml.sax.saxutils import escape, quoteattr

import httpx
import respx
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.models import Episode, Feed, Subscription, User

logger = logging.getLogger(__name__)

MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY = range(5)


@dataclass(frozen=True)
class Item:
    """One episode or article, as it would arrive from a feed."""

    guid: str
    title: str
    description: str
    published_at: datetime
    duration_seconds: int | None  # None means an article: text, no audio
    link: str | None = None

    @property
    def is_article(self) -> bool:
        return self.duration_seconds is None


@dataclass(frozen=True)
class Show:
    key: str
    title: str
    publisher: str
    feed_url: str
    site_url: str
    description: str
    #: Is she subscribed? Unsubscribed shows exist only in the directory, so
    #: reaching them exercises discovery rather than the candidate list.
    subscribed: bool
    #: Findable through the podcast directory. False for a blog, which is only
    #: reachable by its own domain.
    in_directory: bool = True
    items: tuple[Item, ...] = field(default_factory=tuple)

    def item(self, guid: str) -> Item:
        for item in self.items:
            if item.guid == guid:
                return item
        raise KeyError(f"{self.title} has no item {guid!r}")


def slug(title: str) -> str:
    text = title.casefold().replace("æ", "ae").replace("ø", "o").replace("ß", "ss")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-")


def _dates(reference: date, weekdays: tuple[int, ...], count: int, at: time) -> list[datetime]:
    """The `count` most recent publication times on those weekdays, newest first.

    Never the reference day itself: a feed she has already been served from is
    a feed the poller has already seen.
    """
    out: list[datetime] = []
    day = reference - timedelta(days=1)
    while len(out) < count:
        if day.weekday() in weekdays:
            out.append(datetime.combine(day, at, tzinfo=UTC))
        day -= timedelta(days=1)
    return out


# ---------------------------------------------------------------------------
# In Our Time: the deep back catalogue, newest first.
#
# The ordering carries weight. Everything a case expects to be *findable* sits
# in the first handful, because that is all a 60-item window across four
# subscriptions reaches. Æthelstan sits 70 weeks down on purpose — it is the
# episode that started this corpus.
# ---------------------------------------------------------------------------

IN_OUR_TIME_TOPICS = (
    "Plate Tectonics",
    "Sleep",
    "Dark Matter",
    "Sappho",
    "Rosalind Franklin",
    "The Peasants' Revolt",
    "Enzymes",
    "Marie Antoinette",
    "The Song of Roland",
    "The Zong Massacre",
    "Herodotus",
    "The Corn Laws",
    "Julian of Norwich",
    "Photosynthesis",
    "The Trojan War",
    "Nikola Tesla",
    "The Mabinogion",
    "Purgatory",
    "The Great Stink",
    "Antibiotics",
    "Emmy Noether",
    "The Barbary Corsairs",
    "Wuthering Heights",
    "The Solar Wind",
    "Hannah Arendt",
    "The Gordon Riots",
    "Bird Migration",
    "The Rubaiyat of Omar Khayyam",
    "Kant's Categorical Imperative",
    "The Siege of Malta",
    "Frederick Douglass",
    "Radiocarbon Dating",
    "The Interregnum",
    "Sylvia Plath",
    "The Domesday Book",
    "Pheromones",
    "The Kalevala",
    "The Peterloo Massacre",
    "Ovid's Metamorphoses",
    "Dark Energy",
    "The Vinland Sagas",
    "Thomas Hardy's Poetry",
    "The Fable of the Bees",
    "Vulcanology",
    "The Second Barons' War",
    "The Wealth of Nations",
    "Cnut",
    "The Dead Sea Scrolls",
    "The Time Machine",
    "The Battle of Trafalgar",
    "Rembrandt's The Night Watch",
    "The Migration Period",
    "The Nibelungenlied",
    "Cephalopods",
    "The Rosetta Stone",
    "Mary Wollstonecraft",
    "The Antikythera Mechanism",
    "Tocqueville's Democracy in America",
    "The Aurora Borealis",
    "The Fall of the Aztecs",
    "Simone Weil",
    "The Rite of Spring",
    "Prions",
    "The Battle of Lepanto",
    "George Sand",
    "The Manhattan Project",
    "Coral Reefs",
    "The Council of Nicaea",
    "Æthelstan",
    "The Salem Witch Trials",
    "The Ediacaran Biota",
    "The Iliad",
    "Rosa Luxemburg",
    "The Great Fire of London",
    "Neutron Stars",
    "The Book of Kells",
    "Hildegard of Bingen",
    "The Sasanian Empire",
    "Nuclear Fusion",
    "The Poor Laws",
    "Katsushika Hokusai",
    "The Cambrian Explosion",
    "The Treaty of Versailles",
    "Mansa Musa",
    "Bees",
    "The Divine Comedy",
    "Anaesthetics",
    "The Amritsar Massacre",
    "Spinoza",
    "The Silk Road",
    "Fungi",
    "The Levellers",
    "Zeno's Paradoxes",
    "The Suffragettes",
    "Black Holes",
    "The Anglo-Saxon Chronicle",
    "Ada Lovelace",
    "The Hanseatic League",
    "Tardigrades",
    "The Boxer Rebellion",
    "Boethius",
    "The Younger Dryas",
)

#: Guests, for the cases that ask by who was on rather than what it was about.
#: Kept unique across the catalogue so a guest name identifies one episode.
IN_OUR_TIME_GUESTS = {
    "Dark Matter": "Carolin Crawford, Anne Green and Malcolm Fairbairn",
    "Rosalind Franklin": "Patricia Fara, Judith Howard and Matthew Cobb",
    "Sappho": "Edith Hall, Margaret Reynolds and Tim Whitmarsh",
    "Æthelstan": "Sarah Foot, Tom Licence and David Woodman",
    "The Dead Sea Scrolls": "Sarah Bond, Charlotte Hempel and Joan Taylor",
}

REST_IS_HISTORY_TOPICS = (
    "The Anglo-Saxons: Alfred the Great",
    "The Borgias, Part Two",
    "The Borgias, Part One",
    "Watergate: The Tapes",
    "Watergate: The Break-In",
    "The Great Train Robbery",
    "Alexander the Great in India",
    "Alexander the Great: The Persian Campaign",
    "The Spanish Flu",
    "The Medici",
    "The Siege of Vienna",
    "Byron in Greece",
    "The Han Dynasty",
)

REST_IS_POLITICS_TOPICS = (
    "The Budget, Explained",
    "Coalitions and How They Break",
    "The House of Lords Question",
    "Trade Deals and Their Discontents",
    "The Civil Service",
    "Devolution, Twenty Years On",
    "Party Funding",
    "Local Elections Preview",
    "The Whips' Office",
    "Boundary Changes",
)

ASTRAL_CODEX_TEN_POSTS = (
    "Highlights From The Comments On Prediction Markets",
    "Your Book Review: The Origins of Political Order",
    "Contra Wilkinson On Trapped Priors",
    "Links For August",
    "Model City Monday",
    "Why Do Transformers Generalise?",
    "Book Review: The Dawn of Everything",
    "Open Thread 340",
    "Against Learning From Dramatic Events",
    "Prediction Market FAQ",
    "The Psychopolitics of Trauma",
    "Highlights From The Comments On Nature Versus Nurture",
    "Book Review: The Secret of Our Success",
    "Bay Area House Party, Continued",
    "Open Thread 339",
    "Ivermectin: Much More Than You Wanted To Know",
    "Moderation Is Different From Censorship",
    "Slightly Against Underpopulation Worries",
    "Your Book Review: Njal's Saga",
    "Open Thread 338",
    "Every Bay Area House Party",
    "Justice Creep",
    "Unpredictable Reward, Predictable Happiness",
    "Book Review: Sadly, Porn",
    "Open Thread 337",
)

INFINITE_MONKEY_CAGE_TOPICS = (
    "The Science of Laughter",
    "Volcanoes",
    "Is Maths Invented or Discovered?",
    "The Deep Ocean",
    "Antimatter",
    "Sleep and Dreams",
    "The Sun",
    "Extinction",
)

REST_IS_ENTERTAINMENT_TOPICS = (
    "Awards Season",
    "Why Sequels Sell",
    "The Streaming Wars",
    "Newspaper Diaries",
)


def _podcast_items(prefix: str, titles, dates, blurb, guests=None) -> tuple[Item, ...]:
    guests = guests or {}
    items = []
    for index, (title, published) in enumerate(zip(titles, dates, strict=True)):
        description = blurb(title)
        if extra := guests.get(title):
            description += f" With {extra}."
        items.append(
            Item(
                guid=f"{prefix}-{slug(title)}",
                title=title,
                description=description,
                published_at=published,
                # Varied but deterministic: 42 to 57 minutes.
                duration_seconds=2520 + (index * 137) % 900,
            )
        )
    return tuple(items)


def build_world(reference: date | None = None) -> tuple[Show, ...]:
    """Every show in the world, with its items dated against `reference`."""
    reference = reference or date.today()
    morning, midday = time(5, 0), time(12, 30)

    in_our_time = Show(
        key="in_our_time",
        title="In Our Time",
        publisher="BBC Radio 4",
        feed_url="https://podcasts.files.bbci.co.uk/b006qykl.rss",
        site_url="https://www.bbc.co.uk/programmes/b006qykl",
        description="Melvyn Bragg and guests discuss the history of ideas.",
        subscribed=True,
        items=_podcast_items(
            "iot",
            IN_OUR_TIME_TOPICS,
            _dates(reference, (THURSDAY,), len(IN_OUR_TIME_TOPICS), morning),
            lambda title: f"Melvyn Bragg and guests discuss {title}.",
            IN_OUR_TIME_GUESTS,
        ),
    )

    rest_is_history = Show(
        key="rest_is_history",
        title="The Rest Is History",
        publisher="Goalhanger",
        feed_url="https://feeds.megaphone.fm/GLT4787413333",
        site_url="https://therestishistory.com",
        description="Tom Holland and Dominic Sandbrook on the past.",
        subscribed=True,
        items=_podcast_items(
            "trih",
            REST_IS_HISTORY_TOPICS,
            _dates(reference, (MONDAY, WEDNESDAY), len(REST_IS_HISTORY_TOPICS), morning),
            lambda title: f"Tom Holland and Dominic Sandbrook discuss {title}.",
        ),
    )

    rest_is_politics = Show(
        key="rest_is_politics",
        title="The Rest Is Politics",
        publisher="Goalhanger",
        feed_url="https://feeds.megaphone.fm/GLT5347391293",
        site_url="https://therestispolitics.com",
        description="Rory Stewart and Alastair Campbell disagree agreeably.",
        subscribed=True,
        items=_podcast_items(
            "trip",
            REST_IS_POLITICS_TOPICS,
            _dates(reference, (TUESDAY,), len(REST_IS_POLITICS_TOPICS), morning),
            lambda title: f"Rory Stewart and Alastair Campbell discuss {title}.",
        ),
    )

    acx_dates = _dates(reference, (MONDAY, THURSDAY), len(ASTRAL_CODEX_TEN_POSTS), midday)
    astral_codex_ten = Show(
        key="astral_codex_ten",
        title="Astral Codex Ten",
        publisher="Scott Alexander",
        feed_url="https://www.astralcodexten.com/feed",
        site_url="https://www.astralcodexten.com",
        description="A blog about medicine, psychiatry, science and rationality.",
        subscribed=True,
        # A blog is not in the podcast directory: it is only reachable by name
        # through web discovery, or by its own domain.
        in_directory=False,
        items=tuple(
            Item(
                guid=f"https://www.astralcodexten.com/p/{slug(title)}",
                title=title,
                description=f"{title} — an essay from Astral Codex Ten.",
                published_at=published,
                duration_seconds=None,
                link=f"https://www.astralcodexten.com/p/{slug(title)}",
            )
            for title, published in zip(ASTRAL_CODEX_TEN_POSTS, acx_dates, strict=True)
        ),
    )

    infinite_monkey_cage = Show(
        key="infinite_monkey_cage",
        title="The Infinite Monkey Cage",
        publisher="BBC Radio 4",
        feed_url="https://podcasts.files.bbci.co.uk/b00snr0w.rss",
        site_url="https://www.bbc.co.uk/programmes/b00snr0w",
        description="Brian Cox and Robin Ince take a witty look at science.",
        subscribed=False,
        items=_podcast_items(
            "imc",
            INFINITE_MONKEY_CAGE_TOPICS,
            _dates(reference, (FRIDAY,), len(INFINITE_MONKEY_CAGE_TOPICS), morning),
            lambda title: f"Brian Cox and Robin Ince discuss {title}.",
        ),
    )

    rest_is_entertainment = Show(
        key="rest_is_entertainment",
        title="The Rest Is Entertainment",
        publisher="Goalhanger",
        feed_url="https://feeds.megaphone.fm/GLT8891234567",
        site_url="https://therestisentertainment.com",
        description="Richard Osman and Marina Hyde on how the media works.",
        subscribed=False,
        items=_podcast_items(
            "trie",
            REST_IS_ENTERTAINMENT_TOPICS,
            _dates(reference, (WEDNESDAY,), len(REST_IS_ENTERTAINMENT_TOPICS), morning),
            lambda title: f"Richard Osman and Marina Hyde discuss {title}.",
        ),
    )

    slow_boring_dates = _dates(reference, (MONDAY, WEDNESDAY, FRIDAY), 6, midday)
    slow_boring = Show(
        key="slow_boring",
        title="Slow Boring",
        publisher="Matthew Yglesias",
        feed_url="https://www.slowboring.com/feed",
        site_url="https://www.slowboring.com",
        description="Politics and policy, at length.",
        subscribed=False,
        in_directory=False,
        items=tuple(
            Item(
                guid=f"https://www.slowboring.com/p/{slug(title)}",
                title=title,
                description=f"{title} — a post from Slow Boring.",
                published_at=published,
                duration_seconds=None,
                link=f"https://www.slowboring.com/p/{slug(title)}",
            )
            for title, published in zip(
                (
                    "The case for more housing",
                    "Mailbag: tariffs and taxes",
                    "What the polls are missing",
                    "Against doomerism",
                    "Transit costs, again",
                    "Thursday thread",
                ),
                slow_boring_dates,
                strict=True,
            )
        ),
    )

    return (
        in_our_time,
        rest_is_history,
        rest_is_politics,
        astral_codex_ten,
        infinite_monkey_cage,
        rest_is_entertainment,
        slow_boring,
    )


# ---------------------------------------------------------------------------
# Seeding
# ---------------------------------------------------------------------------


async def seed(session: AsyncSession, user: User, world: tuple[Show, ...]) -> None:
    """Put her subscriptions in the database, as the poller would have."""
    for show in world:
        if not show.subscribed:
            continue
        feed = Feed(
            url=show.feed_url,
            title=show.title,
            description=show.description,
            site_url=show.site_url,
        )
        feed.episodes = [
            Episode(
                guid=item.guid,
                title=item.title,
                description=item.description,
                audio_url=None if item.is_article else f"https://cdn.example.com/{item.guid}.mp3",
                duration_seconds=item.duration_seconds,
                published_at=item.published_at,
                link=item.link,
            )
            for item in show.items
        ]
        session.add(feed)
        session.add(Subscription(user_id=user.id, feed=feed))
    await session.commit()


# ---------------------------------------------------------------------------
# The network, as far as the pipeline can tell
# ---------------------------------------------------------------------------


def feed_xml(show: Show) -> bytes:
    items = []
    for item in show.items:
        stamp = item.published_at.strftime("%a, %d %b %Y %H:%M:%S GMT")
        parts = [
            f"    <title>{escape(item.title)}</title>",
            f'    <guid isPermaLink="false">{escape(item.guid)}</guid>',
            f"    <pubDate>{stamp}</pubDate>",
            f"    <description>{escape(item.description)}</description>",
        ]
        if item.link:
            parts.append(f"    <link>{escape(item.link)}</link>")
        if not item.is_article:
            audio = f"https://cdn.example.com/{item.guid}.mp3"
            parts.append(f'    <enclosure url={quoteattr(audio)} length="41123456" type="audio/mpeg"/>')
            parts.append(f"    <itunes:duration>{item.duration_seconds}</itunes:duration>")
        items.append("  <item>\n" + "\n".join(parts) + "\n  </item>")

    body = "\n".join(items)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel>
  <title>{escape(show.title)}</title>
  <link>{escape(show.site_url)}</link>
  <description>{escape(show.description)}</description>
{body}
</channel>
</rss>
""".encode()


def homepage_html(show: Show) -> bytes:
    """A site that advertises its feed, the way discovery expects to find it."""
    return f"""<!doctype html>
<html><head>
<title>{escape(show.title)}</title>
<link rel="alternate" type="application/rss+xml" title={quoteattr(show.title)}
      href={quoteattr(show.feed_url)}>
</head><body><h1>{escape(show.title)}</h1></body></html>
""".encode()


def _meaningful(text: str) -> set[str]:
    words = re.sub(r"[^a-z0-9 ]", " ", text.casefold()).split()
    return {word for word in words if word not in _DIRECTORY_FILLER}


_DIRECTORY_FILLER = {"the", "a", "an", "of", "and", "to", "podcast", "show", "please"}


def directory_results(term: str, world: tuple[Show, ...], limit: int = 5) -> list[dict]:
    """What the podcast directory would return for a spoken name.

    Modelled on Apple's behaviour rather than on what we wish it did: it is
    fuzzy, it ranks by how much of the query it matched, and it will happily
    return something loosely related rather than nothing. The strictness that
    keeps a misheard name from subscribing her to a stranger lives in
    `feeds.search`, and this stub exists partly to keep exercising it.
    """
    wanted = _meaningful(term)
    if not wanted:
        return []
    scored = []
    for show in world:
        if not show.in_directory:
            continue
        haystack = _meaningful(f"{show.title} {show.publisher}")
        overlap = len(wanted & haystack)
        if overlap:
            scored.append((overlap, show))
    scored.sort(key=lambda pair: (-pair[0], pair[1].title))
    return [
        {
            "collectionName": show.title,
            "artistName": show.publisher,
            "feedUrl": show.feed_url,
            "trackCount": len(show.items),
            "artworkUrl600": f"{show.site_url}/artwork.jpg",
        }
        for _score, show in scored[:limit]
    ]


#: Hosts the eval is allowed to reach for real. Only the model: everything
#: else is served from the definitions above, so a run is reproducible and
#: costs one API call per model turn rather than a walk of the live web.
LLM_HOSTS = ("openrouter.ai", "api.anthropic.com", "api.openai.com")


def stub_world(world: tuple[Show, ...]) -> respx.MockRouter:
    """A router serving the whole world, with the model host passed through.

    Returned unstarted; use it as a context manager around the run. One router
    covers every case, because every case shares this one world — which is
    also what makes it safe to run cases concurrently.
    """
    router = respx.mock(assert_all_called=False)

    for host in LLM_HOSTS:
        router.route(host=host).pass_through()

    router.get("https://itunes.apple.com/search").mock(
        side_effect=lambda request: httpx.Response(
            200,
            json={
                "resultCount": len(results := directory_results(_term(request), world)),
                "results": results,
            },
        )
    )

    for show in world:
        router.get(show.feed_url).mock(
            side_effect=lambda request, show=show: httpx.Response(200, content=feed_xml(show))
        )
        # Both spellings of the site, since a spoken domain arrives bare and
        # real sites redirect the apex to www.
        for host in _site_hosts(show.site_url):
            router.get(f"https://{host}").mock(
                side_effect=lambda request, show=show: httpx.Response(
                    200, content=homepage_html(show), headers={"content-type": "text/html"}
                )
            )

    router.route().mock(side_effect=_offline)
    return router


def _term(request: httpx.Request) -> str:
    return request.url.params.get("term", "")


def _site_hosts(site_url: str) -> tuple[str, ...]:
    host = urlparse(site_url).netloc
    bare = host.removeprefix("www.")
    return (host, bare) if host != bare else (host, f"www.{host}")


def _offline(request: httpx.Request) -> httpx.Response:
    """Anything outside the world is simply not there.

    Raised as a connection error rather than a 404 so it travels the same path
    a genuinely unreachable feed would, and logged so an eval failure caused by
    a missing stub is visible rather than mysterious.
    """
    logger.warning("eval world has no stub for %s %s", request.method, request.url)
    raise httpx.ConnectError(f"not in the eval world: {request.url}", request=request)
