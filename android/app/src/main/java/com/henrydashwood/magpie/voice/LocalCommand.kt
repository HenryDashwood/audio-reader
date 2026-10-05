package com.henrydashwood.magpie.voice

import java.util.Locale

/** Whole-utterance controls that never need to send a transcript to a server. */
sealed interface LocalCommand {
    data object Pause : LocalCommand
    data object Resume : LocalCommand
    data class Seek(val seconds: Double) : LocalCommand
    data class Speed(val rate: Float) : LocalCommand
    data class AdjustSpeed(val delta: Float) : LocalCommand
    data class Sleep(val minutes: Int) : LocalCommand
    data object CancelSleep : LocalCommand
    data object EndConversation : LocalCommand
    data object Undo : LocalCommand
    /** "Download this": whatever is in the player. */
    data object Download : LocalCommand
    data object RemoveDownload : LocalCommand

    companion object {
        fun match(transcript: String): LocalCommand? {
            if (Regex("-\\s*[0-9]").containsMatchIn(transcript)) return null
            val dialogue = transcript.lowercase(Locale.ROOT).replace('’', '\'')
                .trim().trim { !it.isLetterOrDigit() }
            if (dialogue in endings) return EndConversation
            if (dialogue in setOf("undo", "undo that", "undo last action")) return Undo
            sleep(transcript)?.let { return it }
            DownloadPhrases.match(transcript)?.let { return it }
            val phrase = transcript.lowercase(Locale.ROOT)
                .replace(Regex("(?<![0-9])\\.|\\.(?![0-9])"), " ")
                .map { if (it.isLetterOrDigit() || it.isWhitespace() || it == '.') it else ' ' }.joinToString("")
                .split(Regex("\\s+")).filter { it.isNotEmpty() && it !in filler }.joinToString(" ")
            phrases[phrase]?.let { return it }
            for ((prefix, sign) in seeks) if (phrase.startsWith(prefix)) {
                val amount = phrase.removePrefix(prefix).removePrefix("by ")
                for ((unit, scale) in timeUnits) if (amount.endsWith(" $unit")) {
                    val value = spokenNumber(amount.removeSuffix(" $unit")) ?: continue
                    if (value > 0 && value * scale <= 7200) return Seek(value * scale * sign)
                }
            }
            for (prefix in listOf("play at ", "set speed to ", "speed ", "playback speed ")) if (phrase.startsWith(prefix)) {
                var amount = phrase.removePrefix(prefix)
                for (suffix in listOf(" times normal speed", " times speed", " times", " speed", "x")) {
                    if (amount.endsWith(suffix)) { amount = amount.removeSuffix(suffix); break }
                }
                val rate = spokenNumber(amount)
                if (rate != null && rate in .5..3.0) return Speed(rate.toFloat())
            }
            return null
        }
        private val endings = setOf("that's all", "that is all", "that's all thanks", "that's all, thanks",
            "end conversation", "end the conversation", "goodbye", "goodbye magpie")
        private val filler = setOf("please", "can", "could", "you", "hey", "ok", "okay", "now", "just", "it", "a", "bit")
        private val seeks = listOf("go back " to -1, "rewind " to -1, "skip back " to -1,
            "skip forward " to 1, "skip ahead " to 1, "jump forward " to 1, "fast forward " to 1)
        private val timeUnits = listOf("seconds" to 1, "second" to 1, "minutes" to 60, "minute" to 60, "hours" to 3600, "hour" to 3600)
        private val units = listOf("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
            "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen")
        private val tens = mapOf("twenty" to 20, "thirty" to 30, "forty" to 40, "fifty" to 50, "sixty" to 60,
            "seventy" to 70, "eighty" to 80, "ninety" to 90)
        private fun spokenNumber(text: String): Double? {
            text.toDoubleOrNull()?.takeIf { it.isFinite() }?.let { return it }
            mapOf("half" to .5, "double" to 2.0, "one and half" to 1.5, "one and quarter" to 1.25,
                "two and half" to 2.5, "one point five" to 1.5, "one point two five" to 1.25,
                "two point five" to 2.5)[text]?.let { return it }
            units.indexOf(text).takeIf { it >= 0 }?.let { return it.toDouble() }
            val words = text.split(' ')
            val ten = tens[words.first()] ?: return null
            if (words.size == 1) return ten.toDouble()
            val unit = if (words.size == 2) units.indexOf(words[1]) else -1
            return if (unit in 0..9) (ten + unit).toDouble() else null
        }
        private val phrases = buildMap<String, LocalCommand> {
            fun aliases(command: LocalCommand, vararg words: String) { words.forEach { put(it, command) } }
            aliases(Pause, "pause", "stop", "be quiet", "quiet", "shush", "hold on", "wait", "silence")
            aliases(Resume, "resume", "continue", "carry on", "keep going", "go on", "unpause", "play", "start again", "start")
            aliases(Seek(30.0), "skip", "skip forward", "skip ahead", "jump forward", "forward", "fast forward")
            aliases(Seek(-15.0), "go back", "back", "rewind", "say that again", "repeat that", "repeat", "what was that")
            aliases(AdjustSpeed(.25f), "faster", "speed up", "quicker", "go faster", "too slow")
            aliases(AdjustSpeed(-.25f), "slower", "slow down", "not so fast", "too fast")
            aliases(Speed(1f), "normal speed", "regular speed", "usual speed", "ordinary speed")
        }
        private fun sleep(text: String): LocalCommand? {
            if (Regex("[0-9][.,][0-9]").containsMatchIn(text)) return null
            val raw = text.lowercase(Locale.ROOT).replace(Regex("[^\\p{L}\\p{N}\\s]"), " ")
                .split(Regex("\\s+")).filter { it.isNotBlank() }
            if (raw.any { it in setOf("what", "why", "explain", "tell", "about", "how", "play", "subscribe", "unsubscribe", "listen", "read", "find", "search") }) return null
            val words = raw.filter { it !in sleepFiller }
            val timer = "timer" in words
            if (!timer && words.none { it in setOf("sleep", "sleeping", "asleep", "bed", "stop", "off") }) return null
            val phrase = words.joinToString(" ")
            val fixed = listOf("an hour and a half" to 90, "hour and a half" to 90,
                "half an hour" to 30, "half hour" to 30, "an hour" to 60, "one hour" to 60)
                .firstOrNull { phrase.contains(it.first) }?.second
            var number: Int? = null
            var ten: Int? = null
            for (word in words) {
                word.toIntOrNull()?.let { number = it }
                if (number != null) break
                val unit = units.indexOf(word)
                if (unit >= 0) { number = (ten ?: 0) + unit; break }
                tens[word]?.let { ten = it }
            }
            if (words.any { it == "second" || it == "seconds" }) return null
            if (words.any { it == "hour" || it == "hours" } && words.any { it == "minute" || it == "minutes" }) return null
            if (fixed == null && words.any { it == "half" || it == "quarter" }) return null
            val amount = number ?: ten
            val minutes = fixed?.toLong() ?: amount?.toLong()?.times(if ("hour" in words || "hours" in words) 60 else 1)
            if (minutes != null) return if (minutes in 1..720) Sleep(minutes.toInt()) else null
            // An explicit but invalid duration must not silently become a 30-minute timer.
            if (words.any { it.any(Char::isDigit) } || words.any { it in timeUnits.map { unit -> unit.first } }) return null
            if (!timer) return null
            return if (words.any { it in setOf("cancel", "clear", "remove", "forget", "off", "no", "stop") }) CancelSleep else Sleep(30)
        }
        private val sleepFiller = setOf("please", "can", "could", "you", "hey", "ok", "okay", "just", "the", "for", "in",
            "after", "set", "put", "me", "my", "i", "want", "to", "go", "at", "on")
    }
}

/**
 * Whole-utterance download phrases, as on iOS: "download the new episode of In Our Time" names
 * something else and is left for the model.
 */
object DownloadPhrases {
    enum class Reply { Yes, WaitForWifi, No }

    fun match(transcript: String): LocalCommand? {
        val phrase = normalise(transcript)
        return when (phrase) {
            in download -> LocalCommand.Download
            in remove -> LocalCommand.RemoveDownload
            else -> null
        }
    }

    /** An answer to "Shall I download it anyway?" */
    fun reply(transcript: String): Reply? = when (normalise(transcript)) {
        in yes -> Reply.Yes
        in wait -> Reply.WaitForWifi
        in no -> Reply.No
        else -> null
    }

    private val things = listOf("this", "this episode", "this one", "it", "this podcast", "the episode", "that", "that episode")
    private val download = buildSet {
        addAll(listOf("download", "download for offline", "save for offline"))
        for (thing in things) addAll(listOf("download $thing", "download $thing for offline", "save $thing for offline",
            "keep $thing for offline", "make $thing available offline"))
    }
    private val remove = buildSet {
        addAll(listOf("remove download", "delete download", "remove the download", "delete the download",
            "remove this download", "delete this download", "remove that download", "delete that download"))
        for (thing in things) addAll(listOf("remove $thing from downloads", "delete $thing from downloads",
            "remove the download of $thing", "delete the download of $thing"))
    }
    private val yes = setOf("yes", "yeah", "yep", "sure", "go ahead", "do it", "download it", "download it anyway",
        "download anyway", "download now", "download it now", "now", "ok", "okay", "use mobile data", "yes download it",
        "yes use mobile data", "that's fine", "thats fine", "fine")
    private val wait = setOf("wait", "wait for wifi", "wait for wi fi", "wait until wifi", "wait until wi fi",
        "wait until i'm on wifi", "wait until i'm on wi fi", "later", "on wifi", "on wi fi", "when i'm on wifi",
        "when i'm on wi fi", "download it later", "download later")
    private val no = setOf("no", "nope", "no thanks", "no thank", "cancel", "don't", "dont", "don't download it",
        "never mind", "nevermind", "forget it", "stop")
    private val filler = setOf("please", "can", "could", "you", "hey", "just", "my", "me")

    private fun normalise(transcript: String) = transcript.lowercase(Locale.ROOT).replace('’', '\'').replace('-', ' ')
        .map { if (it.isLetterOrDigit() || it.isWhitespace() || it == '\'') it else ' ' }.joinToString("")
        .split(Regex("\\s+")).filter { it.isNotEmpty() && it !in filler }.joinToString(" ")
}
