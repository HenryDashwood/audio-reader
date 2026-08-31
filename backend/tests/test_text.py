from audioreader import text
from audioreader.text import article_paragraphs, article_text, for_speech, summarise, word_count


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


class TestArticleText:
    def test_paragraphs_survive(self):
        html = "<p>First point.</p><p>Second point.</p>"
        assert article_paragraphs(html) == ["First point.", "Second point."]

    def test_headings_are_their_own_paragraph(self):
        html = "<h2>The Delian League</h2><p>It began as an alliance.</p>"
        assert article_paragraphs(html) == ["The Delian League", "It began as an alliance."]

    def test_inline_markup_does_not_split(self):
        html = "<p>Both <em>Athens</em> and <a href='https://x.test'>Sparta</a> agreed.</p>"
        assert article_paragraphs(html) == ["Both Athens and Sparta agreed."]

    def test_list_items_split(self):
        html = "<ul><li>One</li><li>Two</li></ul>"
        assert article_paragraphs(html) == ["One", "Two"]

    def test_raw_urls_dropped_link_text_kept(self):
        html = "<p>See <a href='https://x.test/paper'>the paper</a> at https://x.test/paper</p>"
        assert article_paragraphs(html) == ["See the paper at"]

    def test_script_and_style_dropped(self):
        html = "<style>p{}</style><p>Real</p><script>var x=1</script>"
        assert article_paragraphs(html) == ["Real"]

    def test_article_text_joins_with_blank_lines(self):
        assert article_text("<p>One</p><p>Two</p>") == "One\n\nTwo"

    def test_handles_none_and_empty(self):
        assert article_paragraphs(None) == []
        assert article_text("") == ""


class TestWordCount:
    def test_counts_prose_not_punctuation(self):
        assert word_count("One, two... three! -- four?") == 4

    def test_contractions_and_hyphenated_compounds_are_one_word_each(self):
        assert word_count("It's a reader-friendly count") == 4

    def test_handles_none(self):
        assert word_count(None) == 0


class TestSearchKey:
    def test_folds_accents_the_transcript_will_not_have(self):
        # She says "Rubaiyat"; the feed says "Rubáiyát".
        assert "rubaiyat" in text.search_key("The Rubáiyát of Omar Khayyám")

    def test_indexes_a_ligature_under_every_spelling(self):
        # The failure this exists for: the BBC writes "Æthelstan", speech
        # recognition writes "Athelstan", and neither contains the other.
        spellings = text.search_key("Æthelstan").split()
        assert "athelstan" in spellings
        assert "aethelstan" in spellings

    def test_strips_html_from_descriptions(self):
        assert text.search_key("<p>With <b>guests</b> on 1815.</p>") == "with guests on 1815"

    def test_joins_the_parts_it_is_given(self):
        key = text.search_key("Sleep", "<p>Melvyn Bragg and guests discuss sleep.</p>")
        assert key.startswith("sleep melvyn bragg")

    def test_words_stay_separate_so_a_match_cannot_straddle_them(self):
        # "onsleep" must not be findable across the boundary.
        assert "onsleep" not in text.search_key("Bragg on", "Sleep")

    def test_survives_nothing(self):
        assert text.search_key(None, "", None) == ""

    def test_is_bounded(self):
        assert len(text.search_key("word " * 5000, limit=100)) <= 100

    def test_a_word_with_several_ligatures_does_not_multiply_out(self):
        assert len(text.search_key("æœß").split()) <= 4
