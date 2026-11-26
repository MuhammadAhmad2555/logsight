package com.logsight.apptrack

import java.util.Date

/** A point in time (epoch milliseconds, UTC); sent as a Firestore `timestampValue`. */
internal data class Timestamp(val millis: Long) {
    fun plusDays(days: Int) = Timestamp(millis + days * 86_400_000L)
    fun iso(): String = Iso.format(millis)
}

/** RFC 3339 / ISO 8601 UTC formatting without java.time (works on every Android API level). */
internal object Iso {
    fun format(millis: Long): String {
        val days = millis.floorDiv(86_400_000L)
        val msOfDay = millis.mod(86_400_000L)
        // Civil-from-days (Howard Hinnant).
        val z = days + 719_468
        val era = z.floorDiv(146_097L)
        val doe = z - era * 146_097
        val yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        var y = yoe + era * 400
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = doy - (153 * mp + 2) / 5 + 1
        val m = if (mp < 10) mp + 3 else mp - 9
        if (m <= 2) y += 1
        val h = msOfDay / 3_600_000
        val min = (msOfDay / 60_000) % 60
        val s = (msOfDay / 1000) % 60
        val ms = msOfDay % 1000
        return String.format(java.util.Locale.ROOT, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, m, d, h, min, s, ms)
    }

    /** Parses `yyyy-MM-ddTHH:mm:ss[.fraction](Z|±hh:mm)`; fractions beyond ms are truncated. */
    fun parse(text: String): Long {
        val t = text.trim()
        fun num(from: Int, len: Int) = t.substring(from, from + len).toInt()
        val y = num(0, 4).toLong()
        val mo = num(5, 2).toLong()
        val d = num(8, 2).toLong()
        val h = num(11, 2)
        val mi = num(14, 2)
        val s = num(17, 2)
        var i = 19
        var ms = 0
        if (i < t.length && t[i] == '.') {
            i++
            val start = i
            while (i < t.length && t[i].isDigit()) i++
            ms = (t.substring(start, i) + "000").substring(0, 3).toInt()
        }
        var offsetMin = 0
        if (i < t.length && (t[i] == '+' || t[i] == '-')) {
            val sign = if (t[i] == '-') -1 else 1
            offsetMin = sign * (num(i + 1, 2) * 60 + num(i + 4, 2))
        }
        // Days-from-civil.
        val yy = if (mo <= 2) y - 1 else y
        val era = yy.floorDiv(400L)
        val yoe = yy - era * 400
        val mp = (mo + 9) % 12
        val doy = (153 * mp + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        val days = era * 146_097 + doe - 719_468
        return days * 86_400_000L + h * 3_600_000L + mi * 60_000L + s * 1000L + ms - offsetMin * 60_000L
    }
}

/**
 * Turns a user value into a plain, immutable form that the queue file and
 * the Firestore encoder both understand: null, Boolean, String, Long, Double,
 * [Timestamp], Map<String, Any?>, List<Any?>. Unknown types become their text.
 */
internal fun normalize(v: Any?, depth: Int = 0): Any? {
    if (depth > 20) return v.toString()
    return when (v) {
        null, is Boolean, is String, is Long, is Double, is Timestamp -> v
        is Int -> v.toLong()
        is Short -> v.toLong()
        is Byte -> v.toLong()
        is Float -> v.toDouble()
        is Date -> Timestamp(v.time)
        is Map<*, *> -> LinkedHashMap<String, Any?>().also { m ->
            for ((k, e) in v) m[k.toString()] = normalize(e, depth + 1)
        }
        is Iterable<*> -> v.map { normalize(it, depth + 1) }
        is Array<*> -> v.map { normalize(it, depth + 1) }
        is IntArray -> v.map { it.toLong() }
        is LongArray -> v.toList()
        is DoubleArray -> v.toList()
        is FloatArray -> v.map { it.toDouble() }
        is BooleanArray -> v.toList()
        else -> v.toString()
    }
}

/** Encodes a value as a Firestore REST `Value` (same rules as the Dart SDK's `toFirestoreValue`). */
internal fun toFirestoreValue(v: Any?): Map<String, Any?> = when (v) {
    null -> mapOf("nullValue" to null)
    is Boolean -> mapOf("booleanValue" to v)
    is Byte, is Short, is Int, is Long -> mapOf("integerValue" to v.toString())
    is Float -> toFirestoreValue(v.toDouble())
    is Double -> if (v.isNaN() || v.isInfinite()) mapOf("stringValue" to v.toString()) else mapOf("doubleValue" to v)
    is Timestamp -> mapOf("timestampValue" to v.iso())
    is Date -> mapOf("timestampValue" to Iso.format(v.time))
    is Map<*, *> -> mapOf(
        "mapValue" to mapOf(
            "fields" to LinkedHashMap<String, Any?>().also { m ->
                for ((k, e) in v) m[k.toString()] = toFirestoreValue(e)
            },
        ),
    )
    is Iterable<*> -> mapOf("arrayValue" to mapOf("values" to v.map { toFirestoreValue(it) }))
    is Array<*> -> toFirestoreValue(v.asList())
    else -> mapOf("stringValue" to v.toString())
}

private val tokenSplit = Regex("[^a-z0-9_]+")

/**
 * Search tokens for a log message. Must match the dashboard's tokenizer (and
 * the Dart SDK's `tokenize`): lowercase, split on anything but `[a-z0-9_]`,
 * keep words of 2–40 characters, unique, in order, at most [maxTokens].
 */
fun tokenize(text: String, maxTokens: Int = 64): List<String> {
    val seen = LinkedHashSet<String>()
    if (maxTokens <= 0) return emptyList()
    for (raw in text.lowercase().split(tokenSplit)) {
        if (raw.length < 2 || raw.length > 40) continue
        seen.add(raw)
        if (seen.size >= maxTokens) break
    }
    return seen.toList()
}

/**
 * Builds the optional `error` field of a log, or null when there's nothing
 * to record. Values are trimmed and cut to the server's limits
 * (type 200, message 4000, reason 4000, stack 16000 characters).
 */
fun errorDetails(throwable: Throwable? = null, reason: String? = null, stack: String? = null): Map<String, String>? {
    fun cut(v: String?, max: Int): String? {
        val t = v?.trim()
        if (t.isNullOrEmpty()) return null
        return if (t.length > max) t.substring(0, max) else t
    }
    val out = LinkedHashMap<String, String>()
    if (throwable != null) {
        val type = throwable.javaClass.simpleName.ifEmpty { throwable.javaClass.name }
        cut(type, 200)?.let { out["type"] = it }
        cut(throwable.toString(), 4000)?.let { out["message"] = it }
    }
    cut(reason, 4000)?.let { out["reason"] = it }
    cut(stack ?: throwable?.stackTraceToString(), 16000)?.let { out["stack"] = it }
    return if (out.isEmpty()) null else out
}
