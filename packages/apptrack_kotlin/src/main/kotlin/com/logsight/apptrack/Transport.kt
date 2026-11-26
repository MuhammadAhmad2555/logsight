package com.logsight.apptrack

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** Status code and body of an HTTP response. */
class HttpResponse(val statusCode: Int, val body: String)

/**
 * Sends one JSON POST. The default is [UrlConnectionTransport]; pass your
 * own (e.g. backed by OkHttp, or a fake in tests) to [AppTrackLogger].
 * Throw an [IOException] (or any exception) on network failure; the logger
 * treats it like a 5xx and retries with backoff.
 */
fun interface HttpTransport {
    @Throws(IOException::class)
    fun post(url: String, jsonBody: String): HttpResponse
}

/** [HttpTransport] on `java.net.HttpURLConnection` (no dependencies). */
class UrlConnectionTransport @JvmOverloads constructor(
    private val connectTimeoutMs: Int = 20_000,
    private val readTimeoutMs: Int = 20_000,
) : HttpTransport {
    @Suppress("DEPRECATION") // URL(String): its replacement needs Java 20+.
    override fun post(url: String, jsonBody: String): HttpResponse {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.doOutput = true
            c.useCaches = false
            c.connectTimeout = connectTimeoutMs
            c.readTimeout = readTimeoutMs
            c.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            val bytes = jsonBody.toByteArray(Charsets.UTF_8)
            c.setFixedLengthStreamingMode(bytes.size)
            c.outputStream.use { it.write(bytes) }
            val code = c.responseCode
            val stream = if (code >= 400) c.errorStream else c.inputStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            return HttpResponse(code, text)
        } catch (e: IOException) {
            c.disconnect()
            throw e
        }
    }
}
