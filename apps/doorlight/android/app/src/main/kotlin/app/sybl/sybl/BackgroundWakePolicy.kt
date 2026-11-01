package app.sybl.sybl

internal object BackgroundWakePolicy {
    fun effective(requested: Boolean, connectionProfile: String, firebaseAvailable: Boolean): Boolean =
        requested && connectionProfile == "jami" && firebaseAvailable
}
