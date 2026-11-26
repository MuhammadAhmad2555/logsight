package com.logsight.apptrack

import java.io.File
import java.io.FileOutputStream

/**
 * JSON for queued logs and events (same format as the Dart SDK's
 * `queue_codec.dart`): timestamps are stored as `{"$dt": "<ISO 8601>"}` so
 * they come back as timestamps; non-finite doubles are stored as text.
 */
internal object QueueCodec {
    private const val DATE_KEY = "\$dt"

    fun encode(line: Map<String, Any?>): String = Json.encode(enc(line))

    @Suppress("UNCHECKED_CAST")
    fun decode(line: String): Map<String, Any?> =
        dec(Json.decode(line)) as? Map<String, Any?> ?: throw IllegalArgumentException("Not an object")

    private fun enc(v: Any?): Any? = when (v) {
        is Timestamp -> mapOf(DATE_KEY to v.iso())
        is Map<*, *> -> LinkedHashMap<String, Any?>().also { m -> for ((k, e) in v) m[k.toString()] = enc(e) }
        is Iterable<*> -> v.map { enc(it) }
        else -> v
    }

    private fun dec(v: Any?): Any? = when (v) {
        is Map<*, *> -> {
            val dt = v[DATE_KEY]
            if (v.size == 1 && dt is String) {
                Timestamp(Iso.parse(dt))
            } else {
                LinkedHashMap<String, Any?>().also { m -> for ((k, e) in v) m[k.toString()] = dec(e) }
            }
        }
        is List<*> -> v.map { dec(it) }
        else -> v
    }
}

/**
 * Keeps queued logs and events on disk so ones not yet sent survive the app
 * being killed, crashing or going offline, and are sent next launch.
 *
 * Same journal as the Dart SDK (`queue_store_io.dart`): JSON lines
 * `{"n":7,"q":{...}}` when item 7 is queued and `{"upto":7}` once items 1–7
 * have left the queue (sent, rejected or dropped). Writes go straight to the
 * OS (no buffering), so a line written just before a crash is kept. The file
 * is emptied when the queue empties and rewritten when it grows past
 * [compactBytes]. Errors are swallowed: logging must never crash the app.
 *
 * Not thread-safe on its own; the logger calls it while holding its lock.
 */
internal class QueueStore(val file: File, private val compactBytes: Long = 1024 * 1024) {
    private var out: FileOutputStream? = null
    private var failed = false

    /**
     * Items still waiting from earlier runs, oldest first, each with its
     * sequence number in `_n`. Rewrites the file to hold just those.
     */
    fun load(): List<MutableMap<String, Any?>> {
        try {
            if (!file.exists()) return emptyList()
            val items = HashMap<Long, MutableMap<String, Any?>>()
            var upto = 0L
            file.bufferedReader(Charsets.UTF_8).useLines { lines ->
                for (line in lines) {
                    if (line.isBlank()) continue
                    try {
                        val entry = QueueCodec.decode(line)
                        val done = entry["upto"]
                        if (done is Long && done > upto) upto = done
                        val n = entry["n"]
                        val q = entry["q"]
                        if (n is Long && q is Map<*, *>) {
                            val item = LinkedHashMap<String, Any?>()
                            for ((k, e) in q) item[k.toString()] = e
                            item["_n"] = n
                            items[n] = item
                        }
                    } catch (_: Exception) {
                        // A line cut short by a crash: skip it.
                    }
                }
            }
            val pending = items.entries.filter { it.key > upto }.sortedBy { it.key }.map { it.value }
            rewrite(pending)
            return pending
        } catch (_: Exception) {
            failed = true
            return emptyList()
        }
    }

    /** Records a newly queued item (with its `_n`). */
    fun added(item: Map<String, Any?>) {
        val n = item["_n"] as? Long ?: return
        append(mapOf("n" to n, "q" to item.filterKeys { it != "_n" }))
    }

    /**
     * Records that items up to [seq] left the queue; [remaining] is what's
     * still queued (used to empty or compact the file).
     */
    fun removedUpTo(seq: Long, remaining: List<Map<String, Any?>>) {
        if (failed) return
        if (remaining.isEmpty()) {
            truncate()
            return
        }
        append(mapOf("upto" to seq))
        try {
            if (file.length() > compactBytes) rewrite(remaining)
        } catch (_: Exception) {
            failed = true
        }
    }

    fun close() {
        try {
            out?.close()
        } catch (_: Exception) {
        }
        out = null
    }

    private fun open(): FileOutputStream {
        file.absoluteFile.parentFile?.mkdirs()
        return FileOutputStream(file, true)
    }

    private fun append(entry: Map<String, Any?>) {
        if (failed) return
        try {
            val o = out ?: open().also { out = it }
            o.write((QueueCodec.encode(entry) + "\n").toByteArray(Charsets.UTF_8))
        } catch (_: Exception) {
            failed = true
        }
    }

    private fun truncate() {
        try {
            val o = out ?: open().also { out = it }
            o.channel.truncate(0)
        } catch (_: Exception) {
            failed = true
        }
    }

    /** Replaces the file with just [items] (write a temp file, then rename). */
    private fun rewrite(items: List<Map<String, Any?>>) {
        close()
        val tmp = File(file.path + ".tmp")
        tmp.absoluteFile.parentFile?.mkdirs()
        val b = StringBuilder()
        for (item in items) {
            b.append(QueueCodec.encode(mapOf("n" to item["_n"], "q" to item.filterKeys { it != "_n" }))).append('\n')
        }
        FileOutputStream(tmp).use { o ->
            o.write(b.toString().toByteArray(Charsets.UTF_8))
            o.fd.sync()
        }
        if (!tmp.renameTo(file)) {
            // Windows can't rename over an existing file.
            file.delete()
            if (!tmp.renameTo(file)) throw java.io.IOException("Could not replace ${file.path}")
        }
    }
}
