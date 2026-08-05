from audioreader.text import for_speech, summarise


class TestSummarise:
    def test_strips_html_tags(self):
        assert summarise("<p>Hello <em>there</em></p>") == "Hello there"

    def test_unescapes_entities(self):
        assert summarise("Bach &amp; Handel &mdash; a rivalry") == "Bach & Handel — a rivalry"

    def test_collapses_whitespace(self):
        assert summarise("<p>One</p>\n\n<p>Two</p>   <p>Three</p>") == "One Two Three"

    def test_truncates_on_word_boundary(self):
        text = "The Delian League transformed the geopolitics of the classical world"
        assert summarise(text, limit=30) == "The Delian League transformed…"

    def test_short_text_is_untouched(self):
        assert summarise("A short blurb", limit=100) == "A short blurb"

    def test_handles_none(self):
        assert summarise(None) == ""

    def test_drops_script_and_style_content(self):
        assert summarise("<style>p{color:red}</style><p>Real text</p>") == "Real text"


class TestForSpeech:
    def test_removes_urls(self):
        spoken = for_speech("Read more at https://example.com/very/long/path today")
        assert "http" not in spoken
        assert spoken == "Read more at today"

    def test_strips_html_too(self):
        assert for_speech("<p>Spoken <b>aloud</b></p>") == "Spoken aloud"
