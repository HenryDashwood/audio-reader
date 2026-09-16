package com.henrydashwood.magpie.voice

import com.henrydashwood.magpie.data.HttpLibraryApi
import org.json.JSONArray
import org.json.JSONObject

object VoiceWire {
    fun request(value: VoiceRequest) = JSONObject().put("supports_compound_actions", true)
        .put("transcript", value.transcript).put("request_id", value.requestId)
        .put("viewed_episode_id", value.viewedEpisodeId).put("now_playing_episode_id", value.nowPlayingEpisodeId)
        .put("country", value.country?.lowercase(java.util.Locale.ROOT))
        .put("recent_actions", JSONArray(value.recentActions))
        .put("turns", JSONArray().apply { value.turns.forEach { put(JSONObject().put("speaker", it.speaker).put("text", it.text)) } })

    fun event(line: String): VoiceEvent? = try {
        val envelope = JSONObject(line)
        when (envelope.getString("type")) {
            "assistant_delta" -> VoiceEvent.Delta(envelope.getString("text"))
            "result" -> VoiceEvent.Result(response(envelope.getJSONObject("response")))
            "error" -> throw VoiceFailure(envelope.optString("spoken_response").takeIf { it.isNotBlank() && it.length <= 32_000 }
                ?: VoiceExecution.UNCONFIRMED)
            else -> null // Forward-compatible metadata cannot be mistaken for a receipt.
        }
    } catch (error: VoiceFailure) { throw error }
    catch (error: Exception) { throw VoiceFailure(VoiceExecution.UNCONFIRMED, error) }

    private fun response(json: JSONObject, depth: Int = 0): VoiceResponse {
        require(depth < 4)
        val children = json.optJSONArray("actions")
        require((children?.length() ?: 0) <= 32)
        val action = VoiceAction.decode(json.getString("action"))
        val spoken = json.getString("spoken_response")
        require(spoken.length <= 32_000)
        val speed = if (json.isNull("speed")) null else json.getDouble("speed").toFloat()
        require(speed == null || (speed.isFinite() && speed in .5f..3f))
        val episode = json.optJSONObject("episode")?.let(HttpLibraryApi::decodeEpisode)
        val actions = if (children == null) emptyList() else (0 until children.length()).map { response(children.getJSONObject(it), depth + 1) }
        if (actions.isEmpty()) {
            require(action != VoiceAction.Speed || speed != null)
            require(action !in setOf(VoiceAction.Play, VoiceAction.Played, VoiceAction.Dismiss, VoiceAction.Restore) || episode != null)
        }
        return VoiceResponse(action, spoken, episode, speed, json.optBoolean("expects_reply"), actions)
    }
    fun failure(body: String): String = runCatching {
        JSONObject(body).optJSONObject("detail")?.optString("spoken_response")?.takeIf { it.isNotBlank() && it.length <= 32_000 }
    }.getOrNull() ?: "Magpie could not complete that request. Please try again."
}
