package com.mohammadshayani.vibe.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.mohammadshayani.vibe.chat.ChatEngine
import com.mohammadshayani.vibe.chat.ChatMainView
import com.mohammadshayani.vibe.chat.ChatProfileMainView
import com.mohammadshayani.vibe.chat.NativeCallEngine
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
  private lateinit var rootContainer: FrameLayout
  private var profileView: ChatProfileMainView? = null
  private var chatId = ""
  private var conversationTitle = ""
  private var peerUserId = ""
  private var currentConfig: AppSessionConfig? = null
  private var isSavedMessages = false
  private var savedMessageIds: List<String> = emptyList()
  private var currentRows: List<Map<String, Any?>> = emptyList()
  private var pendingCallPermissionType: String? = null
  private var isProfileVisible = false
  private val engineListenerId = "conversation-${System.identityHashCode(this)}"
  @Volatile private var profileRowsRefreshInFlight = false

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
    conversationTitle = title
    peerUserId = intent.getStringExtra(extraPeerUserId).orEmpty()
    currentConfig = config

    ChatEngine.configure(applicationContext, config.toPayload())
    NativeCallEngine.configure(applicationContext, config.toPayload())

    val nativeContext = NativeChatContext(this)
    chatView = ChatMainView(this, nativeContext).apply {
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
          "headerBack" -> if (isProfileVisible) hideProfileView() else finish()
          "headerAvatarPressed" -> showProfileView()
          "headerAudioCallPressed" -> startNativeCall("voice")
          "headerVideoCallPressed" -> startNativeCall("video")
          "savedMessageSent" -> if (isSavedMessages) loadSavedMessages(config.userId)
          "savedMessagesClearRequested" -> if (isSavedMessages) confirmClearSavedMessages(config.userId)
        }
      }
    }

    rootContainer = FrameLayout(this).apply {
      addView(
        chatView,
        FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.MATCH_PARENT,
          FrameLayout.LayoutParams.MATCH_PARENT,
        ),
      )
    }

    setContentView(rootContainer)
    ViewCompat.setOnApplyWindowInsetsListener(rootContainer) { view, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
      view.setPadding(0, 0, 0, bars.bottom)
      insets
    }

    if (isSavedMessages) {
      loadCachedSavedMessages(config.userId)
      loadSavedMessages(config.userId)
    } else {
      ChatEngine.setListener(engineListenerId) { _, changedChatId, _ ->
        val changed = changedChatId?.trim().orEmpty()
        if (changed.isBlank() || changed == chatId) {
          refreshNormalChatRowsForProfile()
        }
      }
      ChatEngine.openChatChannel(mapOf("chatId" to chatId))
      refreshNormalChatRowsForProfile()
    }
  }

  override fun onDestroy() {
    ChatEngine.setListener(engineListenerId, null)
    super.onDestroy()
  }

  private fun ChatProfileMainView.configureProfileSurface(
    config: AppSessionConfig,
    rows: List<Map<String, Any?>>,
  ) {
    setProfileOnly(true)
    setSurfaceId("standalone-profile-$chatId")
    setEngineSurfaceId("standalone-profile-engine-$chatId")
    setEngineChatId(chatId)
    setEngineMyUserId(config.userId)
    setEnginePeerUserId(peerUserId)
    setAppearance(buildNativeThemeSeed(this@ConversationActivity))
    setHeaderTitle(conversationTitle)
    setHeaderSubtitle(if (isSavedMessages) "Saved Messages" else peerUserId)
    setProfileName(conversationTitle)
    setProfileHandle(if (isSavedMessages) "Personal notes and media" else peerUserId)
    setProfileBio("")
    setIsGroupOrChannel(false)
    setRows(rows)
  }

  private fun makeProfileView(config: AppSessionConfig): ChatProfileMainView {
    profileView?.let { return it }

    val nextProfileView = ChatProfileMainView(this, NativeChatContext(this)).apply {
      configureProfileSurface(config, rows = currentRows)
      visibility = View.GONE
      alpha = 0f
      nativeEventSink = { payload ->
        when (payload["type"]) {
          "headerBack" -> hideProfileView()
          "headerAudioCallPressed" -> startNativeCall("voice")
          "headerVideoCallPressed" -> startNativeCall("video")
          "headerSearchPressed" -> {
            hideProfileView()
            chatView.openHeaderSearch()
          }
          "profileSharedItemPressed" -> {
            val messageId = payload["messageId"]?.toString().orEmpty()
            hideProfileView()
            if (messageId.isNotBlank()) {
              chatView.scrollToMessage(messageId, true, 0.5)
            }
          }
          else -> Unit
        }
      }
    }
    rootContainer.addView(
      nextProfileView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )
    profileView = nextProfileView
    return nextProfileView
  }

  private fun showProfileView() {
    if (isProfileVisible) return
    val config = currentConfig ?: AppSessionConfig.current(applicationContext) ?: return
    val profileView = makeProfileView(config)
    profileView.configureProfileSurface(config, rows = currentRows)
    if (!isSavedMessages) {
      refreshNormalChatRowsForProfile()
    }
    isProfileVisible = true
    profileView.animate().cancel()
    chatView.animate().cancel()
    profileView.bringToFront()
    profileView.visibility = View.VISIBLE
    profileView.alpha = 1f
    val width = rootContainer.width.takeIf { it > 0 } ?: resources.displayMetrics.widthPixels
    profileView.translationX = width.toFloat()
    profileView.animate()
      .translationX(0f)
      .setDuration(260L)
      .start()
  }

  private fun hideProfileView() {
    if (!isProfileVisible) return
    val profileView = profileView ?: run {
      isProfileVisible = false
      return
    }
    isProfileVisible = false
    profileView.animate().cancel()
    chatView.animate().cancel()
    val width = rootContainer.width.takeIf { it > 0 } ?: resources.displayMetrics.widthPixels
    profileView.animate()
      .translationX(width.toFloat())
      .alpha(0.96f)
      .setDuration(220L)
      .withEndAction {
        profileView.translationX = 0f
        profileView.alpha = 0f
        profileView.visibility = View.GONE
        rootContainer.removeView(profileView)
        if (this.profileView === profileView) {
          this.profileView = null
        }
      }
      .start()
  }

  private fun startNativeCall(callType: String) {
    val targetUserId = peerUserId.trim()
    if (isSavedMessages || targetUserId.isBlank()) {
      Toast.makeText(this, "Calls are available in direct chats.", Toast.LENGTH_SHORT).show()
      return
    }
    val config = currentConfig ?: AppSessionConfig.current(applicationContext)
    if (config == null) {
      Toast.makeText(this, "The current session is unavailable.", Toast.LENGTH_SHORT).show()
      return
    }
    if (!hasCallPermissions(callType)) {
      requestCallPermissions(callType)
      return
    }

    NativeCallEngine.configure(applicationContext, config.toPayload())
    val now = System.currentTimeMillis()
    val payload = mapOf(
      "event" to "call-start",
      "callId" to "call_${now}_${java.util.UUID.randomUUID().toString().take(8)}",
      "callType" to if (callType == "video") "video" else "voice",
      "toUserId" to targetUserId,
      "toUserName" to conversationTitle,
      "chatId" to chatId,
    )
    val result = NativeCallEngine.startOutgoing(payload)
    NativeCallActivity.startOutgoing(this, payload, result)
    val accepted = result["signalingAccepted"] as? Boolean ?: true
    if (!accepted) {
      Toast.makeText(this, "Could not start call.", Toast.LENGTH_SHORT).show()
    }
  }

  private fun refreshNormalChatRowsForProfile() {
    if (isSavedMessages || profileRowsRefreshInFlight) return
    profileRowsRefreshInFlight = true
    Thread {
      val rows = ChatEngine.getChatRows(mapOf("chatId" to chatId))
      runOnUiThread {
        profileRowsRefreshInFlight = false
        if (rows.isNotEmpty()) {
          currentRows = rows
          profileView?.setRows(rows)
        }
      }
    }.start()
  }

  private fun hasCallPermissions(callType: String): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
    val needsCamera = callType == "video"
    val audioGranted = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    val cameraGranted = !needsCamera || checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    return audioGranted && cameraGranted
  }

  private fun requestCallPermissions(callType: String) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    pendingCallPermissionType = if (callType == "video") "video" else "voice"
    val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
    if (callType == "video") permissions += Manifest.permission.CAMERA
    requestPermissions(permissions.toTypedArray(), if (callType == "video") 4202 else 4201)
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode != 4201 && requestCode != 4202) return
    val callType = pendingCallPermissionType ?: if (requestCode == 4202) "video" else "voice"
    pendingCallPermissionType = null
    if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
      startNativeCall(callType)
    } else {
      Toast.makeText(this, "Microphone permission is needed for calls.", Toast.LENGTH_SHORT).show()
    }
  }

  private fun loadCachedSavedMessages(userId: String) {
    val rows = cachedSavedRows(userId) ?: return
    currentRows = rows
    savedMessageIds = rows.mapNotNull { savedMessageIdFromRow(it) }
    chatView.setRows(rows)
    profileView?.setRows(rows)
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
        currentRows = rows
        savedMessageIds = rows.mapNotNull { savedMessageIdFromRow(it) }
        chatView.setRows(rows)
        profileView?.setRows(rows)
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
    currentRows = emptyList()
    chatView.setRows(emptyList())
    profileView?.setRows(emptyList())
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
