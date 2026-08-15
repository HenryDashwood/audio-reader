from audioreader.schemas import EpisodeRead, FeedRead


def feed(image: str | None) -> FeedRead:
    return FeedRead.model_validate(
        {
            "id": 1,
            "url": "https://f/1",
            "title": "T",
            "description": None,
            "image_url": image,
            "episode_count": 1,
        }
    )


def episode(audio: str | None) -> EpisodeRead:
    return EpisodeRead.model_validate(
        {
            "id": 1,
            "title": "T",
            "description": None,
            "audio_url": audio,
            "duration_seconds": None,
            "published_at": None,
            "link": None,
        }
    )


class TestMediaURLsAreSecure:
    def test_upgrades_http_audio(self):
        # iOS App Transport Security refuses plain HTTP, so an http:// episode
        # simply will not play. Most podcast hosts serve the same file
        # over https.
        assert episode("http://open.live.bbc.co.uk/x.mp3").audio_url == ("https://open.live.bbc.co.uk/x.mp3")

    def test_upgrades_http_artwork(self):
        assert feed("http://ichef.bbci.co.uk/a.jpg").image_url == "https://ichef.bbci.co.uk/a.jpg"

    def test_leaves_https_alone(self):
        url = "https://cdn.example.com/a.mp3"
        assert episode(url).audio_url == url

    def test_leaves_missing_urls_alone(self):
        assert episode(None).audio_url is None
        assert feed(None).image_url is None

    def test_does_not_touch_the_path(self):
        # BBC audio URLs contain the literal string "proto/http" in the path,
        # which must survive untouched.
        upgraded = episode("http://o.bbc.co.uk/mediaset/proto/http/vpid/x.mp3").audio_url
        assert upgraded == "https://o.bbc.co.uk/mediaset/proto/http/vpid/x.mp3"
