package com.mohammadshayani.vibe.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.mohammadshayani.vibe.chat.ChatEngine
import com.mohammadshayani.vibe.chat.ChatMainView
import com.mohammadshayani.vibe.chat.NativeChatContext
import com.mohammadshayani.vibe.home.ChatHomeListRow
import com.mohammadshayani.vibe.session.AppSessionConfig
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

class ConversationActivity : AppCompatActivity() {
  companion object {
    private const val extraChatId = "chat_id"
    private const val extraTitle = "title"
    private const val extraPeerUserId = "peer_user_id"
    private const val extraIsSavedMessages = "is_saved_messages"
    private const val savedMessagesCachePrefs = "vibe_android_saved_messages_cache"

    internal fun intent(context: Context, row: ChatHomeListRow): Intent {
      return Intent(context, ConversationActivity::class.java).apply {
        putExtra(extraChatId, row.chatId)
        putExtra(extraTitle, row.title)
        putExtra(extraPeerUserId, row.peerUserId)
        putExtra(extraIsSavedMessages, row.isSavedMessages)
      }
    }

    fun savedMessagesIntent(context: Context): Intent {
      return Intent(context, ConversationActivity::class.java).apply {
        putExtra(extraChatId, "saved_messages")
        putExtra(extraTitle, "Saved Messages")
        putExtra(extraIsSavedMessages, true)
      }
    }
  }

  private lateinit var chatView: ChatMainView
  private var chatId = ""
  private var isSavedMessages = false
  private var savedMessageIds: List<String> = emptyList()

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)

    val palette = resolveAppThemePalette(this)
    applyThemedSystemBars(this, palette)

    val config = AppSessionConfig.current(applicationContext)
    if (config == null) {
      startActivity(Intent(this, WelcomeActivity::class.java))
      finish()
      return
    }

    chatId = intent.getStringExtra(extraChatId).orEmpty().ifBlank { "saved_messages" }
    isSavedMessages = intent.getBooleanExtra(extraIsSavedMessages, false) || chatId == "saved_messages"
    val title = intent.getStringExtra(extraTitle).orEmpty().ifBlank {
      if (isSavedMessages) "Saved Messages" else "Chat"
    }
    val peerUserId = intent.getStringExtra(extraPeerUserId).orEmpty()

    ChatEngine.configure(applicationContext, config.toPayload())

    chatView = ChatMainView(this, NativeChatContext(this)).apply {
      setSurfaceId("standalone-$chatId")
      setEngineSurfaceId("standalone-engine-$chatId")
      setEngineChatId(chatId)
      setEngineMyUserId(config.userId)
      setEnginePeerUserId(peerUserId)
      setAppearance(buildNativeThemeSeed(this@ConversationActivity))
      setHeaderMode(if (isSavedMessages) "saved_messages" else "default")
      setHeaderTitle(title)
      setHeaderSubtitle(if (isSavedMessages) "" else peerUserId)
      setProfileName(title)
      setInputPlaceholder(if (isSavedMessages) "Saved Message" else "Message")
      setInputBarEnabled(true)
      setNativeSendEnabled(true)
      setStatusAuthorityEnabled(true)
      setRows(emptyList())
      nativeEventSink = { payload ->
        when (payload["type"]) {
          "headerBack" -> finish()
          "savedMessageSent" -> if (isSavedMessages) loadSavedMessages(config.userId)
          "savedMessagesClearRequested" -> if (isSavedMessages) confirmClearSavedMessages(config.userId)
        }
      }
    }
    setContentView(chatView)
    ViewCompat.setOnApplyWindowInsetsListener(chatView) { view, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
      view.setPadding(0, 0, 0, bars.bottom)
      insets
    }

    if (isSavedMessages) {
      loadCachedSavedMessages(config.userId)
      loadSavedMessages(config.userId)
    } else {
      ChatEngine.openChatChannel(mapOf("chatId" to chatId))
    }
  }

  private fun loadCachedSavedMessages(userId: String) {
    val rows = cachedSavedRows(userId) ?: return
    savedMessageIds = rows.mapNotNull { savedMessageIdFromRow(it) }
    chatView.setRows(rows)
    Log.i("ConversationActivity", "loaded cached saved messages rows=${rows.size}")
  }

  private fun loadSavedMessages(userId: String) {
    Thread {
      val result = ChatEngine.fetchSavedMessages(mapOf("userId" to userId))
      @Suppress("UNCHECKED_CAST")
      val messages = result["messages"] as? List<Map<String, Any?>> ?: emptyList()
      val rows =
        messages
          .sortedBy { savedMessageTimestampMs(it) }
          .mapIndexed { index, message -> savedMessageRow(index, message, userId) }
      runOnUiThread {
        savedMessageIds = rows.mapNotNull { savedMessageIdFromRow(it) }
        chatView.setRows(rows)
        cacheSavedRows(userId, rows)
        Log.i("ConversationActivity", "loaded remote saved messages rows=${rows.size} success=${result["success"]}")
      }
    }.start()
  }

  private fun confirmClearSavedMessages(userId: String) {
    val ids = savedMessageIds
    if (ids.isEmpty()) return
    AlertDialog.Builder(this)
      .setTitle("Clear Saved Messages?")
      .setMessage("This removes all saved messages from this device and your account.")
      .setNegativeButton("Cancel", null)
      .setPositiveButton("Clear") { _, _ -> clearSavedMessages(userId, ids) }
      .show()
  }

  private fun clearSavedMessages(userId: String, ids: List<String>) {
    savedMessageIds = emptyList()
    chatView.setRows(emptyList())
    Thread {
      var successCount = 0
      ids.forEach { id ->
        val result = ChatEngine.deleteSavedMessage(mapOf("userId" to userId, "messageId" to id))
        if ((result["success"] as? Boolean) == true) successCount += 1
      }
      cacheSavedRows(userId, emptyList())
      Log.i("ConversationActivity", "clear saved messages requested=${ids.size} success=$successCount")
      loadSavedMessages(userId)
    }.start()
  }

  private fun savedMessageTimestampMs(message: Map<String, Any?>): Long {
    return (message["timestampMs"] as? Number)?.toLong()
      ?: (message["timestamp"] as? Number)?.toLong()
      ?: 0L
  }

  private fun savedMessageRow(
    index: Int,
    message: Map<String, Any?>,
    userId: String,
  ): Map<String, Any?> {
    val id = message["id"]?.toString()?.takeIf { it.isNotBlank() } ?: "saved-$index"
    val timestampMs = savedMessageTimestampMs(message).takeIf { it > 0L } ?: System.currentTimeMillis()
    val type = message["type"]?.toString()?.ifBlank { "text" } ?: "text"
    val fromId = message["fromId"]?.toString()
    val text = message["text"]?.toString()
      ?: message["plaintext"]?.toString()
      ?: message["content"]?.toString()
      ?: ""
    val rowMessage = linkedMapOf<String, Any?>(
      "id" to id,
      "text" to text,
      "timestamp" to DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(timestampMs)),
      "timestampMs" to timestampMs,
      "type" to type,
      "isMe" to (fromId.isNullOrBlank() || fromId == userId),
      "status" to (message["status"] ?: "sent"),
    )
    listOf(
      "mediaUrl",
      "localMediaUrl",
      "fileName",
      "mediaKey",
      "duration",
      "width",
      "height",
      "waveform",
      "isVideoNote",
      "stickerId",
      "stickerPackId",
      "packId",
      "stickerBundleFileName",
      "bundleFileName",
      "emoji",
    ).forEach { key ->
      message[key]?.let { rowMessage[key] = it }
    }
    return mapOf(
      "kind" to "message",
      "key" to id,
      "message" to rowMessage,
    )
  }

  private fun savedMessageIdFromRow(row: Map<String, Any?>): String? {
    val message = row["message"] as? Map<*, *> ?: return null
    return message["id"]?.toString()?.takeIf { it.isNotBlank() }
  }

  private fun cacheSavedRows(userId: String, rows: List<Map<String, Any?>>) {
    getSharedPreferences(savedMessagesCachePrefs, Context.MODE_PRIVATE)
      .edit()
      .putString(savedMessagesCacheKey(userId), JSONArray(rows.map { jsonValue(it) }).toString())
      .apply()
  }

  private fun cachedSavedRows(userId: String): List<Map<String, Any?>>? {
    val raw = getSharedPreferences(savedMessagesCachePrefs, Context.MODE_PRIVATE)
      .getString(savedMessagesCacheKey(userId), null)
      ?: return null
    return runCatching {
      jsonArrayToList(JSONArray(raw)).mapNotNull { it as? Map<String, Any?> }
    }.getOrNull()
  }

  private fun savedMessagesCacheKey(userId: String): String = "saved_rows_$userId"

  private fun jsonValue(value: Any?): Any {
    return when (value) {
      null -> JSONObject.NULL
      is Map<*, *> -> {
        val obj = JSONObject()
        value.forEach { (key, item) ->
          if (key != null) obj.put(key.toString(), jsonValue(item))
        }
        obj
      }
      is Iterable<*> -> JSONArray(value.map { jsonValue(it) })
      is Array<*> -> JSONArray(value.map { jsonValue(it) })
      is Number, is Boolean, is String -> value
      else -> value.toString()
    }
  }

  private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
    val map = linkedMapOf<String, Any?>()
    val keys = json.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      map[key] = jsonAny(json.opt(key))
    }
    return map
  }

  private fun jsonArrayToList(json: JSONArray): List<Any?> {
    val list = ArrayList<Any?>(json.length())
    for (index in 0 until json.length()) {
      list.add(jsonAny(json.opt(index)))
    }
    return list
  }

  private fun jsonAny(value: Any?): Any? {
    return when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> jsonObjectToMap(value)
      is JSONArray -> jsonArrayToList(value)
      else -> value
    }
  }
}
