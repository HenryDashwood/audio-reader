package com.henrydashwood.magpie.playback

import java.io.File
import java.io.RandomAccessFile

data class WaveInfo(val format: ByteArray, val dataOffset: Long, val dataSize: Long, val bytesPerSecond: Long)

/** TTS WAVs can contain extra chunks. Do not assume a fixed 44-byte input header. */
fun inspectWave(file: File): WaveInfo = RandomAccessFile(file, "r").use { input ->
    fun tag() = ByteArray(4).also(input::readFully).toString(Charsets.US_ASCII)
    fun uint() = Integer.reverseBytes(input.readInt()).toLong() and 0xffffffffL
    require(tag() == "RIFF") { "The voice returned an unsupported audio format." }
    uint()
    require(tag() == "WAVE") { "The voice returned an unsupported audio format." }
    var format: ByteArray? = null
    var dataOffset = 0L
    var dataSize = 0L
    while (input.filePointer + 8 <= input.length()) {
        val id = tag()
        val size = uint()
        val start = input.filePointer
        require(size <= input.length() - start) { "The voice returned incomplete audio." }
        when (id) {
            "fmt " -> {
                require(size in 16..4096)
                format = ByteArray(size.toInt()).also(input::readFully)
            }
            "data" -> { dataOffset = start; dataSize = size }
        }
        input.seek(start + size + size % 2)
    }
    val fmt = requireNotNull(format) { "The voice returned no audio format." }
    fun u16(offset: Int) = (fmt[offset].toInt() and 255) or ((fmt[offset + 1].toInt() and 255) shl 8)
    require(u16(0) == 1 && u16(2) > 0 && u16(14) in setOf(8, 16)) { "Unsupported voice audio format." }
    val byteRate = (8..11).fold(0L) { value, i -> value or ((fmt[i].toLong() and 255) shl ((i - 8) * 8)) }
    require(byteRate > 0 && dataSize > 0)
    WaveInfo(fmt, dataOffset, dataSize, byteRate)
}

/** Publish only a complete file, so a cancelled render never becomes playable audio. */
fun joinWaves(parts: List<File>, chunks: List<TextChunk>, destination: File): List<TimedChunk> {
    require(parts.isNotEmpty() && parts.size == chunks.size)
    val infos = parts.map(::inspectWave)
    val format = infos.first().format
    require(infos.all { it.format.contentEquals(format) }) { "The voice changed audio format while reading." }
    val total = infos.sumOf { it.dataSize }
    require(total < Int.MAX_VALUE)
    val padding = total % 2
    val formatPadding = format.size % 2
    val temporary = File(destination.parentFile, destination.name + ".partial")
    try {
        RandomAccessFile(temporary, "rw").use { output ->
            output.setLength(0)
            fun uint(value: Long) { output.writeInt(Integer.reverseBytes(value.toInt())) }
            output.writeBytes("RIFF")
            uint(4 + 8 + format.size + formatPadding + 8 + total + padding)
            output.writeBytes("WAVEfmt ")
            uint(format.size.toLong())
            output.write(format)
            if (formatPadding != 0) output.write(0)
            output.writeBytes("data")
            uint(total)
            parts.zip(infos).forEach { (part, info) ->
                RandomAccessFile(part, "r").use { input ->
                    input.seek(info.dataOffset)
                    var remaining = info.dataSize
                    val buffer = ByteArray(8192)
                    while (remaining > 0) {
                        val count = input.read(buffer, 0, minOf(remaining, buffer.size.toLong()).toInt())
                        check(count > 0)
                        output.write(buffer, 0, count)
                        remaining -= count
                    }
                }
            }
            if (padding != 0L) output.write(0)
        }
        check(temporary.renameTo(destination)) { "Could not save the prepared article." }
    } finally { temporary.delete() }
    var bytes = 0L
    return infos.mapIndexed { index, info ->
        val start = bytes * 1000 / info.bytesPerSecond
        bytes += info.dataSize
        TimedChunk(chunks[index], start, bytes * 1000 / info.bytesPerSecond)
    }.also { require(it.last().endMs > 0) }
}
