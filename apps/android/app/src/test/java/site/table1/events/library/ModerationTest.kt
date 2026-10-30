package site.table1.events.library

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/* Moderation (contract/moderation-2026-10-18.md § RPCs): moderation_notices and moderation_queue as the server sends
   them, and the words the Notices screen shows. */
class ModerationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun noticesDecode() {
        val n = json.decodeFromString<List<ModerationNotice>>("""[
            {"id": 7, "subject_kind": "list_name", "label": "Deck Mono-Black Suicide", "action": "unshare", "category": "self_harm",
             "reason_text": "Names that mention self-harm aren't shared.", "at": "2026-10-18T20:00:00.123+00:00", "seen": false,
             "appeal": "none", "can_appeal": true},
            {"id": 8, "subject_kind": "display_name", "label": "Your display name", "action": "reset_name", "category": null,
             "reason_text": "x", "at": "2026-10-19T10:00:00+00:00", "seen": true, "appeal": "reverted", "can_appeal": false}]""")
        assertEquals("No longer shared", n[0].whatChanged)
        assertEquals("New", n[0].status)
        assertTrue(n[0].canAppeal)
        assertEquals("Restored", n[1].status)
        assertEquals("Oct 18, 2026", ModerationWords.date(n[0].at))
    }

    @Test fun queueDecodes() {
        val q = json.decodeFromString<ReviewQueue>("""{"mode": "shadow",
            "checks": [{"id": 31, "subject_kind": "display_name", "text": "Table 1 Admin", "status": "block", "category": "impersonation",
                        "reason": "Poses as staff", "source": "write", "enforced": false,
                        "owner": {"user_id": "u1", "display_name": "Table 1 Admin"}, "strikes": 0, "reports": 0}],
            "appeals": [], "flagged": [{"user_id": "u2", "display_name": "Lee", "strikes": 1, "reporters": 3}]}""")
        assertEquals(2, q.waiting)
        assertEquals("Impersonation", ModerationWords.category(q.checks[0].category))
        assertEquals("Unclear", ModerationWords.category(null))
    }
}
