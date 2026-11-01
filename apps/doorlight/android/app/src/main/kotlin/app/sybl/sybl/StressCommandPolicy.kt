package app.sybl.sybl

internal object StressCommandPolicy {
    private val commands = setOf(
        "ping", "select", "voice", "video", "answer", "hangup",
        "camera:on", "camera:off", "camera:flip", "screen:on", "screen:off",
        "group:join", "group:camera", "group:leave", "group:screen:on", "group:screen:off",
        "profile:lan", "profile:jami",
    )

    fun peer(command: String, peer: String?): String? {
        if (command !in commands &&
            !(command.length == 6 && command.startsWith("chat:") && command[5] in '1'..'9')) return null
        if (command != "select") return ""
        return peer?.lowercase()?.takeIf {
            it.length == 40 && it.all { char -> char in '0'..'9' || char in 'a'..'f' }
        }
    }

    fun dispatchCommand(command: String, peer: String?): String? {
        val validatedPeer = peer(command, peer) ?: return null
        return if (command == "select") "select:$validatedPeer" else command
    }
}
