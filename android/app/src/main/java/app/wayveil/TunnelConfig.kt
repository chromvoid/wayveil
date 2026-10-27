package app.wayveil

import kotlinx.serialization.json.*

object TunnelConfig {
    fun create(profile: ConnectionProfile, mode: RoutingMode): String = buildJsonObject {
        put("profile", Json.parseToJsonElement(profile.toJson()))
        put("routing", mode.name)
    }.toString()
}
