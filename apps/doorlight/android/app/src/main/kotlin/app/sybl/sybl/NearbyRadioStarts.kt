package app.sybl.sybl

/** Old SDK starts must be stopped individually, even while another start is pending. */
internal class NearbyRadioStarts {
    var pending = 0
        private set
    var failed = false
        private set
    fun begin() { check(pending == 0); failed = false }
    fun submitted() { pending++ }
    fun fail() { failed = true }
    fun finished(success: Boolean, current: Boolean): Boolean {
        check(pending > 0)
        pending--
        if (!success) failed = true
        return failed || !current
    }
}
