"""GET /feeds/{id}/episodes?q=: finding an episode inside one show."""

from audioreader.models import Episode, Feed


async def make_feed(session, titles: list[tuple[str, str]]) -> int:
    """A subscribed feed whose episodes have the given (title, description)."""
    feed = Feed(url="https://archive.example.com/feed", title="The Archive")
    for index, (title, description) in enumerate(titles):
        feed.episodes.append(
            Episode(
                guid=f"e-{index}",
                title=title,
                description=description,
                audio_url=f"https://cdn.example.com/{index}.mp3",
            )
        )
    session.add(feed)
    await session.commit()
    return feed.id


async def subscribe_to(client, session, feed_id: int) -> None:
    from sqlalchemy import select

    from audioreader.models import Subscription, User

    user = await session.scalar(select(User))
    session.add(Subscription(user_id=user.id, feed_id=feed_id))
    await session.commit()


async def search(client, feed_id: int, query: str | None = None) -> list[str]:
    url = f"/feeds/{feed_id}/episodes"
    if query is not None:
        url += f"?q={query}"
    return [episode["title"] for episode in (await client.get(url)).json()]


class TestEpisodeSearch:
    async def test_finds_an_episode_by_a_word_in_its_title(self, client, session):
        feed_id = await make_feed(
            session,
            [("The eruption of Krakatoa", ""), ("The Peasants' Revolt", ""), ("Volcanoes", "")],
        )
        await subscribe_to(client, session, feed_id)

        assert await search(client, feed_id, "krakatoa") == ["The eruption of Krakatoa"]

    async def test_finds_an_episode_by_a_word_in_its_description(self, client, session):
        feed_id = await make_feed(
            session,
            [("Episode 401", "Melvyn Bragg discusses the Delian League"), ("Episode 402", "Something else")],
        )
        await subscribe_to(client, session, feed_id)

        assert await search(client, feed_id, "delian") == ["Episode 401"]

    async def test_a_second_word_narrows_rather_than_widens(self, client, session):
        # A search box, not a spoken phrase: typing more means meaning less.
        feed_id = await make_feed(
            session,
            [("Roman roads", ""), ("Roman Britain and its coins", ""), ("Coins of the Raj", "")],
        )
        await subscribe_to(client, session, feed_id)

        assert await search(client, feed_id, "roman coins") == ["Roman Britain and its coins"]

    async def test_a_prefix_finds_the_whole_word(self, client, session):
        feed_id = await make_feed(session, [("Volcanoes", ""), ("The Peasants' Revolt", "")])
        await subscribe_to(client, session, feed_id)

        assert await search(client, feed_id, "volcan") == ["Volcanoes"]

    async def test_a_short_word_is_not_dropped(self, client, session):
        # The voice path discards words this short because a transcript is
        # full of filler. Someone who typed "ai" meant it.
        feed_id = await make_feed(session, [("AI and the labour market", ""), ("Roman roads", "")])
        await subscribe_to(client, session, feed_id)

        assert await search(client, feed_id, "ai") == ["AI and the labour market"]

    async def test_accents_do_not_have_to_be_typed(self, client, session):
        feed_id = await make_feed(session, [("The Rubáiyát of Omar Khayyám", ""), ("Roman roads", "")])
        await subscribe_to(client, session, feed_id)

        assert await search(client, feed_id, "rubaiyat") == ["The Rubáiyát of Omar Khayyám"]

    async def test_no_match_is_an_empty_list_not_the_whole_feed(self, client, session):
        # The failure that matters: a search that silently ignores its query
        # looks exactly like a search that found everything.
        feed_id = await make_feed(session, [("Roman roads", ""), ("Volcanoes", "")])
        await subscribe_to(client, session, feed_id)

        assert await search(client, feed_id, "xylophone") == []

    async def test_an_empty_query_is_the_whole_feed(self, client, session):
        feed_id = await make_feed(session, [("Roman roads", ""), ("Volcanoes", "")])
        await subscribe_to(client, session, feed_id)

        assert len(await search(client, feed_id, "%20")) == 2
        assert len(await search(client, feed_id)) == 2

    async def test_it_reaches_past_the_page_the_app_has_loaded(self, client, session):
        # The whole point: the app holds the newest fifty, and the episode
        # being looked for is very often older than that.
        feed_id = await make_feed(session, [(f"Episode {n}", "") for n in range(60)] + [("Krakatoa", "")])
        await subscribe_to(client, session, feed_id)

        assert await search(client, feed_id, "krakatoa") == ["Krakatoa"]

    async def test_another_persons_feed_is_still_not_searchable(self, client, session):
        feed_id = await make_feed(session, [("Roman roads", "")])

        assert (await client.get(f"/feeds/{feed_id}/episodes?q=roman")).status_code == 404
