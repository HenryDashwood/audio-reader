package com.henrydashwood.magpie.ui

import org.jsoup.Jsoup
import org.jsoup.parser.Parser
import java.util.Base64

/** Only the backend's inert, self-contained chart subset may accompany raster images. */
internal object ArticleImageSource {
    private const val SVG_PREFIX = "data:image/svg+xml;base64,"
    private val raster = Regex("^data:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\\r\\n]+$")
    private val tags = setOf("svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline",
        "polygon", "text", "tspan", "title", "desc")
    private val attributes = setOf("x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "r", "rx", "ry",
        "dx", "dy", "width", "height", "opacity", "fill-opacity", "stroke-opacity", "stroke-width",
        "stroke-miterlimit", "stroke-dashoffset", "stroke-dasharray", "font-size", "letter-spacing",
        "word-spacing", "textLength", "text-anchor", "font-weight", "font-style", "fill-rule",
        "stroke-linecap", "stroke-linejoin", "dominant-baseline", "fill", "stroke", "color",
        "font-family", "d", "points", "transform")
    private val urlReference = Regex("url\\s*\\(", RegexOption.IGNORE_CASE)

    fun isEmbedded(source: String): Boolean {
        if (raster.matches(source)) return true
        if (!source.startsWith(SVG_PREFIX) || source.length > SVG_PREFIX.length + 270_000) return false
        return runCatching {
            val bytes = Base64.getDecoder().decode(source.substring(SVG_PREFIX.length))
            if (bytes.size > 200_000) return false
            val xml = bytes.toString(Charsets.UTF_8)
            // Generated charts contain no declarations, entities, comments or processing instructions.
            if (xml.contains("<!") || xml.contains("<?")) return false
            val document = Jsoup.parse(xml, "", Parser.xmlParser())
            val root = document.children().singleOrNull() ?: return false
            if (root.tagName() != "svg" || root.attr("xmlns") != "http://www.w3.org/2000/svg") return false
            val elements = root.getAllElements()
            if (elements.size > 5000 || elements.size < 2) return false
            elements.all { element ->
                element.tagName() in tags && (element === root || element.tagName() != "svg") &&
                    element.parents().size <= 41 && element.attributes().all { attribute ->
                        val name = attribute.key
                        val value = attribute.value
                        when {
                            value.length > 16000 || value.contains('\\') || urlReference.containsMatchIn(value) -> false
                            name == "xmlns" -> element === root && value == "http://www.w3.org/2000/svg"
                            name == "style" -> element === root && value == "background:white;color:black"
                            name == "viewBox" -> element === root && Regex("[-+0-9.eE,\\s]+").matches(value)
                            else -> name in attributes
                        }
                    }
            }
        }.getOrDefault(false)
    }
}
