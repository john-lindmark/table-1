package site.table1.events.library

import site.table1.events.util.rethrowIfCancelled

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.util.Telemetry
import java.util.UUID

/* Friends, public profiles, sharing and trade matches (contract/friends-sharing-2026-10-18.md). Friendships are
   mutual; every part of the Library is private until its owner shares it (Account → Sharing). The server checks who
   may see what on every read, so this store only holds what came back. Trade matches put your wants next to friends'
   for-trade copies (and theirs next to yours) in trade_confirm's order. Same rules as
   apps/ios/Table1/Library/Friends.swift. */

enum class Visibility(val wire: String, val label: String, /** What it asks of a viewer: public 0, friends 1, private 3. */ val asks: Int) {
    Private("private", "Private", 3), Friends("friends", "Friends", 1),
    /** "Anyone" means anyone on Table 1; the UI never says "Public" (contract § UX rules 1). */
    Public("public", "Anyone", 0);

    companion object {
        fun of(s: String?) = entries.firstOrNull { it.wire == s }
    }
}

@Serializable
data class Person(
    @SerialName("user_id") val userId: String,
    @SerialName("display_name") val displayName: String,
    val handle: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val since: String? = null,
    val at: String? = null,
    @SerialName("shared_events") val sharedEvents: Int? = null,
    /** self / friend / requested (you asked) / incoming (they asked) / blocked / none */
    val relation: String? = null,
    /** A profile's friends list (profile_friends): also the viewer's friend. */
    val mutual: Boolean? = null,
)

/**
 * A request you sent: to an account (asked by id: a Person) or to an address (asked by email: `{email, at}` with no
 * user_id, account or not, so the server never says whose it is). Older servers sent email asks as a Person.
 */
@Serializable(with = SentRequestSerializer::class)
data class SentRequest(val person: Person? = null, val email: String? = null, val at: String? = null) {
    val key get() = person?.userId ?: "email:$email"
    val label get() = person?.displayName ?: email.orEmpty()
}

object SentRequestSerializer : KSerializer<SentRequest> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("SentRequest")

    override fun deserialize(decoder: Decoder): SentRequest {
        val d = decoder as JsonDecoder
        val o = d.decodeJsonElement().jsonObject
        fun str(k: String) = (o[k] as? JsonPrimitive)?.contentOrNull
        return if (str("user_id") != null) SentRequest(person = d.json.decodeFromJsonElement(Person.serializer(), o), at = str("at"))
        else SentRequest(email = str("email"), at = str("at"))
    }

    override fun serialize(encoder: Encoder, value: SentRequest) {
        val e = encoder as JsonEncoder
        e.encodeJsonElement(value.person?.let { e.json.encodeToJsonElement(Person.serializer(), it) }
            ?: buildJsonObject { value.email?.let { put("email", it) }; value.at?.let { put("at", it) } })
    }
}

@Serializable
data class FriendsList(
    val friends: List<Person> = emptyList(), val incoming: List<Person> = emptyList(),
    val outgoing: List<SentRequest> = emptyList(), val blocked: List<Person> = emptyList(),
)

/** user_report's reasons (contract § UX rules 6). */
enum class ReportReason(val wire: String, val label: String) {
    Spam("spam", "Spam or fake account"), Harassment("harassment", "Harassment"),
    OffensiveProfile("offensive_profile", "Offensive name or photo"), OffensiveContent("offensive_content", "Offensive deck, binder or cube name"),
    Other("other", "Something else");

    /** Harassment suggests blocking too. */
    val blocksByDefault get() = this == Harassment
}

/** What players are told before joining an event (contract § UX rules 9). */
object JoinNotice {
    const val TEXT = "Your name shows in this event's pairings and standings, to its players and anyone with its standings link."
}

/* ── sharing ── */

enum class SharePart(val wire: String, val label: String, val detail: String) {
    Profile("profile", "Profile", "Who can open your profile at all"),
    Record("record", "Record", "Lifetime wins, losses and draws"),
    /** Who sees your friends list on your profile; who sees you in your friends' lists (§ Friends on profiles). */
    Friends("friends", "Friends", "Your list, on your profile"),
    Listed("listed", "You in friends' lists", "You, on friends' profiles"),
    Library("library", "Library", "The default for everything in it"),
    AllCards("all_cards", "All cards", "Your whole collection"),
    ForTrade("for_trade", "For trade", "Copies in for-trade binders, as one list. Trade matches read this"),
    Wants("wants", "Wants", "Your wishlist, without max prices"),
    Binders("binders", "Binders", "The default for each binder"),
    Decks("decks", "Decks", "The default for each deck"),
    Cubes("cubes", "Cubes", "The default for each cube");

    /** Library parts can be "Same as Library". */
    val inherits get() = this in libraryParts

    companion object {
        val libraryParts = listOf(AllCards, ForTrade, Wants, Binders, Decks, Cubes)
    }
}

@Serializable
data class ShareItem(val kind: String, val id: String, val name: String, @SerialName("for_trade") val forTrade: Boolean? = null,
                     val visibility: String? = null) {
    val group get() = when (kind) { "binder" -> SharePart.Binders; "cube" -> SharePart.Cubes; else -> SharePart.Decks }
    val vis get() = Visibility.of(visibility)
}

@Serializable
data class Sharing(
    val profile: String = "friends", val library: String = "private",
    @SerialName("all_cards") val allCards: String? = null, @SerialName("for_trade") val forTrade: String? = null,
    val wants: String? = null, val binders: String? = null, val decks: String? = null, val cubes: String? = null,
    val record: String = "private",
    /** null from a server without them: private and friends (the server's defaults). */
    val friends: String? = null, val listed: String? = null,
    val items: List<ShareItem> = emptyList(),
    /** Live share links (contract/share-links-2026-10-23.md); null from a server without them. */
    val links: List<PartLink>? = null,
) {
    /** A part's own setting (null = same as the level above). */
    fun own(p: SharePart): Visibility? = Visibility.of(when (p) {
        SharePart.Profile -> profile; SharePart.Library -> library; SharePart.Record -> record
        SharePart.AllCards -> allCards; SharePart.ForTrade -> forTrade; SharePart.Wants -> wants
        SharePart.Binders -> binders; SharePart.Decks -> decks; SharePart.Cubes -> cubes
        SharePart.Friends -> friends ?: "private"; SharePart.Listed -> listed ?: "friends"
    })

    fun with(p: SharePart, v: Visibility?): Sharing {
        val w = v?.wire
        return when (p) {
            SharePart.Profile -> copy(profile = w ?: "friends"); SharePart.Library -> copy(library = w ?: "private")
            SharePart.Record -> copy(record = w ?: "private"); SharePart.AllCards -> copy(allCards = w)
            SharePart.ForTrade -> copy(forTrade = w); SharePart.Wants -> copy(wants = w); SharePart.Binders -> copy(binders = w)
            SharePart.Decks -> copy(decks = w); SharePart.Cubes -> copy(cubes = w)
            SharePart.Friends -> copy(friends = w ?: "private"); SharePart.Listed -> copy(listed = w ?: "friends")
        }
    }
}

/* ── share links (contract/share-links-2026-10-23.md) ── */

/** "Anyone with the link" for one part: whoever holds it sees that part and nothing else, signed out too. */
@Serializable
data class PartLink(val part: String, val id: String? = null, val token: String, @SerialName("created_at") val createdAt: String? = null) {
    val url get() = url(token)
    companion object { fun url(token: String) = "https://table-1.site/l/$token" }
}

/** A part of your Library you can share: All cards, For trade, Wants, or one binder, deck or cube. */
data class ShareTarget(val part: String, val id: String? = null, val name: String? = null, val forTrade: Boolean? = null) {
    val title get() = name ?: partTitle(part)
    val isItem get() = id != null
    /** The Sharing part behind All cards / For trade / Wants (items use their ShareItem). */
    val sharePart get() = SharePart.entries.firstOrNull { it.wire == part && it in listOf(SharePart.AllCards, SharePart.ForTrade, SharePart.Wants) }

    /** What a link shows, for "Anyone with it sees …". */
    val what get() = when (part) {
        "all_cards" -> "every card you own"
        "for_trade" -> "the copies in your for-trade binders"
        "wants" -> "your wishlist"
        "binder" -> "every card in this binder, with condition and language"
        else -> "every card in this $part"
    }

    /** The confirm before making a link. */
    val confirmMessage get() = buildString {
        append("Anyone with the link sees $what, even without a Table 1 account. Nothing else on your profile shows. You can stop sharing it any time.")
        if (part == "all_cards") append(" Your total value is never shown.")
        if (part == "wants") append(" Your max prices are never shown.")
    }

    /** The same part on your profile, for people the settings already reach. */
    fun profileUrl(me: String) = "https://table-1.site/u/$me/$part" + (id?.let { "/$it" } ?: "")
    fun matches(l: PartLink) = l.part == part && l.id == id

    companion object {
        val AllCards = ShareTarget("all_cards"); val ForTrade = ShareTarget("for_trade"); val Wants = ShareTarget("wants")
        fun partTitle(part: String) = mapOf("all_cards" to "All cards", "for_trade" to "For trade", "wants" to "Wants")[part]
            ?: part.replaceFirstChar { it.uppercase() }
    }
}

/** What a link shows before its cards: the part, its name, the owner's name and photo. */
@Serializable
data class SharedLinkData(
    val part: String, val id: String? = null, val name: String? = null, val format: String? = null,
    @SerialName("for_trade") val forTrade: Boolean? = null, val cards: Int = 0, val owner: Owner, val mine: Boolean = false,
) {
    @Serializable data class Owner(@SerialName("display_name") val displayName: String, @SerialName("avatar_url") val avatarUrl: String? = null)
    val title get() = name ?: ShareTarget.partTitle(part)
    val byline get() = if (mine) "Your link · anyone with it sees this" else "Shared by ${owner.displayName}"
}

object SharingRules {
    /** What a part is set to after following "Same as …" up the tree. */
    fun effective(s: Sharing, p: SharePart): Visibility = s.own(p) ?: if (p.inherits) s.own(SharePart.Library)!! else Visibility.Private

    fun effective(s: Sharing, item: ShareItem): Visibility = item.vis ?: effective(s, item.group)

    /** Who it actually reaches: the profile caps every part. */
    fun reach(s: Sharing, v: Visibility): Visibility {
        val profile = s.own(SharePart.Profile)!!
        return if (profile.asks >= v.asks) profile else v
    }

    /** The part is set wider than the profile lets it go. */
    fun capped(s: Sharing, v: Visibility) = s.own(SharePart.Profile)!!.asks > v.asks

    /** The server's check: a viewer at [level] (3 you, 1 friend, 0 any other account, -1 blocked) sees it. */
    fun sees(level: Int, profile: Visibility, part: Visibility) = level >= 3 || (level >= 0 && level >= profile.asks && level >= part.asks)

    fun sharedCount(s: Sharing): Int =
        (SharePart.libraryParts + SharePart.Record + SharePart.Friends).count { reach(s, effective(s, it)) != Visibility.Private } +
            s.items.count { it.vis != null && reach(s, effective(s, it)) != Visibility.Private }

    fun summary(s: Sharing): String {
        val n = sharedCount(s)
        return "Profile ${s.own(SharePart.Profile)!!.label.lowercase()} · " + if (n == 0) "nothing shared" else "$n shared"
    }

    /** Who a part reaches once the profile cap applies (Record and the Library parts). */
    fun reachOf(s: Sharing, p: SharePart): Visibility = if (p == SharePart.Profile) s.own(SharePart.Profile)!! else reach(s, effective(s, p))

    fun reachOf(s: Sharing, item: ShareItem): Visibility = reach(s, effective(s, item))

    /** What newly reaches friends and anyone (contract § UX rules 4). Empty = only narrows or does nothing: no question. */
    data class Widening(
        val friends: List<String> = emptyList(), val anyone: List<String> = emptyList(),
        val allCardsToAnyone: Boolean = false, val profileToAnyone: Boolean = false,
    ) {
        val isEmpty get() = friends.isEmpty() && anyone.isEmpty()
        val title get() = if (anyone.isEmpty()) "Show to friends?" else "Show to anyone on Table 1?"
        val message get() = listOfNotNull(
            anyone.takeIf { it.isNotEmpty() }?.let { "Anyone on Table 1 will see: ${it.joinToString(", ")}." },
            friends.takeIf { it.isNotEmpty() }?.let { "Friends will see: ${it.joinToString(", ")}." },
            if (allCardsToAnyone) "Every card you own. Your total value is never shown." else null,
            if (profileToAnyone) "Your profile shows up when people search your name." else null,
        ).joinToString("\n\n")
    }

    val shownParts = listOf(SharePart.Profile to "your profile", SharePart.Record to "your record", SharePart.Friends to "your friends",
        SharePart.AllCards to "All cards", SharePart.ForTrade to "For trade", SharePart.Wants to "Wants")
    /** Widening also names you in your friends' lists (the Sharing summary lines don't: it shows on their profiles). */
    val wideningParts = shownParts.take(3) + (SharePart.Listed to "you in your friends' lists") + shownParts.drop(3)

    fun widening(a: Sharing, b: Sharing): Widening {
        val friends = mutableListOf<String>(); val anyone = mutableListOf<String>()
        var allCards = false; var profile = false
        fun add(name: String, to: Visibility) { if (to == Visibility.Public) anyone += name else friends += name }
        for ((p, name) in wideningParts) {
            val ra = reachOf(a, p); val rb = reachOf(b, p)
            if (rb.asks >= ra.asks) continue
            add(name, rb)
            if (p == SharePart.AllCards && rb == Visibility.Public) allCards = true
            if (p == SharePart.Profile && rb == Visibility.Public) profile = true
        }
        val before = a.items.associateBy { it.id }
        for (kind in listOf("binder", "deck", "cube")) for (to in listOf(Visibility.Public, Visibility.Friends)) {
            val opened = b.items.filter { item ->
                item.kind == kind && reachOf(b, item) == to && to.asks < (before[item.id]?.let { reachOf(a, it) } ?: Visibility.Private).asks
            }
            if (opened.size == 1) add(opened[0].name, to) else if (opened.size > 1) add("${opened.size} ${kind}s", to)
        }
        return Widening(friends, anyone, allCards, profile)
    }

    /** The line per audience at the top of Sharing (contract § UX rules 5). Name and photo always show. */
    fun seesLine(s: Sharing, level: Int): String {
        val names = mutableListOf("your name and photo")
        val profile = s.own(SharePart.Profile)!!
        if (level >= profile.asks) {
            for ((p, name) in shownParts) if (p != SharePart.Profile && sees(level, profile, effective(s, p))) names += name
            for (kind in listOf("binder", "deck", "cube")) {
                val n = s.items.count { it.kind == kind && sees(level, profile, effective(s, it)) }
                if (n > 0) names += "$n $kind${if (n == 1) "" else "s"}"
            }
        }
        return (if (level >= 1) "Friends see: " else "Anyone on Table 1 sees: ") + names.joinToString(", ") + "."
    }

    /** Your own profile as a friend (level 1) or anyone (level 0) would get it from profile_view (contract § UX rules 5). */
    fun viewAs(d: ProfileData, s: Sharing, level: Int): ProfileData {
        val profile = s.own(SharePart.Profile)!!
        val visible = level >= profile.asks
        val base = d.copy(relation = if (level >= 1) "friend" else "none", visible = visible)
        if (!visible) return base.copy(sections = ProfileData.Sections())
        fun ok(v: Visibility) = sees(level, profile, v)
        val items = s.items.associateBy { it.id }
        fun itemOk(id: String, group: SharePart) = ok(items[id]?.let { effective(s, it) } ?: effective(s, group))
        val src = d.sections
        val tradeOk = ok(effective(s, SharePart.ForTrade))
        val tradeBinders = src.binders.orEmpty().filter { it.forTrade && (tradeOk || itemOk(it.id, SharePart.Binders)) }
        return base.copy(sections = ProfileData.Sections(
            allCards = src.allCards?.takeIf { ok(effective(s, SharePart.AllCards)) }?.copy(valueUsd = null),
            forTrade = if (tradeBinders.isEmpty()) null else ProfileData.Counts(cards = tradeBinders.sumOf { it.cards }),
            wants = src.wants?.takeIf { ok(effective(s, SharePart.Wants)) },
            binders = src.binders.orEmpty().filter { itemOk(it.id, SharePart.Binders) },
            decks = src.decks.orEmpty().filter { itemOk(it.id, SharePart.Decks) },
            cubes = src.cubes.orEmpty().filter { itemOk(it.id, SharePart.Cubes) },
            record = src.record?.takeIf { ok(s.own(SharePart.Record)!!) },
            // How many a viewer would see depends on each friend's own setting, which isn't yours to know.
            friends = if (ok(effective(s, SharePart.Friends))) ProfileData.FriendsCount() else null,
        ))
    }

    fun change(p: SharePart, v: Visibility?): JsonObject = buildJsonObject { put(p.wire, v?.wire?.let(::JsonPrimitive) ?: JsonNull) }

    fun change(item: ShareItem, v: Visibility?): JsonObject = buildJsonObject {
        put("items", buildJsonArray {
            add(buildJsonObject {
                put("kind", item.kind); put("id", item.id)
                put("visibility", v?.wire?.let(::JsonPrimitive) ?: JsonNull)
            })
        })
    }
}

/* ── profiles ── */

/** Words for friends lists on profiles (contract § Friends on profiles; cases in testdata/sharing/cases.json `profile_friends`). */
object ProfileFriends {
    /** The Friends row on someone's profile: "3 mutual", or nothing. */
    fun detail(mutual: Int?): String? = mutual?.takeIf { it > 0 }?.let { "$it mutual" }

    /** The Friends row on your own profile: who it reaches. */
    fun ownDetail(reach: Visibility) = when (reach) {
        Visibility.Private -> "Only you"
        Visibility.Friends -> "Seen by friends"
        Visibility.Public -> "Seen by anyone"
    }

    /** One person in the list: "You", "Mutual friend", or their handle. */
    fun rowDetail(p: Person): String? = when {
        p.relation == "self" -> "You"
        p.mutual == true -> "Mutual friend"
        else -> p.handle?.let { "@$it" }
    }
}

@Serializable
private data class FriendsPage(val rows: List<Person>, val more: Boolean)

@Serializable
data class ProfileData(
    @SerialName("user_id") val userId: String,
    @SerialName("display_name") val displayName: String,
    val handle: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val relation: String = "none",
    @SerialName("friends_since") val friendsSince: String? = null,
    val visible: Boolean = false,
    val sections: Sections = Sections(),
) {
    @Serializable data class Counts(val cards: Int, val printings: Int? = null, @SerialName("value_usd") val valueUsd: Double? = null)
    @Serializable data class BinderSummary(val id: String, val name: String, @SerialName("for_trade") val forTrade: Boolean = false, val cards: Int = 0)
    @Serializable data class ListSummary(val id: String, val name: String, val format: String = "", val cards: Int = 0)
    @Serializable data class Record(
        @SerialName("match_wins") val matchWins: Int, @SerialName("match_losses") val matchLosses: Int,
        @SerialName("match_draws") val matchDraws: Int, @SerialName("events_played") val eventsPlayed: Int,
    )
    /** The friends list reaches you; [mutual]: how many shown are your friends too (null in View as). */
    @Serializable data class FriendsCount(val mutual: Int? = null)
    @Serializable data class Sections(
        @SerialName("all_cards") val allCards: Counts? = null, @SerialName("for_trade") val forTrade: Counts? = null,
        val wants: Counts? = null, val binders: List<BinderSummary>? = null, val decks: List<ListSummary>? = null,
        val cubes: List<ListSummary>? = null, val record: Record? = null, val friends: FriendsCount? = null,
    )

    /** The collection's value, on your own profile only (the server sends it only there now; older servers sent it to
     *  anyone who saw All cards). */
    val valueUsd get() = if (relation == "self") sections.allCards?.valueUsd else null

    /** Sections that reach you (binders, decks and cubes count one each). */
    val sectionCount get() = listOf(sections.allCards, sections.forTrade, sections.wants, sections.record, sections.friends).count { it != null } +
        (sections.binders?.size ?: 0) + (sections.decks?.size ?: 0) + (sections.cubes?.size ?: 0)
}

/** One row of profile_cards, whatever the section's shape. */
data class ProfileCard(
    val cardId: String? = null, val oracleId: String? = null, val finish: String? = null, val condition: String? = null,
    val lang: String? = null, val board: String? = null, val qty: Int,
) {
    companion object {
        /** all_cards [card, finish, qty] · for_trade / binder [card, finish, condition, lang, qty] · deck / cube
         *  [card, board, qty] · wants [oracle, card?, finish?, qty] */
        fun parse(section: String, r: List<JsonElement>): ProfileCard? {
            fun s(i: Int) = (r.getOrNull(i) as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            fun n(i: Int) = (r.getOrNull(i) as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
            return when (section) {
                "all_cards" -> n(2)?.let { ProfileCard(cardId = s(0), finish = s(1), qty = it) }
                "for_trade", "binder" -> n(4)?.let { ProfileCard(cardId = s(0), finish = s(1), condition = s(2), lang = s(3), qty = it) }
                "deck", "cube" -> n(2)?.let { ProfileCard(cardId = s(0), board = s(1), qty = it) }
                "wants" -> n(3)?.let { ProfileCard(cardId = s(1), oracleId = s(0), finish = s(2), qty = it) }
                else -> null
            }
        }
    }
}

/** A deck or cube opened from a profile: what Export and Copy to my Library need beyond its cards
 *  (contract/shared-lists-grouping-2026-10-20.md §1). */
object SharedList {
    fun kind(section: String): ListKind? = when (section) { "deck" -> ListKind.Deck; "cube" -> ListKind.Cube; else -> null }

    /** The shared rows as list lines (profile_cards sends no finish, so copies are non-foil), merged per card and board. */
    fun entries(rows: List<ProfileCard>): List<ListEntry> {
        val qty = LinkedHashMap<Pair<String, String>, Int>()
        for (r in rows) {
            val id = r.cardId ?: continue
            if (r.qty <= 0) continue
            qty.merge(id to (r.board ?: "main"), r.qty, Int::plus)
        }
        return qty.map { (k, n) -> ListEntry(k.first, k.second, n) }
    }

    /** A deck's count leaves out Considering, like the profile row. */
    fun count(rows: List<ProfileCard>, kind: ListKind?): Int = rows.filter { kind != ListKind.Deck || it.board != "maybe" }.sumOf { it.qty }

    /** The first version's note on a copy, so its history says where it came from (owner null: your own profile). */
    fun copyNote(owner: String?, name: String) = if (owner != null) "Copied from $owner's $name" else "Copied from $name"
}

/** profile_cards / shared_cards. Decoded by supabase-kt's runtime serializer lookup, so a missing @Serializable
 *  only fails when called ("Serializer for class … is not found"); FriendsTest decodes it the same way. */
@Serializable
internal data class ProfileCardsPage(val rows: List<JsonArray> = emptyList(), val more: Boolean = false)

/* ── trade matches ── */

@Serializable
data class WantKey(@SerialName("oracle_id") val oracleId: String, @SerialName("card_id") val cardId: String? = null, val finish: String? = null) {
    /** exact / printing / any */
    val tier get() = if (finish != null) "exact" else if (cardId != null) "printing" else "any"
}

@Serializable
data class MatchLine(
    @SerialName("card_id") val cardId: String, val finish: String, val condition: String = "NM", val lang: String = "en",
    /** They want: your binder the copies are in. */
    @SerialName("binder_id") val binderId: String? = null,
    val qty: Int, val want: WantKey, val usd: Double? = null,
    /** They have: your want has a max and the price is above it. */
    @SerialName("over_max") val overMax: Boolean? = null,
) {
    val key get() = itemKey(cardId, finish, condition, lang)
}

@Serializable
data class TradeMatch(
    @SerialName("user_id") val userId: String, @SerialName("display_name") val displayName: String, val handle: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null, val friend: Boolean = false,
    @SerialName("they_have") val theyHave: List<MatchLine> = emptyList(), @SerialName("they_want") val theyWant: List<MatchLine> = emptyList(),
    @SerialName("have_copies") val haveCopies: Int = 0, @SerialName("want_copies") val wantCopies: Int = 0,
    @SerialName("have_usd") val haveUsd: Double = 0.0, @SerialName("want_usd") val wantUsd: Double = 0.0,
) {
    /** The list row: "Has 3 · wants 2". */
    val short get() = listOfNotNull(if (haveCopies > 0) "Has $haveCopies" else null,
        if (wantCopies > 0) "${if (haveCopies > 0) "wants" else "Wants"} $wantCopies" else null).joinToString(" · ")
    val summary get() = listOfNotNull(if (haveCopies > 0) "Has $haveCopies you want" else null,
        if (wantCopies > 0) "Wants $wantCopies you have" else null).joinToString(" · ")
}

@Serializable private data class MatchesResult(val people: List<TradeMatch> = emptyList())
@Serializable private data class Status(val status: String? = null)
@Serializable private data class Started(val id: String)

/**
 * The server's matching (t1_private.want_match) on the device, for the shared test cases in testdata/trade-matches.
 * Wants for that printing and finish take copies first, then wants for that printing in any finish, then wants for any
 * printing; within a want NM first, then cheaper (no price last), then English. A copy is used once; a want up to its qty.
 */
object TradeMatcher {
    data class WantIn(val oracleId: String, val cardId: String? = null, val finish: String? = null, val qty: Int, val maxUsd: Double? = null) {
        val key get() = WantKey(oracleId, cardId, finish)
    }
    data class CopyIn(val oracleId: String, val cardId: String, val finish: String, val condition: String, val lang: String,
                      val binderId: String? = null, val qty: Int, val usd: Double? = null)

    private data class Part(val qty: Int, val tier: Int, val want: WantIn)

    fun lines(wants: List<WantIn>, copies: List<CopyIn>): List<MatchLine> {
        fun crank(c: String) = mapOf("NM" to 0, "LP" to 1, "MP" to 2, "HP" to 3)[c] ?: 4
        val order = copies.indices.sortedWith { a, b ->
            val x = copies[a]; val y = copies[b]
            when {
                crank(x.condition) != crank(y.condition) -> crank(x.condition) - crank(y.condition)
                x.usd != null && y.usd != null && x.usd != y.usd -> x.usd.compareTo(y.usd)
                x.usd != null && y.usd == null -> -1
                x.usd == null && y.usd != null -> 1
                (x.lang == "en") != (y.lang == "en") -> if (x.lang == "en") -1 else 1
                else -> a - b
            }
        }
        val left = copies.map { it.qty }.toIntArray()
        val got = sortedMapOf<Int, MutableList<Part>>()
        val tiers: List<Triple<Int, (WantIn) -> Boolean, (WantIn, CopyIn) -> Boolean>> = listOf(
            Triple(0, { w -> w.cardId != null && w.finish != null }, { w, c -> c.cardId == w.cardId && c.finish == w.finish }),
            Triple(1, { w -> w.cardId != null && w.finish == null }, { w, c -> c.cardId == w.cardId }),
            Triple(2, { w -> w.cardId == null }, { w, c -> c.oracleId == w.oracleId }),
        )
        for ((tier, isTier, meets) in tiers) {
            for (w in wants) {
                if (w.qty <= 0 || !isTier(w)) continue
                var need = w.qty
                for (i in order) {
                    if (need <= 0) break
                    if (left[i] <= 0 || !meets(w, copies[i])) continue
                    val n = minOf(need, left[i])
                    left[i] -= n
                    need -= n
                    got.getOrPut(i) { mutableListOf() }.add(Part(n, tier, w))
                }
            }
        }
        return got.map { (i, parts) ->
            val c = copies[i]
            val first = parts.minBy { it.tier }
            val over = parts.any { p -> p.want.maxUsd != null && c.usd != null && c.usd > p.want.maxUsd }
            MatchLine(c.cardId, c.finish, c.condition, c.lang, c.binderId, parts.sumOf { it.qty }, first.want.key, c.usd, over)
        }.sortedWith(compareBy<MatchLine>({ it.cardId }, { it.finish }, { it.condition }, { it.lang }))
    }

    /** They have: under-max first, dearest first (the server's order). */
    fun shown(lines: List<MatchLine>) = lines.sortedWith(compareBy<MatchLine>({ it.overMax == true }, { -(it.usd ?: -1.0) }, { it.cardId }, { it.finish }))

    fun value(lines: List<MatchLine>, skipOverMax: Boolean) = lines.filter { !(skipOverMax && it.overMax == true) }.sumOf { it.qty * (it.usd ?: 0.0) }
}

/* ── store ── */

data class FriendsState(
    val list: FriendsList? = null, val sharing: Sharing? = null, val matches: List<TradeMatch>? = null, val error: String? = null,
) {
    val requestsWaiting get() = list?.incoming?.size ?: 0
}

object FriendsStore {
    private val _state = MutableStateFlow(FriendsState())
    val state: StateFlow<FriendsState> = _state.asStateFlow()
    private val rpc get() = T1App.supabase.postgrest

    fun stop() { _state.value = FriendsState() }

    private fun fail(e: Throwable) { e.rethrowIfCancelled(); _state.update { it.copy(error = e.message) } }

    suspend fun load() {
        runCatching { rpc.rpc("friends_list").decodeAs<FriendsList>() }
            .onSuccess { l -> _state.update { it.copy(list = l, error = null) } }.onFailure(::fail)
    }

    /** Played-with suggestions (empty query) or a search that also finds public profiles. */
    suspend fun search(query: String): List<Person> = rpc.rpc("friend_search", buildJsonObject {
        val q = query.trim()
        if (q.isEmpty()) put("p_query", JsonNull) else put("p_query", q)
        put("p_limit", 30)
    }).decodeAs()

    /** Asks them (or accepts, if they asked you). [via]: search / played_with / profile. */
    suspend fun request(userId: String, via: String): String {
        val r = rpc.rpc("friend_request", buildJsonObject { put("p_user_id", userId) }).decodeAs<Status>()
        Telemetry.capture("friend_request_sent", mapOf("via" to via))
        load()
        return r.status ?: "requested"
    }

    suspend fun requestByEmail(email: String) {
        rpc.rpc("friend_request_by_email", buildJsonObject { put("p_email", email) })
        Telemetry.capture("friend_request_sent", mapOf("via" to "email"))
        load()
    }

    suspend fun respond(userId: String, accept: Boolean) {
        rpc.rpc("friend_respond", buildJsonObject { put("p_user_id", userId); put("p_accept", accept) })
        Telemetry.capture("friend_request_responded", mapOf("accepted" to accept))
        load()
    }

    /** Cancels your request, or unfriends. */
    suspend fun remove(userId: String) {
        val wasFriend = _state.value.list?.friends?.any { it.userId == userId } == true
        rpc.rpc("friend_remove", buildJsonObject { put("p_user_id", userId) })
        Telemetry.capture(if (wasFriend) "friend_removed" else "friend_request_cancelled")
        load()
        _state.update { s -> s.copy(matches = s.matches?.filter { it.userId != userId }) }
    }

    /** Cancels a request you made by email (an `{email, at}` row in Sent). */
    suspend fun cancelEmail(email: String) {
        rpc.rpc("friend_cancel_email", buildJsonObject { put("p_email", email) })
        Telemetry.capture("friend_request_cancelled", mapOf("via" to "email"))
        load()
    }

    /** Cancels a row in Sent, whichever way it was asked. */
    suspend fun cancel(r: SentRequest) {
        if (r.person != null) remove(r.person.userId) else r.email?.let { cancelEmail(it) }
    }

    suspend fun block(userId: String, on: Boolean) {
        rpc.rpc("user_block", buildJsonObject { put("p_user_id", userId); put("p_blocked", on) })
        Telemetry.capture("user_blocked", mapOf("blocked" to on))
        load()
        if (on) _state.update { s -> s.copy(matches = s.matches?.filter { it.userId != userId }) }
    }

    /** Reports an account (contract § UX rules 6); [block] also blocks them. [from]: profile / friends / request / search / trade_match. */
    suspend fun report(userId: String, reason: ReportReason, note: String, from: String, item: Pair<String, String>? = null, block: Boolean) {
        val trimmed = note.trim().take(500)
        rpc.rpc("user_report", buildJsonObject {
            put("p_user_id", userId); put("p_reason", reason.wire)
            if (trimmed.isEmpty()) put("p_note", JsonNull) else put("p_note", trimmed)
            put("p_context", buildJsonObject { put("from", from); item?.let { put("kind", it.first); put("id", it.second) } })
            put("p_block", block)
        })
        Telemetry.capture("user_reported", mapOf("reason" to reason.wire, "from" to from, "blocked" to block))
        if (block) {
            Telemetry.capture("user_blocked", mapOf("blocked" to true))
            _state.update { s -> s.copy(matches = s.matches?.filter { it.userId != userId }) }
        }
        load()
    }

    /** A binder, deck or cube's sharing row (made up from its group when sharing_get hasn't listed it yet). */
    fun shareItem(kind: String, id: String, name: String, forTrade: Boolean? = null): ShareItem =
        _state.value.sharing?.items?.firstOrNull { it.id == id } ?: ShareItem(kind, id, name, forTrade)

    /** What a change would newly show, to ask first (contract § UX rules 4); empty when it only narrows. */
    fun widening(p: SharePart, v: Visibility?): SharingRules.Widening {
        val s = _state.value.sharing ?: return SharingRules.Widening()
        return SharingRules.widening(s, s.with(p, v))
    }

    fun widening(item: ShareItem, v: Visibility?): SharingRules.Widening {
        val s = _state.value.sharing ?: return SharingRules.Widening()
        val next = if (s.items.any { it.id == item.id }) s.items.map { if (it.id == item.id) it.copy(visibility = v?.wire) else it }
            else s.items + item.copy(visibility = v?.wire)
        return SharingRules.widening(s, s.copy(items = next))
    }

    /** Several parts at once (a sharing offer: the offer was the question). */
    suspend fun setAll(parts: List<SharePart>, v: Visibility) {
        val s = _state.value.sharing ?: return
        val next = parts.fold(s) { acc, p -> acc.with(p, v) }
        save(s, next, buildJsonObject { parts.forEach { put(it.wire, v.wire) } }, parts.joinToString(",") { it.wire }, v)
    }

    suspend fun loadSharing() {
        runCatching { rpc.rpc("sharing_get").decodeAs<Sharing>() }
            .onSuccess { s -> _state.update { it.copy(sharing = s, error = null) } }.onFailure(::fail)
    }

    suspend fun set(p: SharePart, v: Visibility?) {
        val s = _state.value.sharing ?: return
        if (s.own(p) == v || (!p.inherits && v == null)) return
        save(s, s.with(p, v), SharingRules.change(p, v), p.wire, v)
    }

    suspend fun set(item: ShareItem, v: Visibility?) {
        val s = _state.value.sharing ?: return
        if (item.vis == v) return
        val items = if (s.items.any { it.id == item.id }) s.items.map { if (it.id == item.id) it.copy(visibility = v?.wire) else it }
            else s.items + item.copy(visibility = v?.wire)
        save(s, s.copy(items = items), SharingRules.change(item, v), item.kind, v)
    }

    private suspend fun save(before: Sharing, next: Sharing, change: JsonObject, part: String, v: Visibility?) {
        _state.update { it.copy(sharing = next) } // shows at once; put back if the server refuses
        runCatching { rpc.rpc("sharing_set", buildJsonObject { put("p_settings", change) }).decodeAs<Sharing>() }
            .onSuccess { s ->
                _state.update { it.copy(sharing = s, error = null) }
                Telemetry.capture("sharing_changed", mapOf("part" to part, "visibility" to (v?.wire ?: "inherit")))
            }
            .onFailure { e -> _state.update { it.copy(sharing = before, error = e.message) } }
    }

    // share links

    fun link(t: ShareTarget): PartLink? = _state.value.sharing?.links?.firstOrNull(t::matches)

    /** The live link for a part, made if there isn't one; [new] retires the old link first. */
    suspend fun makeLink(t: ShareTarget, new: Boolean = false): PartLink {
        val l = rpc.rpc("share_link_create", buildJsonObject {
            put("p_part", t.part); if (t.id == null) put("p_id", JsonNull) else put("p_id", t.id); put("p_new", new)
        }).decodeAs<PartLink>()
        _state.update { s -> s.copy(sharing = s.sharing?.let { sh -> sh.copy(links = (sh.links ?: emptyList()).filterNot(t::matches) + l) }) }
        Telemetry.capture("share_link_created", mapOf("part" to t.part, "new" to new))
        return l
    }

    /** Stop sharing the link: it stops working for anyone holding it. The part's setting doesn't change. */
    suspend fun stopLink(t: ShareTarget) {
        rpc.rpc("share_link_revoke", buildJsonObject { put("p_part", t.part); if (t.id == null) put("p_id", JsonNull) else put("p_id", t.id) })
        _state.update { s -> s.copy(sharing = s.sharing?.let { sh -> sh.copy(links = (sh.links ?: emptyList()).filterNot(t::matches)) }) }
        Telemetry.capture("share_link_stopped", mapOf("part" to t.part))
    }

    /** What a link shows (the server checks the link). */
    suspend fun shared(token: String): SharedLinkData = rpc.rpc("shared_view", buildJsonObject { put("p_token", token) }).decodeAs()

    /** Every card behind a link, 5000 at a time, in profile_cards' shapes. */
    suspend fun sharedCards(token: String, part: String): List<ProfileCard> {
        val out = mutableListOf<ProfileCard>()
        var after = 0
        while (true) {
            val page = rpc.rpc("shared_cards", buildJsonObject {
                put("p_token", token); put("p_after", after); put("p_limit", 5000)
            }).decodeAs<ProfileCardsPage>()
            page.rows.mapNotNullTo(out) { ProfileCard.parse(part, it) }
            after += page.rows.size
            if (!page.more || page.rows.isEmpty()) return out
        }
    }

    suspend fun profile(userId: String): ProfileData =
        rpc.rpc("profile_view", buildJsonObject { put("p_user_id", userId) }).decodeAs()

    /** The friends behind a profile's Friends section that reach you: mutual first, then by name (profile_friends). */
    suspend fun friendsOf(userId: String): List<Person> {
        val out = mutableListOf<Person>()
        var after = 0
        while (true) {
            val page = rpc.rpc("profile_friends", buildJsonObject {
                put("p_user_id", userId); put("p_after", after); put("p_limit", 500)
            }).decodeAs<FriendsPage>()
            out += page.rows
            after += page.rows.size
            if (!page.more || page.rows.isEmpty()) return out
        }
    }

    /** Every row of a section, 5000 at a time. */
    suspend fun cards(userId: String, section: String, item: String?): List<ProfileCard> {
        val out = mutableListOf<ProfileCard>()
        var after = 0
        while (true) {
            val page = rpc.rpc("profile_cards", buildJsonObject {
                put("p_user_id", userId); put("p_section", section)
                if (item == null) put("p_id", JsonNull) else put("p_id", item)
                put("p_after", after); put("p_limit", 5000)
            }).decodeAs<ProfileCardsPage>()
            page.rows.mapNotNullTo(out) { ProfileCard.parse(section, it) }
            after += page.rows.size
            if (!page.more || page.rows.isEmpty()) return out
        }
    }

    private suspend fun fetchMatches(only: String?): List<TradeMatch> = rpc.rpc("trade_matches", buildJsonObject {
        if (only == null) put("p_user_id", JsonNull) else put("p_user_id", only)
    }).decodeAs<MatchesResult>().people

    suspend fun loadMatches() {
        runCatching { fetchMatches(null) }.onSuccess { m -> _state.update { it.copy(matches = m, error = null) } }.onFailure(::fail)
    }

    suspend fun matchWith(userId: String): TradeMatch? {
        val m = fetchMatches(userId).firstOrNull()
        if (m != null) _state.update { s ->
            s.copy(matches = s.matches?.let { all -> if (all.any { it.userId == userId }) all.map { if (it.userId == userId) m else it } else all + m })
        }
        return m
    }

    /** A trade draft from the match with that person; returns its id (in TradesStore once this returns). */
    suspend fun startTrade(m: TradeMatch): String {
        val t = rpc.rpc("trade_match_start", buildJsonObject {
            put("p_user_id", m.userId); put("p_idempotency_key", UUID.randomUUID().toString())
        }).decodeAs<Started>()
        TradesStore.load()
        Telemetry.capture("trade_started_from_match", mapOf("gives" to m.wantCopies, "gets" to m.haveCopies))
        return t.id
    }
}

/**
 * Sharing offers made at the moment they help, once per account on this device (contract § UX rules 8). Not now
 * counts as an answer. Same as iOS SharingOffer.
 */
enum class SharingOffer(val wire: String) {
    ForTrade("for_trade"), Matches("matches"), Record("record");

    private val prefs get() = T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE)
    private val key get() = "sharing_offer.$wire.${site.table1.events.data.Repo.userId ?: "none"}"
    val answered get() = prefs.getBoolean(key, false)

    fun answer(accepted: Boolean) {
        prefs.edit().putBoolean(key, true).apply()
        Telemetry.capture("sharing_offer", mapOf("offer" to wire, "accepted" to accepted))
    }

    companion object {
        /** An offer to show now (AppRoot shows it over whatever screen made it due). */
        val due = kotlinx.coroutines.flow.MutableStateFlow<SharingOffer?>(null)

        /** After a binder is marked For trade: offer when no one can see any of For trade yet. */
        suspend fun forTradeDue(): Boolean {
            if (ForTrade.answered) return false
            if (FriendsStore.state.value.sharing == null) FriendsStore.loadSharing()
            val s = FriendsStore.state.value.sharing ?: return false
            return SharingRules.reachOf(s, SharePart.ForTrade) == Visibility.Private &&
                s.items.none { it.forTrade == true && SharingRules.reachOf(s, it) != Visibility.Private }
        }
    }
}
