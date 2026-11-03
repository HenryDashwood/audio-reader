package com.henrydashwood.magpie.playback

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.util.Log
import com.google.ai.edge.litert.Accelerator
import com.google.ai.edge.litert.CompiledModel
import com.google.ai.edge.litert.TensorBuffer
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer
import org.json.JSONObject

/**
 * Kokoro on a phone: a sentence of text in, 24 kHz audio and where each word lands in it out.
 *
 * The models and the steps between them are text-to-speech notebook 106's `synthesize`, as the iOS app's
 * NaturalVoiceEngine runs them. The front half (`tokens`, then `prosody`) and the sine source run on ONNX Runtime on
 * the CPU; the decoder's body runs on LiteRT, on the GPU where the phone has one, at one of the padded sizes in the
 * voice's `voice.json`, all one model with its weights shared. Not thread-safe: callers take turns.
 */
class NaturalVoiceEngine(folder: File, val voice: NaturalVoice, cacheDir: File) : AutoCloseable {
    class Word(val characters: IntRange, val samples: IntRange)
    class Sentence(val samples: FloatArray, val words: List<Word>)
    class TooLong(val frames: Int) : Exception("$frames frames is longer than the voice's longest body.")
    class NothingToSay : Exception("Nothing to say.")

    /** The body's sizes, in frames: a sentence is padded up to the next. */
    val sizes: List<Int>
    private val phonemizer = NativePhonemizer(folder, voice.isBritish)
    private val vocabulary: Map<Int, Long>
    private val styles: FloatArray  // 510 rows of 256: one per sentence length in phonemes
    private val environment = OrtEnvironment.getEnvironment()
    private val tokens: OrtSession
    private val prosody: OrtSession
    private val source: OrtSession
    private val body: CompiledModel
    private val buffers = mutableMapOf<Int, Pair<Map<String, TensorBuffer>, Map<String, TensorBuffer>>>()
    private val random = SplitMix64(0x5EED)
    val accelerator: String

    init {
        val vocab = JSONObject(File(folder, "vocab.json").readText())
        vocabulary = vocab.keys().asSequence().filter { it.isNotEmpty() }.associate { it.codePointAt(0) to vocab.getLong(it) }
        sizes = JSONObject(File(folder, "voice.json").readText()).getJSONArray("sizes").let { a -> List(a.length()) { a.getInt(it) } }.sorted()
        val table = ByteBuffer.wrap(File(folder, "voices/${voice.id}.bin").readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        styles = FloatArray(table.remaining()).also { table.get(it) }
        val options = OrtSession.SessionOptions().apply { setIntraOpNumThreads(4) }
        tokens = environment.createSession(File(folder, "tokens.onnx").path, options)
        prosody = environment.createSession(File(folder, "prosody.onnx").path, options)
        source = environment.createSession(File(folder, "source.onnx").path, options)
        val path = File(folder, "body.tflite").path
        val gpu = runCatching {
            // GPU programs compile on first load; the cache makes later loads quick.
            val cache = File(cacheDir, "natural-voice-gpu").apply { mkdirs() }
            CompiledModel.create(path, CompiledModel.Options(Accelerator.GPU).apply {
                gpuOptions = CompiledModel.GpuOptions(serializationDir = cache.path, modelCacheKey = "body-${File(path).length()}",
                    precision = CompiledModel.GpuOptions.Precision.FP16)
            })
        }.onFailure { Log.i(TAG, "No GPU for the natural voice, so the CPU: ${it.message}") }.getOrNull()
        // On the CPU, XNNPACK repacks the weights for each size; its cache file lets the sizes share one copy.
        body = gpu ?: CompiledModel.create(path, CompiledModel.Options(Accelerator.CPU).apply {
            cpuOptions = CompiledModel.CpuOptions(numThreads = 4, xnnPackWeightCachePath = File(cacheDir, "natural-voice-xnnpack").path)
        })
        accelerator = if (gpu != null) "GPU" else "CPU"
    }

    /** Speaks `text`, trimmed to the speech with a little either side. */
    fun render(text: String): Sentence {
        val started = System.nanoTime()
        var lap = started
        val stages = mutableListOf<String>()
        fun lap(name: String) { val now = System.nanoTime(); stages += "$name ${(now - lap) / 1_000_000}ms"; lap = now }
        val g2p = phonemizer.phonemize(text)
        lap("g2p")
        val phonemes = g2p.phonemes.codePoints().limit(510).toArray().toList()  // Kokoro's limit, in code points
        val ids = longArrayOf(0) + phonemes.mapNotNull { vocabulary[it] }.toLongArray() + longArrayOf(0)
        if (ids.size <= 2) throw NothingToSay()
        val n = ids.size
        val style = styles.copyOfRange((phonemes.size - 1) * 256, phonemes.size * 256)

        // Per phoneme: duration features d (1, n, 640), text features t_en (1, 512, n), durations (1, n)
        val front = run(tokens, "ids" to tensor(ids, 1, n.toLong()), "style" to tensor(style, 1, 256))
        lap("tokens")
        val d = front.getValue("d")
        val tEn = front.getValue("t_en")
        val frames = front.getValue("duration").map { maxOf(1, Math.rint(it.toDouble()).toInt()) }
        val total = frames.sum()
        val bucket = sizes.firstOrNull { it >= total } ?: throw TooLong(total)
        val phonemeOfFrame = frames.flatMapIndexed { phoneme, count -> List(count) { phoneme } }.toIntArray()

        // Per frame: pitch and energy, two values a frame
        val en = gather(d, rows = n, columns = 640, at = phonemeOfFrame, transposing = true)
        val pitch = run(prosody, "en" to tensor(en, 1, 640, total.toLong()), "style" to tensor(style, 1, 256))
        lap("prosody")
        val f0 = repeated(pitch.getValue("F0"), 2 * bucket)
        val energy = repeated(pitch.getValue("N"), 2 * bucket)

        // The decoder's sine source, with its random numbers supplied here
        val phases = FloatArray(9) { random.uniform().toFloat() }.also { it[0] = 0f }
        val noise = random.gaussians(9 * 600 * bucket)
        lap("noise")
        val harmonics = run(source, "f0" to tensor(f0, 1, 2L * bucket), "phases" to tensor(phases, 1, 9),
            "noise" to tensor(noise, 1, 9, 600L * bucket)).getValue("har")
        lap("source")

        // The body, padded to its size by repeating the sentence, as notebook 103 does
        val padded = IntArray(bucket) { phonemeOfFrame[it % total] }
        val asr = gather(tEn, rows = 512, columns = n, at = padded, transposing = false)
        val (inputs, outputs) = buffers(bucket)
        inputs.getValue("args_0").writeFloat(asr)
        inputs.getValue("args_1").writeFloat(f0)
        inputs.getValue("args_2").writeFloat(energy)
        inputs.getValue("args_3").writeFloat(style.copyOf(128))
        inputs.getValue("args_4").writeFloat(harmonics)
        body.run(inputs, outputs, "body$bucket")
        val audio = outputs.getValue("output_0").readFloat()
        lap("body$bucket")
        Log.d(TAG, "render: ${stages.joinToString()}")
        return trimmed(audio.copyOf(total * FRAME), words(g2p.tokens, frames))
    }

    private fun buffers(bucket: Int) = buffers.getOrPut(bucket) {
        val signature = "body$bucket"
        (0..4).associate { "args_$it" to body.createInputBuffer("args_$it", signature) } to
            mapOf("output_0" to body.createOutputBuffer("output_0", signature))
    }

    private fun tensor(values: LongArray, vararg shape: Long) = OnnxTensor.createTensor(environment, LongBuffer.wrap(values), shape)
    private fun tensor(values: FloatArray, vararg shape: Long) = OnnxTensor.createTensor(environment, FloatBuffer.wrap(values), shape)

    /** Runs `session`, closing the tensors in and out, and returns each output as floats. */
    private fun run(session: OrtSession, vararg inputs: Pair<String, OnnxTensor>): Map<String, FloatArray> = try {
        session.run(mapOf(*inputs)).use { result ->
            result.associate { (name, value) ->
                val buffer = (value as OnnxTensor).floatBuffer
                name to FloatArray(buffer.remaining()).also { buffer.get(it) }
            }
        }
    } finally { inputs.forEach { it.second.close() } }

    override fun close() {
        buffers.values.forEach { (inputs, outputs) -> (inputs.values + outputs.values).forEach { it.close() } }
        buffers.clear()
        body.close(); tokens.close(); prosody.close(); source.close(); phonemizer.close()
    }

    companion object {
        private const val TAG = "NaturalVoice"
        const val SAMPLE_RATE = 24_000
        /** Samples per frame: Kokoro decides durations in 25 ms steps. */
        const val FRAME = 600

        /** Repeats per-phoneme features once per frame. `x` is (rows, columns) row-major; the result is
         *  (channels, frames): with `transposing`, x's rows are phonemes and its columns channels (Tokens' d), else the
         *  other way round (Tokens' t_en). */
        fun gather(x: FloatArray, rows: Int, columns: Int, at: IntArray, transposing: Boolean): FloatArray {
            val channels = if (transposing) columns else rows
            val out = FloatArray(channels * at.size)
            for (c in 0 until channels) {
                val row = c * at.size
                for (f in at.indices) out[row + f] = if (transposing) x[at[f] * columns + c] else x[c * columns + at[f]]
            }
            return out
        }

        /** Repeats `x` to length `n`: padding whose statistics look like the sentence's. */
        fun repeated(x: FloatArray, n: Int) = FloatArray(n) { x[it % x.size] }

        /** Kokoro's `KPipeline.join_timestamps`: each token's span in the audio, from the frames each phoneme lasts,
         *  counting half-frames so a space can be split. */
        fun words(tokens: List<PhonemeToken>, frames: List<Int>): List<Word> {
            if (tokens.isEmpty() || frames.size < 3) return emptyList()
            val halfFrame = FRAME / 2
            var left = 2 * maxOf(0, frames[0] - 3)
            var right = left
            var i = 1
            val words = mutableListOf<Word>()
            for (token in tokens) {
                if (i >= frames.size - 1) break
                if (token.phonemes.isEmpty()) {
                    if (token.whitespace.isNotEmpty()) {
                        i += 1
                        left = right + frames[i]
                        right = left + frames[i]
                        i += 1
                    }
                    continue
                }
                val j = i + token.phonemes.codePointCount(0, token.phonemes.length)
                if (j >= frames.size) break
                val start = left
                val spoken = frames.subList(i, j).sum()
                val space = if (token.whitespace.isEmpty()) 0 else frames[j]
                left = right + 2 * spoken + space
                right = left + space
                i = j + if (token.whitespace.isEmpty()) 0 else 1
                if (token.text.any { it.isLetterOrDigit() }) {
                    words += Word(token.start until token.end, start * halfFrame until left * halfFrame)
                }
            }
            return words
        }

        /** Cuts the audio to the speech, keeping 0.1 s before the first word and 0.25 s after the last, as the
         *  notebooks' player does, and moves the words to match. */
        fun trimmed(samples: FloatArray, words: List<Word>): Sentence {
            val first = words.firstOrNull() ?: return Sentence(samples, emptyList())
            val from = maxOf(0, first.samples.first - SAMPLE_RATE / 10)
            val to = minOf(samples.size, words.last().samples.last + 1 + SAMPLE_RATE / 4)
            if (from >= to) return Sentence(samples, words)
            val moved = words.map {
                Word(it.characters, maxOf(0, it.samples.first - from) until maxOf(0, minOf(to, it.samples.last + 1) - from))
            }
            return Sentence(samples.copyOfRange(from, to), moved)
        }
    }
}

/** A small, fast generator for the source's noise: millions of numbers a sentence. The same as iOS's. */
class SplitMix64(seed: Long) {
    private var state = seed

    fun next(): Long {
        state += -0x61c8864680b583ebL  // 0x9E3779B97F4A7C15
        var z = state
        z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L  // 0xBF58476D1CE4E5B9
        z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L  // 0x94D049BB133111EB
        return z xor (z ushr 31)
    }

    /** In [0, 1). */
    fun uniform(): Double = (next() ushr 11) * TWO_TO_MINUS_53

    /** Unit Gaussians, by Box-Muller: each pair of uniforms gives two. */
    fun gaussians(count: Int): FloatArray {
        val out = FloatArray(count)
        var i = 0
        while (i < count) {
            val radius = Math.sqrt(-2 * Math.log(1 - (next() ushr 40) * TWO_TO_MINUS_24))  // In (0, 1]: log(0) would be minus infinity
            val angle = (next() ushr 40) * TWO_TO_MINUS_24 * 2 * Math.PI
            out[i] = (radius * Math.cos(angle)).toFloat()
            if (i + 1 < count) out[i + 1] = (radius * Math.sin(angle)).toFloat()
            i += 2
        }
        return out
    }

    private companion object {
        const val TWO_TO_MINUS_53 = 1.0 / (1L shl 53)
        const val TWO_TO_MINUS_24 = 1.0 / (1L shl 24)
    }
}
