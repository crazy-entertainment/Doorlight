package net.jami.daemon;

/**
 * Typed ownership adapter for a SWIG typedef gap: currentMediaList is generated as an opaque
 * std::vector&lt;libjami::MediaMap&gt; even though VectMap wraps the same native vector type.
 *
 * Keep this outside generated sources' implementation bodies. The returned VectMap owns and
 * deletes the native result, which the opaque wrapper itself cannot release.
 */
public final class CurrentMediaListAdapter {
    private CurrentMediaListAdapter() {}

    public static VectMap get(String accountId, String callId) {
        SWIGTYPE_p_std__vectorT_libjami__MediaMap_t opaque =
                JamiService.currentMediaList(accountId, callId);
        return new VectMap(
                SWIGTYPE_p_std__vectorT_libjami__MediaMap_t.getCPtr(opaque),
                true);
    }
}
