package app.sybl.sybl

/** There is deliberately no SIP/PEER_NUMBER fallback when transport identity
 * is unavailable, including callbacks that precede transport authentication. */
internal fun authenticatedCallPeer(details: Map<String, String>): String {
    val account = bareJamiId(details["AUTHENTICATED_PEER_ACCOUNT_ID"])
    val device = details["AUTHENTICATED_PEER_DEVICE_ID"].orEmpty()
    return account.takeIf { device.matches(Regex("^[0-9a-f]{40,128}$")) }.orEmpty()
}
