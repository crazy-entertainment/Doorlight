package app.sybl.sybl

internal data class NativeAccountScope(val accountId: String?, internal val lifetime: Any)

/** Captures a selected-account command before it enters the serial daemon queue. */
internal class NativeAccountAuthority {
    private var selected: String? = null
    private var lifetime = Any()

    @Synchronized fun select(accountId: String?) {
        if (selected != accountId) lifetime = Any()
        selected = accountId
    }

    @Synchronized fun capture(expectedAccountId: String? = null): NativeAccountScope? =
        if (expectedAccountId != null && selected != expectedAccountId) null
        else NativeAccountScope(selected, lifetime)

    @Synchronized fun owns(scope: NativeAccountScope?): Boolean =
        scope != null && scope.accountId == selected && scope.lifetime === lifetime

    /** Account selection and invocation both run on the same daemon worker. */
    fun invoke(scope: NativeAccountScope?, action: () -> Unit): Boolean {
        if (!owns(scope)) return false
        action()
        return true
    }
}
