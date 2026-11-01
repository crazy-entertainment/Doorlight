package app.sybl.sybl

/** A replacement Flutter listener cannot inherit camera commands from the old UI. */
internal class CaptureUiAuthority {
    private var owner: Any? = null
    @Synchronized fun attach() { owner = Any() }
    @Synchronized fun detach() { owner = null }
    @Synchronized fun capture(): Any? = owner
    @Synchronized fun owns(candidate: Any?): Boolean = candidate != null && owner === candidate
}
