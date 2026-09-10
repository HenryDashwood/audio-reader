package com.henrydashwood.magpie.playback

import java.io.File
import java.io.RandomAccessFile
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WaveFilesTest {
    @get:Rule val directory = TemporaryFolder()

    private fun wave(name: String, samples: Int, sampleRate: Int = 16000, extraChunk: Boolean = false): File {
        val file = directory.newFile(name)
        RandomAccessFile(file, "rw").use { out ->
            fun int(value: Int) = out.writeInt(Integer.reverseBytes(value))
            fun short(value: Int) = out.writeShort(java.lang.Short.reverseBytes(value.toShort()).toInt())
            out.writeBytes("RIFF"); int(36 + samples * 2 + if (extraChunk) 12 else 0); out.writeBytes("WAVE")
            if (extraChunk) { out.writeBytes("JUNK"); int(3); out.write(byteArrayOf(1, 2, 3, 0)) }
            out.writeBytes("fmt "); int(16); short(1); short(1); int(sampleRate); int(sampleRate * 2); short(2); short(16)
            out.writeBytes("data"); int(samples * 2); out.write(ByteArray(samples * 2))
        }
        return file
    }

    @Test fun joinsAudioWithOptionalChunksAndBuildsOneContinuousTimeline() {
        val files = listOf(wave("a.wav", 16000, extraChunk = true), wave("b.wav", 32000))
        val output = File(directory.root, "joined.wav")
        val timeline = joinWaves(files, listOf(TextChunk("A", 0, 1), TextChunk("B", 3, 4)), output)
        assertEquals(96000L, inspectWave(output).dataSize)
        assertEquals(0L, timeline[0].startMs)
        assertEquals(1000L, timeline[1].startMs)
        assertEquals(3000L, timeline[1].endMs)
        assertFalse(File(directory.root, "joined.wav.partial").exists())
    }

    @Test fun refusesMismatchedFormatsWithoutPublishingAudio() {
        val output = File(directory.root, "joined.wav")
        assertThrows(IllegalArgumentException::class.java) {
            joinWaves(listOf(wave("a.wav", 10), wave("b.wav", 10, sampleRate = 22050)), listOf(TextChunk("A", 0, 1), TextChunk("B", 2, 3)), output)
        }
        assertFalse(output.exists())
    }

    @Test fun refusesTruncatedAudio() {
        val file = wave("bad.wav", 16000)
        RandomAccessFile(file, "rw").use { it.setLength(50) }
        assertThrows(IllegalArgumentException::class.java) { inspectWave(file) }
    }
}
