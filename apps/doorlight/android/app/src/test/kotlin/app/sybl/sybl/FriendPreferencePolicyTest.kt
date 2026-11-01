package app.sybl.sybl

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FriendPreferencePolicyTest {
    private val peer = "a".repeat(40)
    private fun document(global: Boolean, holograms: String, alerts: String, review: Boolean = false): JSONObject =
        JSONObject().put("schemaVersion", 17)
            .put("microphone", JSONObject().put("globalDefault", "pushToTalk")
                .put("reviewRequired", false).put("conversationOverrides", JSONArray()))
            .put("notifications", JSONObject().put("hologramPresentationEnabled", global)
                .put("messageAlertsEnabled", global))
            .put("friendPreferences", JSONObject().put("reviewRequired", review).put("overrides", JSONArray().put(
                JSONObject().put("accountId", "owner").put("peerId", peer)
                    .put("holograms", holograms).put("messageAlerts", alerts))))

    @Test fun profileColorSchemaPreservesFriendPolicyAndRejectsFutureSchemas() {
        for (version in listOf(17, 18, 19, 20, 21, 22)) {
            val value = document(true, "block", "mute").put("schemaVersion", version)
            val policy = FriendPreferencePolicy.decode(value.toString())!!
            assertFalse(policy.allowsHolograms("owner", peer))
            assertFalse(policy.allowsMessageAlerts("owner", peer))
            assertTrue(policy.allowsHolograms("other", peer))
            value.getJSONObject("friendPreferences").put("reviewRequired", true)
            assertFalse(FriendPreferencePolicy.decode(value.toString())!!.allowsHolograms("other", peer))
        }
        val future = document(true, "allow", "useGlobalDefault").put("schemaVersion", 23)
        assertNull(FriendPreferencePolicy.decode(future.toString()))
    }

    @Test fun accountOwnersMatchTheCanonicalUnicodeAndControlBoundary() {
        for (account in listOf("", " owner", "owner ", "ow\u0001ner", "owner\u007f",
                "\u0085owner", "\u00a0owner", "owner\ufeff", "a".repeat(129))) {
            val value = document(true, "block", "mute")
            value.getJSONObject("friendPreferences").getJSONArray("overrides")
                .getJSONObject(0).put("accountId", account)
            assertNull(FriendPreferencePolicy.decode(value.toString()))
            assertNull(IncomingCallMicrophonePolicy.decode(value.toString()))
        }
        for (account in listOf("a".repeat(128), "\u00e9".repeat(128))) {
            val value = document(true, "block", "mute")
            value.getJSONObject("friendPreferences").getJSONArray("overrides")
                .getJSONObject(0).put("accountId", account)
            val policy = FriendPreferencePolicy.decode(value.toString())!!
            assertFalse(policy.allowsHolograms(account, peer))
            assertFalse(policy.allowsMessageAlerts(account, peer))
        }
    }

    @Test fun choicesResolveIndependentlyAndRemainOwnerScoped() {
        for (global in listOf(false, true)) for (holograms in listOf("useGlobalDefault", "allow", "block")) {
            for (alerts in listOf("useGlobalDefault", "mute")) {
                val policy = FriendPreferencePolicy.decode(document(global, holograms, alerts).toString())!!
                assertEquals(if (holograms == "allow") true else if (holograms == "block") false else global,
                    policy.allowsHolograms("owner", peer.uppercase()))
                assertEquals(global && alerts != "mute", policy.allowsMessageAlerts("owner", peer))
                assertEquals(global, policy.allowsHolograms("other", peer))
                assertFalse(policy.allowsHolograms("owner", "group:$peer"))
            }
        }
    }

    @Test fun unresolvedRestoreNeverEnablesAnOverrideOrDefault() {
        val policy = FriendPreferencePolicy.decode(document(true, "allow", "useGlobalDefault", true).toString())!!
        assertFalse(policy.allowsHolograms("owner", peer))
        assertFalse(policy.allowsMessageAlerts("other", peer))
    }

    @Test fun malformedPolicyCannotBeSavedAsAnAdmissibleMicrophoneDocument() {
        val valid = document(true, "allow", "mute")
        assertNotNull(IncomingCallMicrophonePolicy.decode(valid.toString()))
        val invalid = document(true, "unknown", "mute")
        assertNull(FriendPreferencePolicy.decode(invalid.toString()))
        assertNull(IncomingCallMicrophonePolicy.decode(invalid.toString()))
        val duplicate = document(true, "allow", "mute")
        val entries = duplicate.getJSONObject("friendPreferences").getJSONArray("overrides")
        entries.put(JSONObject(entries.getJSONObject(0).toString()).put("peerId", peer.uppercase()))
        assertNull(FriendPreferencePolicy.decode(duplicate.toString()))
    }
}
