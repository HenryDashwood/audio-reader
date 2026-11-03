//! Abbreviations misaki reads as letters or nonsense ("St." as "S T", "km" as "kkm"), written out before it sees them.
//!
//! Context decides where the spelling alone can't: "St. Paul's" is Saint and "Baker St." is Street; a unit is only a
//! unit after a number. Every rewrite is recorded, so a token of the rewritten text maps back to the characters of the
//! original it came from: the app highlights and seeks by the original text.

use regex::Regex;
use std::ops::Range;
use std::sync::LazyLock;

/// The rewritten text, and where each rewrite came from.
pub struct Normalized {
    pub text: String,
    edits: Vec<Edit>, // In order, not overlapping
}

struct Edit {
    original: Range<usize>,
    rewritten: Range<usize>,
}

impl Normalized {
    /// The byte range of the original text that a byte range of the rewritten text came from. Anything touching a
    /// rewrite maps to the whole of what it replaced.
    pub fn to_original(&self, r: Range<usize>) -> Range<usize> {
        let start = self.map(r.start, false);
        start..self.map(r.end, true).max(start)
    }

    fn map(&self, p: usize, end: bool) -> usize {
        let mut delta: isize = 0;
        for e in &self.edits {
            let inside = if end {
                e.rewritten.start < p && p <= e.rewritten.end
            } else {
                e.rewritten.start <= p && p < e.rewritten.end
            };
            if inside {
                return if end { e.original.end } else { e.original.start };
            }
            if e.rewritten.end > p {
                break;
            }
            delta = e.original.end as isize - e.rewritten.end as isize;
        }
        (p as isize + delta) as usize
    }
}

/// Whether the period stays: an abbreviation that ends a sentence still ends it.
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    /// Before a name: "Dr. Brown" -> "Doctor Brown". Only when a capitalised word follows.
    Title,
    /// After a name or number: "Baker St." -> "Baker Street", "Widgets Inc." -> "Widgets Incorporated".
    Trailing,
    /// Anywhere: "approx." -> "approximately".
    Anywhere,
    /// Next to a number: "Jan. 3", "Fig. 3", "3 Jan.".
    Numbered,
}

const ABBREVIATIONS: &[(&str, &str, Kind)] = &[
    ("Prof", "Professor", Kind::Title),
    ("Gen", "General", Kind::Title),
    ("Gov", "Governor", Kind::Title),
    ("Sen", "Senator", Kind::Title),
    ("Rep", "Representative", Kind::Title),
    ("Rev", "Reverend", Kind::Title),
    ("Capt", "Captain", Kind::Title),
    ("Lt", "Lieutenant", Kind::Title),
    ("Col", "Colonel", Kind::Title),
    ("Sgt", "Sergeant", Kind::Title),
    ("Maj", "Major", Kind::Title),
    ("Cmdr", "Commander", Kind::Title),
    ("Adm", "Admiral", Kind::Title),
    ("Pres", "President", Kind::Title),
    ("Supt", "Superintendent", Kind::Title),
    ("Insp", "Inspector", Kind::Title),
    ("Det", "Detective", Kind::Title),
    ("Hon", "Honourable", Kind::Title),
    ("Fr", "Father", Kind::Title),
    ("Mt", "Mount", Kind::Title),
    ("Ft", "Fort", Kind::Title),
    ("Jr", "Junior", Kind::Trailing),
    ("Sr", "Senior", Kind::Trailing),
    ("Inc", "Incorporated", Kind::Trailing),
    ("Ltd", "Limited", Kind::Trailing),
    ("Co", "Company", Kind::Trailing),
    ("Corp", "Corporation", Kind::Trailing),
    ("Bros", "Brothers", Kind::Trailing),
    ("Ave", "Avenue", Kind::Trailing),
    ("Rd", "Road", Kind::Trailing),
    ("Blvd", "Boulevard", Kind::Trailing),
    ("Ln", "Lane", Kind::Trailing),
    ("Sq", "Square", Kind::Trailing),
    ("Hwy", "Highway", Kind::Trailing),
    ("Dept", "Department", Kind::Trailing),
    ("Univ", "University", Kind::Trailing),
    ("Assn", "Association", Kind::Trailing),
    ("Govt", "Government", Kind::Anywhere),
    ("approx", "approximately", Kind::Anywhere),
    ("viz", "namely", Kind::Anywhere),
    ("cf", "compare", Kind::Anywhere),
    ("Intl", "International", Kind::Anywhere),
    ("Natl", "National", Kind::Anywhere),
    ("Jan", "January", Kind::Numbered),
    ("Feb", "February", Kind::Numbered),
    ("Mar", "March", Kind::Numbered),
    ("Apr", "April", Kind::Numbered),
    ("Jun", "June", Kind::Numbered),
    ("Jul", "July", Kind::Numbered),
    ("Aug", "August", Kind::Numbered),
    ("Sep", "September", Kind::Numbered),
    ("Sept", "September", Kind::Numbered),
    ("Oct", "October", Kind::Numbered),
    ("Nov", "November", Kind::Numbered),
    ("Dec", "December", Kind::Numbered),
    ("Mon", "Monday", Kind::Numbered),
    ("Tue", "Tuesday", Kind::Numbered),
    ("Tues", "Tuesday", Kind::Numbered),
    ("Wed", "Wednesday", Kind::Numbered),
    ("Thu", "Thursday", Kind::Numbered),
    ("Thur", "Thursday", Kind::Numbered),
    ("Thurs", "Thursday", Kind::Numbered),
    ("Fri", "Friday", Kind::Numbered),
    ("Sat", "Saturday", Kind::Numbered),
    ("Sun", "Sunday", Kind::Numbered),
    ("Fig", "Figure", Kind::Numbered),
    ("Figs", "Figures", Kind::Numbered),
    ("Vol", "Volume", Kind::Numbered),
    ("Vols", "Volumes", Kind::Numbered),
    ("Ch", "Chapter", Kind::Numbered),
    ("Ste", "Suite", Kind::Numbered),
    ("Apt", "Apartment", Kind::Numbered),
    ("pp", "pages", Kind::Numbered),
    ("p", "page", Kind::Numbered),
];

/// Units after a number, singular and plural.
const UNITS: &[(&str, &str, &str)] = &[
    ("km", "kilometre", "kilometres"),
    ("cm", "centimetre", "centimetres"),
    ("mm", "millimetre", "millimetres"),
    ("kg", "kilogram", "kilograms"),
    ("mg", "milligram", "milligrams"),
    ("lb", "pound", "pounds"),
    ("lbs", "pound", "pounds"),
    ("oz", "ounce", "ounces"),
    ("ft", "foot", "feet"),
    ("mi", "mile", "miles"),
    ("mph", "mile per hour", "miles per hour"),
    ("kph", "kilometre per hour", "kilometres per hour"),
    ("km/h", "kilometre per hour", "kilometres per hour"),
    ("ml", "millilitre", "millilitres"),
    ("kWh", "kilowatt hour", "kilowatt hours"),
    ("MW", "megawatt", "megawatts"),
    ("GW", "gigawatt", "gigawatts"),
    ("kW", "kilowatt", "kilowatts"),
    ("KB", "kilobyte", "kilobytes"),
    ("MB", "megabyte", "megabytes"),
    ("GB", "gigabyte", "gigabytes"),
    ("TB", "terabyte", "terabytes"),
];

static ABBREVIATION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b([A-Za-z]{1,6})\.").unwrap());
static UNIT: LazyLock<Regex> = LazyLock::new(|| {
    let mut units: Vec<_> = UNITS.iter().map(|u| regex::escape(u.0)).collect();
    units.sort_by_key(|u| std::cmp::Reverse(u.len()));
    Regex::new(&format!(r"(\d[\d,]*(?:\.\d+)?)(\s?)({})\b\.?", units.join("|"))).unwrap()
});
/// Money in thousands, millions and so on: "$1M", "£2.5bn", "€300k". misaki reads "$1M" as "one M".
static MONEY_MAGNITUDE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"([$£€])(\d[\d,]*(?:\.\d+)?)\s?(k|K|m|M|mn|bn|b|B|tn|T|thousand|million|billion|trillion)\b").unwrap()
});
static ORDINAL_BEFORE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\d(?:st|nd|rd|th)?\s*$").unwrap());
static ST: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(St|Dr)\.").unwrap());

pub fn normalize(text: &str) -> Normalized {
    let mut rewrites: Vec<(Range<usize>, String)> = Vec::new();

    for m in ST.captures_iter(text) {
        let all = m.get(0).unwrap();
        let (before, after) = (&text[..all.start()], &text[all.end()..]);
        let next = after.trim_start().split(|c: char| !c.is_alphabetic()).next().unwrap_or("");
        let word = if starts_capitalised(after) && !SENTENCE_STARTERS.contains(&next) && !ends_name(before) {
            if &m[1] == "St" { "Saint".to_string() } else { continue } // misaki already says "Doctor"
        } else if ends_capitalised_word(before) || ends_number(before) {
            with_period(if &m[1] == "St" { "Street" } else { "Drive" }, after)
        } else {
            continue;
        };
        rewrites.push((all.range(), word));
    }

    for m in ABBREVIATION.captures_iter(text) {
        let all = m.get(0).unwrap();
        let (before, after) = (&text[..all.start()], &text[all.end()..]);
        if before.ends_with('.') || after.starts_with(char::is_alphabetic) {
            continue; // Part of an initialism: "p.m.", "U.S."
        }
        if &m[1] == "ed" || &m[1] == "eds" {
            // "ed. by" is edited by; "2nd ed." an edition
            let word = if after.trim_start().starts_with("by ") {
                "edited"
            } else if ORDINAL_BEFORE.is_match(before) {
                if &m[1] == "ed" { "edition" } else { "editions" }
            } else {
                continue;
            };
            rewrites.push((all.range(), with_period(word, after)));
            continue;
        }
        let Some(&(_, word, kind)) = ABBREVIATIONS.iter().find(|a| a.0 == &m[1]) else { continue };
        let ok = match kind {
            Kind::Title => starts_capitalised(after),
            Kind::Trailing => ends_capitalised_word(before) || ends_number(before),
            Kind::Anywhere => true,
            Kind::Numbered => starts_number(after) || ends_number(before),
        };
        if ok {
            let word = match kind {
                Kind::Title => word.to_string(),
                Kind::Anywhere if !after.trim().is_empty() => word.to_string(), // Mid-sentence, nearly always
                _ => with_period(word, after),
            };
            rewrites.push((all.range(), word));
        }
    }

    for m in MONEY_MAGNITUDE.captures_iter(text) {
        let currency = match &m[1] {
            "$" => "dollars",
            "£" => "pounds",
            _ => "euros",
        };
        let magnitude = match &m[3] {
            "k" | "K" | "thousand" => "thousand",
            "m" | "M" | "mn" | "million" => "million",
            "bn" | "b" | "B" | "billion" => "billion",
            _ => "trillion",
        };
        rewrites.push((m.get(0).unwrap().range(), format!("{} {magnitude} {currency}", &m[2])));
    }

    for m in UNIT.captures_iter(text) {
        let (number, space, unit) = (m.get(1).unwrap(), m.get(2).unwrap(), m.get(3).unwrap());
        let Some(&(_, one, many)) = UNITS.iter().find(|u| u.0 == unit.as_str()) else { continue };
        let all = m.get(0).unwrap();
        let word = if number.as_str() == "1" { one } else { many };
        let after = &text[all.end()..];
        let word = if all.as_str().ends_with('.') { with_period(word, after) } else { word.to_string() };
        let word = if space.as_str().is_empty() { format!(" {word}") } else { word }; // "3kg" -> "3 kilograms"
        rewrites.push((unit.start()..all.end(), word));
    }

    rewrites.sort_by_key(|(r, _)| r.start);
    let mut out = Normalized { text: String::with_capacity(text.len()), edits: Vec::new() };
    let mut at = 0;
    for (range, word) in rewrites {
        if range.start < at {
            continue; // Overlaps one already made
        }
        out.text.push_str(&text[at..range.start]);
        let start = out.text.len();
        out.text.push_str(&word);
        out.edits.push(Edit { original: range.clone(), rewritten: start..out.text.len() });
        at = range.end;
    }
    out.text.push_str(&text[at..]);
    out
}

/// The word, keeping the abbreviation's period when it also ends a sentence: at the end of the text, or before a
/// word that starts sentences. A capital alone isn't enough, since names follow abbreviations too ("Ave. Road").
fn with_period(word: &str, after: &str) -> String {
    let rest = after.trim_start();
    let next = rest.split(|c: char| !c.is_alphabetic()).next().unwrap_or("");
    if rest.is_empty() || (after.starts_with(char::is_whitespace) && SENTENCE_STARTERS.contains(&next)) {
        format!("{word}.")
    } else {
        word.to_string()
    }
}

/// Words that start sentences far more often than they name anything: after one, a full stop ended the sentence.
const SENTENCE_STARTERS: &[&str] = &[
    "A", "After", "All", "Also", "An", "And", "As", "At", "Because", "But", "By", "During", "Each", "Even", "Every",
    "For", "From", "He", "Her", "Here", "His", "How", "However", "I", "If", "In", "It", "Its", "Many", "Meanwhile",
    "Most", "My", "No", "Not", "Now", "Of", "On", "One", "Only", "Or", "Our", "She", "Since", "So", "Some", "Still",
    "That", "The", "Their", "Then", "There", "These", "They", "This", "Those", "Though", "To", "Today", "Under", "We",
    "What", "When", "Where", "Which", "While", "Who", "Why", "With", "Yet", "You", "Your",
];

fn starts_capitalised(s: &str) -> bool {
    let s = s.strip_prefix(' ').unwrap_or(s);
    s.chars().next().is_some_and(char::is_uppercase)
}

fn starts_number(s: &str) -> bool {
    s.trim_start().chars().next().is_some_and(|c| c.is_ascii_digit())
}

fn ends_number(s: &str) -> bool {
    s.trim_end().trim_end_matches(',').chars().last().is_some_and(|c| c.is_ascii_digit())
}

/// Whether `s` ends with a capitalised word in the same sentence (a word ending in a full stop ends the sentence).
fn ends_capitalised_word(s: &str) -> bool {
    let trimmed = s.trim_end();
    if trimmed.len() == s.len() {
        return false; // No space: part of the same word
    }
    let word = trimmed.rsplit(char::is_whitespace).next().unwrap_or(trimmed);
    !word.ends_with(['.', '!', '?']) && word.chars().next().is_some_and(char::is_uppercase)
}

/// The same, but not a word capitalised only for starting its sentence: "Baker" in "past Baker St." and not "When"
/// in "When Dr. Clark".
fn ends_name(s: &str) -> bool {
    let rest = s.trim_end().rsplit_once(char::is_whitespace).map_or("", |(rest, _)| rest).trim_end();
    ends_capitalised_word(s) && !(rest.is_empty() || rest.ends_with(['.', '!', '?', ':', '"', '“', '(']))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn n(s: &str) -> String {
        normalize(s).text
    }

    #[test]
    fn saint_and_street_by_context() {
        assert_eq!(n("St. Paul's is on Ludgate Hill, not Baker St. in London."), "Saint Paul's is on Ludgate Hill, not Baker Street in London.");
        assert_eq!(n("He lives at 221B Baker St., London."), "He lives at 221B Baker Street, London.");
        assert_eq!(n("No. 10 Downing St. Then home."), "No. 10 Downing Street. Then home.");
        assert_eq!(n("Flat 2, Ave. Road, London. Downing St. The end."), "Flat 2, Avenue Road, London. Downing Street. The end.");
        assert_eq!(n("Turn onto Mulholland Dr. and stop. Dr. Brown waved."), "Turn onto Mulholland Drive and stop. Dr. Brown waved.");
        assert_eq!(n("When Dr. Clark arrived, Rome. St. Peter's"), "When Dr. Clark arrived, Rome. Saint Peter's");
    }

    #[test]
    fn titles_only_before_names() {
        assert_eq!(n("Gen. Patton met Capt. Kirk and Lt. Uhura."), "General Patton met Captain Kirk and Lieutenant Uhura.");
        assert_eq!(n("The gen. pop."), "The gen. pop.");
    }

    #[test]
    fn trailing_after_names() {
        assert_eq!(n("John Smith Jr. arrived. Acme Co., Widgets Inc. and Gadgets Ltd. merged."),
                   "John Smith Junior arrived. Acme Company, Widgets Incorporated and Gadgets Limited merged.");
    }

    #[test]
    fn dates_and_references_beside_numbers() {
        assert_eq!(n("Mon. 3 Jan. and Fri. 14 Sept. 2026, see Fig. 3, Vol. 2, pp. 14-20."),
                   "Monday 3 January and Friday 14 September 2026, see Figure 3, Volume 2, pages 14-20.");
        assert_eq!(n("The Sun. Mar. is a name."), "The Sun. Mar. is a name.");
        assert_eq!(n("At 5 p.m. on Jan. 3"), "At 5 p.m. on January 3");
    }

    #[test]
    fn units_after_numbers() {
        assert_eq!(n("5 km from here, 3kg, 1 ft, 6 ft tall, 20 mph."), "5 kilometres from here, 3 kilograms, 1 foot, 6 feet tall, 20 miles per hour.");
        assert_eq!(n("The ft and the km stayed."), "The ft and the km stayed.");
        assert_eq!(n("It was 5 km."), "It was 5 kilometres.");
    }

    #[test]
    fn money_in_millions() {
        assert_eq!(n("Under $1M/year, or £2.5bn and €300k."), "Under 1 million dollars/year, or 2.5 billion pounds and 300 thousand euros.");
        assert_eq!(n("It cost $5 and 3 MB."), "It cost $5 and 3 megabytes.");
    }

    #[test]
    fn editors_and_editions() {
        assert_eq!(n("ed. by J. R. R. Tolkien, 2nd ed. of the book, cf. Ch. 5."), "edited by J. R. R. Tolkien, 2nd edition of the book, compare Chapter 5.");
    }

    #[test]
    fn maps_back_to_the_original() {
        let text = "Baker St. is 5 km away.";
        let n = normalize(text);
        let at = |w: &str| {
            let s = n.text.find(w).unwrap();
            &text[n.to_original(s..s + w.len())]
        };
        assert_eq!(at("Street"), "St.");
        assert_eq!(at("kilometres"), "km");
        assert_eq!(at("away"), "away");
        assert_eq!(at("Baker"), "Baker");
    }
}
