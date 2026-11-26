package com.logsight.apptrack

/**
 * Minimal JSON encoder/decoder (no third-party dependencies).
 *
 * Encodes: null, Boolean, String, Number (Byte/Short/Int/Long as integers,
 * Float/Double as decimals; non-finite as strings), Map (keys via toString),
 * Iterable / Array. Anything else is written as its toString().
 *
 * Decodes objects to [LinkedHashMap], arrays to [ArrayList], integers to
 * [Long] (or [Double] if out of range), decimals to [Double].
 */
internal object Json {
    fun encode(value: Any?): String = StringBuilder().also { write(it, value) }.toString()

    fun decode(text: String): Any? {
        val p = Parser(text)
        p.ws()
        val v = p.value()
        p.ws()
        if (p.i != text.length) throw IllegalArgumentException("Trailing data at ${p.i}")
        return v
    }

    private fun write(b: StringBuilder, v: Any?) {
        when (v) {
            null -> b.append("null")
            is Boolean -> b.append(if (v) "true" else "false")
            is String -> string(b, v)
            is Byte, is Short, is Int, is Long -> b.append(v.toString())
            is Double -> if (v.isNaN() || v.isInfinite()) string(b, v.toString()) else b.append(v.toString())
            is Float -> write(b, v.toDouble())
            is Map<*, *> -> {
                b.append('{')
                var first = true
                for ((k, e) in v) {
                    if (!first) b.append(',')
                    first = false
                    string(b, k.toString())
                    b.append(':')
                    write(b, e)
                }
                b.append('}')
            }
            is Iterable<*> -> {
                b.append('[')
                var first = true
                for (e in v) {
                    if (!first) b.append(',')
                    first = false
                    write(b, e)
                }
                b.append(']')
            }
            is Array<*> -> write(b, v.asList())
            else -> string(b, v.toString())
        }
    }

    private fun string(b: StringBuilder, s: String) {
        b.append('"')
        for (c in s) {
            when (c) {
                '"' -> b.append("\\\"")
                '\\' -> b.append("\\\\")
                '\n' -> b.append("\\n")
                '\r' -> b.append("\\r")
                '\t' -> b.append("\\t")
                '\b' -> b.append("\\b")
                '\u000C' -> b.append("\\f")
                ' ' -> b.append("\\u2028")
                ' ' -> b.append("\\u2029")
                else -> if (c < ' ') {
                    b.append("\\u").append(String.format(java.util.Locale.ROOT, "%04x", c.code))
                } else {
                    b.append(c)
                }
            }
        }
        b.append('"')
    }

    private class Parser(val s: String) {
        var i = 0

        fun ws() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) i++
        }

        private fun fail(msg: String): Nothing = throw IllegalArgumentException("$msg at $i")

        fun value(): Any? {
            if (i >= s.length) fail("Unexpected end")
            return when (val c = s[i]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> lit("true", true)
                'f' -> lit("false", false)
                'n' -> lit("null", null)
                else -> if (c == '-' || c in '0'..'9') num() else fail("Unexpected '$c'")
            }
        }

        private fun lit(word: String, v: Any?): Any? {
            if (!s.startsWith(word, i)) fail("Bad literal")
            i += word.length
            return v
        }

        private fun obj(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            i++
            ws()
            if (i < s.length && s[i] == '}') { i++; return m }
            while (true) {
                ws()
                if (i >= s.length || s[i] != '"') fail("Expected key")
                val k = str()
                ws()
                if (i >= s.length || s[i] != ':') fail("Expected ':'")
                i++
                ws()
                m[k] = value()
                ws()
                if (i >= s.length) fail("Unexpected end")
                when (s[i]) {
                    ',' -> i++
                    '}' -> { i++; return m }
                    else -> fail("Expected ',' or '}'")
                }
            }
        }

        private fun arr(): List<Any?> {
            val l = ArrayList<Any?>()
            i++
            ws()
            if (i < s.length && s[i] == ']') { i++; return l }
            while (true) {
                ws()
                l.add(value())
                ws()
                if (i >= s.length) fail("Unexpected end")
                when (s[i]) {
                    ',' -> i++
                    ']' -> { i++; return l }
                    else -> fail("Expected ',' or ']'")
                }
            }
        }

        private fun str(): String {
            i++ // opening quote
            val b = StringBuilder()
            while (true) {
                if (i >= s.length) fail("Unterminated string")
                val c = s[i++]
                when {
                    c == '"' -> return b.toString()
                    c == '\\' -> {
                        if (i >= s.length) fail("Bad escape")
                        when (val e = s[i++]) {
                            '"' -> b.append('"')
                            '\\' -> b.append('\\')
                            '/' -> b.append('/')
                            'b' -> b.append('\b')
                            'f' -> b.append('\u000C')
                            'n' -> b.append('\n')
                            'r' -> b.append('\r')
                            't' -> b.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) fail("Bad unicode escape")
                                b.append(s.substring(i, i + 4).toInt(16).toChar())
                                i += 4
                            }
                            else -> fail("Bad escape '$e'")
                        }
                    }
                    c < ' ' -> fail("Control character in string")
                    else -> b.append(c)
                }
            }
        }

        private fun num(): Any {
            val start = i
            if (s[i] == '-') i++
            var decimal = false
            while (i < s.length) {
                val c = s[i]
                if (c in '0'..'9' || c == '+' || c == '-') {
                    i++
                } else if (c == '.' || c == 'e' || c == 'E') {
                    decimal = true
                    i++
                } else {
                    break
                }
            }
            val t = s.substring(start, i)
            if (t == "-" || t.isEmpty()) fail("Bad number")
            if (!decimal) t.toLongOrNull()?.let { return it }
            return t.toDoubleOrNull() ?: fail("Bad number '$t'")
        }
    }
}
