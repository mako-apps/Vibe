package com.mohammadshayani.vibe.chat

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.mohammadshayani.vibe.home.ChatHomeListRow
import com.mohammadshayani.vibe.home.parseChatHomeRows
import com.mohammadshayani.vibe.packet.PacketBootstrapService
import com.mohammadshayani.vibe.packet.PacketRuntime
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.session.AppSessionConfig
import com.mohammadshayani.vibe.storage.SecureKeyStore
import com.mohammadshayani.vibe.ui.NativeAuthService
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

object ChatEngineApi {
  private const val CACHE_PREFS = "vibe_android_chat_home_cache"
  private const val CACHE_CHATS = "chats_payload_v1"

  private open class FatalRequestException(message: String) : IOException(message)
  private class SessionExpiredException(message: String) : FatalRequestException(message)

  private val httpClient by lazy {
    OkHttpClient.Builder()
      .connectTimeout(15, TimeUnit.SECONDS)
      .readTimeout(20, TimeUnit.SECONDS)
      .writeTimeout(20, TimeUnit.SECONDS)
      .callTimeout(22, TimeUnit.SECONDS)
      .build()
  }
  private val mainHandler = Handler(Looper.getMainLooper())

  internal data class PeerLookupResult(
    val userId: String,
    val displayName: String,
    val username: String?,
    val phoneNumber: String?,
    val avatarUri: String?,
    val publicKey: String?,
    val isOnline: Boolean,
  ) {
    val subtitle: String
      get() {
        if (!phoneNumber.isNullOrBlank()) return phoneNumber
        val handle = username?.trim()?.removePrefix("@").orEmpty()
        if (handle.isNotEmpty() && !looksLikeUuid(handle) && !handle.equals(displayName, ignoreCase = true)) {
          return "@$handle"
        }
        return "User is in Vibegram"
      }
  }

  internal fun fetchChats(context: Context, callback: (Result<List<ChatHomeListRow>>) -> Unit) {
    val config = AppSessionConfig.current(context)
    if (config == null) {
      callback(Result.failure(IllegalStateException("Missing native auth config.")))
      return
    }

    Thread {
      val result = runCatching {
        withSessionRefresh(context, config) { activeConfig ->
          val request = buildRequest(activeConfig)
          executeWithTransport(context, activeConfig) { client ->
            execute(client, request, context)
          }
        }
      }
      val resolvedResult =
        if (result.isFailure) {
          cachedRows(context)?.let { Result.success(it) } ?: result
        } else {
          result
        }
      mainHandler.post { callback(resolvedResult) }
    }.start()
  }

  internal fun startDirectChat(
    context: Context,
    lookup: String,
    callback: (Result<ChatHomeListRow>) -> Unit,
  ) {
    findUser(context, lookup) { result ->
      result.onSuccess { peer ->
        startDirectChat(context, peer, callback)
      }.onFailure { error ->
        callback(Result.failure(error))
      }
    }
  }

  internal fun findUser(
    context: Context,
    lookup: String,
    callback: (Result<PeerLookupResult>) -> Unit,
  ) {
    val config = AppSessionConfig.current(context)
    if (config == null) {
      callback(Result.failure(IllegalStateException("Missing native auth config.")))
      return
    }
    val normalizedLookup = lookup.trim().removePrefix("@")
    if (normalizedLookup.isBlank()) {
      callback(Result.failure(IllegalArgumentException("Enter a username, phone, or user id.")))
      return
    }

    Thread {
      val result = runCatching {
        withSessionRefresh(context, config) { activeConfig ->
          executeWithTransport(context, activeConfig) { client ->
            resolvePeer(client, activeConfig, normalizedLookup)
          }
        }
      }
      mainHandler.post { callback(result) }
    }.start()
  }

  internal fun startDirectChat(
    context: Context,
    peer: PeerLookupResult,
    callback: (Result<ChatHomeListRow>) -> Unit,
  ) {
    val config = AppSessionConfig.current(context)
    if (config == null) {
      callback(Result.failure(IllegalStateException("Missing native auth config.")))
      return
    }

    Thread {
      val result = runCatching {
        withSessionRefresh(context, config) { activeConfig ->
          val executor: (OkHttpClient) -> ChatHomeListRow = { client ->
            val chatId = createDirectChat(client, activeConfig, peer.userId)
            ChatEngine.seedChatPeerInfo(
              mapOf(
                "chatId" to chatId,
                "peerUserId" to peer.userId,
                "publicKey" to peer.publicKey,
              ),
            )
            ChatHomeListRow(
              chatId = chatId,
              title = peer.displayName,
              preview = "Start a conversation",
              timeLabel = "",
              unreadCount = 0,
              markedUnread = false,
              muted = false,
              pinned = false,
              isTyping = false,
              isOnline = peer.isOnline,
              peerUserId = peer.userId,
              avatarUri = peer.avatarUri,
              avatarFallback = peer.displayName.take(1).uppercase().ifBlank { "?" },
              avatarGradientStartLight = null,
              avatarGradientEndLight = null,
              avatarGradientStartDark = null,
              avatarGradientEndDark = null,
              isSavedMessages = false,
            )
          }
          executeWithTransport(context, activeConfig, executor)
        }
      }
      mainHandler.post { callback(result) }
    }.start()
  }

  private fun <T> withSessionRefresh(
    context: Context,
    config: AppSessionConfig,
    operation: (AppSessionConfig) -> T,
  ): T {
    return try {
      operation(config)
    } catch (error: SessionExpiredException) {
      operation(refreshSession(context, error.message))
    }
  }

  private fun refreshSession(context: Context, fallbackMessage: String?): AppSessionConfig {
    val secret =
      SecureKeyStore.retrieveSecret(context.applicationContext, "loginSecret")
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: throw SessionExpiredException(fallbackMessage ?: "Session expired. Sign in again.")
    val result = NativeAuthService.signIn(context.applicationContext, secret)
    AppSessionConfig.store(context.applicationContext, result.config)
    SecureKeyStore.storeSecret(context.applicationContext, "loginSecret", secret)
    return result.config
  }

  private fun <T> executeWithTransport(
    context: Context,
    config: AppSessionConfig,
    operation: (OkHttpClient) -> T,
  ): T {
    return when (config.transportMode) {
      PacketTransportMode.OFFLINE ->
        throw IOException("Transport mode offline is not available in the standalone native app.")
      PacketTransportMode.BRIDGE_TEXT ->
        throw IOException("Transport mode bridge_text is not available in the standalone native app.")
      PacketTransportMode.PACKET_MESH -> {
        try {
          val snapshot = PacketRuntime.ensureStarted(context, config)
          operation(PacketRuntime.buildHttpClient(snapshot))
        } catch (error: SessionExpiredException) {
          throw error
        } catch (error: FatalRequestException) {
          throw error
        } catch (_: Throwable) {
          operation(httpClient)
        }
      }
      PacketTransportMode.DIRECT -> {
        try {
          val value = operation(httpClient)
          PacketRuntime.stop(context, resetToDirect = true)
          PacketBootstrapService.prefetchIfNeeded(context, config)
          value
        } catch (error: SessionExpiredException) {
          throw error
        } catch (error: FatalRequestException) {
          throw error
        } catch (_: Throwable) {
          val snapshot = PacketRuntime.ensureStarted(context, config)
          operation(PacketRuntime.buildHttpClient(snapshot))
        }
      }
    }
  }

  private fun buildRequest(config: AppSessionConfig): Request {
    val base = config.apiBaseUrl.trim().trimEnd('/')
    val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
    val url = "$pathBase/chats/${config.userId}"
    return Request.Builder()
      .url(url)
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
      .header("Authorization", "Bearer ${config.authToken}")
      .build()
  }

  private fun resolvePeer(
    client: OkHttpClient,
    config: AppSessionConfig,
    lookup: String,
  ): PeerLookupResult {
    val candidates = lookupCandidates(config, lookup)
    var lastFailure: IOException? = null
    for (request in candidates) {
      try {
        client.newCall(request).execute().use { response ->
          val body = response.body?.string().orEmpty()
          if (response.code == 401) {
            throw SessionExpiredException(serverErrorMessage(response.code, body, "Session expired. Sign in again."))
          }
          if (!response.isSuccessful) {
            lastFailure =
              FatalRequestException(
                if (response.code == 404) "User not found." else serverErrorMessage(response.code, body, "User lookup failed.")
              )
            return@use
          }
          if (!looksLikeJson(body)) {
            lastFailure = FatalRequestException("The server returned an invalid user lookup response.")
            return@use
          }
          val json = JSONObject(body)
          val source = json.optJSONObject("data") ?: json
          val userId = firstNonBlank(
            source.opt("userId"),
            source.opt("user_id"),
            source.opt("id"),
          )
          if (userId.isNullOrBlank()) {
            lastFailure = IOException("User lookup returned no user id.")
            return@use
          }
          val username = firstNonBlank(source.opt("username"), source.opt("handle"))
          val title = firstNonBlank(
            source.opt("displayName"),
            source.opt("display_name"),
            source.opt("fullName"),
            source.opt("full_name"),
            source.opt("name"),
            username,
          )?.takeUnless { looksLikeUuid(it) }
            ?: username?.takeUnless { looksLikeUuid(it) }
            ?: "Vibegram User"
          return PeerLookupResult(
            userId = userId,
            displayName = title,
            username = username,
            phoneNumber = firstNonBlank(source.opt("phoneNumber"), source.opt("phone_number"), source.opt("phone")),
            avatarUri = firstNonBlank(source.opt("profileImage"), source.opt("profile_image"), source.opt("avatarUrl"), source.opt("avatar_url")),
            publicKey = firstNonBlank(source.opt("publicKey"), source.opt("public_key"), source.opt("friendKey"), source.opt("friendPublicKey")),
            isOnline = parseBool(source.opt("online") ?: source.opt("isOnline") ?: source.opt("is_online")) ?: false,
          )
        }
      } catch (error: SessionExpiredException) {
        throw error
      } catch (error: FatalRequestException) {
        throw error
      } catch (error: Throwable) {
        lastFailure = IOException(sanitizeClientError(error.message, "User lookup failed."), error)
      }
    }
    throw lastFailure ?: IOException("User not found.")
  }

  private fun createDirectChat(
    client: OkHttpClient,
    config: AppSessionConfig,
    peerUserId: String,
  ): String {
    val base = config.apiBaseUrl.trim().trimEnd('/')
    val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
    val body =
      JSONObject()
        .put("myId", config.userId)
        .put("friendId", peerUserId)
        .toString()
        .toRequestBody("application/json; charset=utf-8".toMediaType())
    val request =
      Request.Builder()
        .url("$pathBase/chat")
        .post(body)
        .header("Accept", "application/json")
        .header("ngrok-skip-browser-warning", "true")
        .header("Authorization", "Bearer ${config.authToken}")
        .build()
    client.newCall(request).execute().use { response ->
      val payload = response.body?.string().orEmpty()
      if (response.code == 401) {
        throw SessionExpiredException(serverErrorMessage(response.code, payload, "Session expired. Sign in again."))
      }
      if (!response.isSuccessful) {
        throw FatalRequestException(serverErrorMessage(response.code, payload, "Chat create failed."))
      }
      val chatId = JSONObject(payload).optString("chatId").trim()
      if (chatId.isBlank()) throw IOException("Chat create returned no chat id.")
      return chatId
    }
  }

  private fun lookupCandidates(
    config: AppSessionConfig,
    lookup: String,
  ): List<Request> {
    val base = config.apiBaseUrl.trim().trimEnd('/')
    val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
    val encoded = URLEncoder.encode(lookup, StandardCharsets.UTF_8.name())
    val paths =
      when {
        lookup.startsWith("+") || lookup.any { it.isDigit() } && lookup.none { it.isLetter() } ->
          listOf("user/phone/$encoded", "user/$encoded")
        else ->
          listOf("user/name/$encoded", "user/$encoded")
      }
    return paths.map { path ->
      Request.Builder()
        .url("$pathBase/$path")
        .get()
        .header("Accept", "application/json")
        .header("ngrok-skip-browser-warning", "true")
        .header("Authorization", "Bearer ${config.authToken}")
        .build()
    }
  }

  private fun execute(
    client: OkHttpClient,
    request: Request,
    context: Context,
  ): List<ChatHomeListRow> {
    client.newCall(request).execute().use { response ->
      val body = response.body?.string().orEmpty()
      if (response.code == 401) {
        throw SessionExpiredException(serverErrorMessage(response.code, body, "Session expired. Sign in again."))
      }
      if (!response.isSuccessful) {
        throw FatalRequestException(serverErrorMessage(response.code, body, "Request failed."))
      }
      cachePayload(context, body)
      return parseChatHomeRows(parsePayload(body), context)
    }
  }

  private fun serverErrorMessage(statusCode: Int, body: String, fallback: String): String {
    val serverMessage =
      runCatching {
        val json = JSONObject(body)
        firstNonBlank(json.opt("message"), json.opt("error"), json.opt("reason"))
      }.getOrNull()
    if (!serverMessage.isNullOrBlank()) {
      return if (statusCode == 401) serverMessage else "$fallback ($statusCode): $serverMessage"
    }
    val sanitized = sanitizeClientError(body, "")
    return if (sanitized.isBlank()) "$fallback ($statusCode)." else "$fallback ($statusCode): $sanitized"
  }

  private fun sanitizeClientError(raw: String?, fallback: String): String {
    val trimmed = raw?.trim().orEmpty()
    if (trimmed.isBlank()) return fallback
    val lower = trimmed.lowercase()
    if (lower.startsWith("<!doctype") || lower.startsWith("<html") || "<body" in lower) {
      return fallback
    }
    return trimmed.take(160)
  }

  private fun looksLikeJson(body: String): Boolean {
    val trimmed = body.trimStart()
    return trimmed.startsWith("{") || trimmed.startsWith("[")
  }

  private fun cachePayload(context: Context, body: String) {
    if (body.isBlank()) return
    context.getSharedPreferences(CACHE_PREFS, Context.MODE_PRIVATE)
      .edit()
      .putString(CACHE_CHATS, body)
      .apply()
  }

  internal fun cachedRows(context: Context): List<ChatHomeListRow>? {
    val body =
      context.getSharedPreferences(CACHE_PREFS, Context.MODE_PRIVATE)
        .getString(CACHE_CHATS, null)
        ?: return null
    return runCatching { parseChatHomeRows(parsePayload(body), context) }
      .getOrNull()
      ?.takeIf { it.isNotEmpty() }
  }

  private fun parsePayload(body: String): List<Map<String, Any?>> {
    val trimmed = body.trim()
    if (trimmed.startsWith("{")) {
      val obj = JSONObject(trimmed)
      val nested = obj.optJSONArray("chats") ?: obj.optJSONArray("data") ?: JSONArray()
      return parseArray(nested)
    }
    return parseArray(JSONArray(trimmed))
  }

  private fun parseArray(array: JSONArray): List<Map<String, Any?>> {
    val items = ArrayList<Map<String, Any?>>(array.length())
    for (index in 0 until array.length()) {
      val item = array.opt(index)
      if (item is JSONObject) {
        items.add(jsonObjectToMap(item))
      }
    }
    return items
  }

  private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
    val map = linkedMapOf<String, Any?>()
    val keys = json.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      map[key] = jsonValueToAny(json.opt(key))
    }
    return map
  }

  private fun jsonArrayToList(json: JSONArray): List<Any?> {
    val list = ArrayList<Any?>(json.length())
    for (index in 0 until json.length()) {
      list.add(jsonValueToAny(json.opt(index)))
    }
    return list
  }

  private fun jsonValueToAny(value: Any?): Any? {
    return when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> jsonObjectToMap(value)
      is JSONArray -> jsonArrayToList(value)
      else -> value
    }
  }

  private fun firstNonBlank(vararg values: Any?): String? {
    return values.firstNotNullOfOrNull { value ->
      when (value) {
        null, JSONObject.NULL -> null
        is String -> value.trim().takeIf { it.isNotEmpty() }
        else -> value.toString().trim().takeIf { it.isNotEmpty() }
      }
    }
  }

  private fun parseBool(value: Any?): Boolean? {
    return when (value) {
      is Boolean -> value
      is Number -> value.toInt() != 0
      is String -> when (value.trim().lowercase()) {
        "1", "true", "yes", "on" -> true
        "0", "false", "no", "off" -> false
        else -> null
      }
      else -> null
    }
  }

  private fun looksLikeUuid(value: String): Boolean {
    val trimmed = value.trim()
    if (trimmed.length != 36) return false
    return runCatching { java.util.UUID.fromString(trimmed) }.isSuccess
  }
}
