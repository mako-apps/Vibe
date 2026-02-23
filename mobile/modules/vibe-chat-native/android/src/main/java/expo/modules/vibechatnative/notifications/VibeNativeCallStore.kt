package expo.modules.vibechatnative.notifications

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

private const val VIBE_CALL_STORE_PREFS = "vibe_native_call_store"
private const val KEY_PENDING_EVENTS = "pending_events"
private const val KEY_FCM_TOKEN = "fcm_token"

internal object VibeNativeCallStore {
  private fun prefs(context: Context) =
    context.applicationContext.getSharedPreferences(VIBE_CALL_STORE_PREFS, Context.MODE_PRIVATE)

  fun setFcmToken(context: Context, token: String?) {
    prefs(context).edit().putString(KEY_FCM_TOKEN, token?.trim().orEmpty()).apply()
  }

  fun getFcmToken(context: Context): String? {
    val value = prefs(context).getString(KEY_FCM_TOKEN, null)?.trim().orEmpty()
    return value.ifEmpty { null }
  }

  fun enqueueEvent(
    context: Context,
    eventType: String,
    payload: Map<String, String>,
  ) {
    try {
      val now = System.currentTimeMillis()
      val event = JSONObject().apply {
        put("type", eventType)
        put("timestamp", now)
        put("payload", JSONObject(payload))
      }
      val current = prefs(context).getString(KEY_PENDING_EVENTS, null)
      val array = if (current.isNullOrBlank()) JSONArray() else JSONArray(current)
      array.put(event)
      prefs(context).edit().putString(KEY_PENDING_EVENTS, array.toString()).apply()
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "enqueueEvent failed type=$eventType ${t.message}", t)
    }
  }

  fun enqueueIncomingCall(context: Context, payload: Map<String, String>) {
    enqueueEvent(context, "incomingCall", payload)
  }

  fun enqueueAction(
    context: Context,
    action: String,
    payload: Map<String, String>,
  ) {
    enqueueEvent(
      context,
      "callAction",
      payload + mapOf("action" to action),
    )
  }

  fun drainEvents(context: Context): List<Map<String, Any?>> {
    val raw = prefs(context).getString(KEY_PENDING_EVENTS, null)
    if (raw.isNullOrBlank()) return emptyList()
    return try {
      val array = JSONArray(raw)
      val results = ArrayList<Map<String, Any?>>(array.length())
      for (index in 0 until array.length()) {
        val item = array.optJSONObject(index) ?: continue
        results.add(jsonObjectToMap(item))
      }
      prefs(context).edit().remove(KEY_PENDING_EVENTS).apply()
      results
    } catch (t: Throwable) {
      Log.w("VibeCallStore", "drainEvents failed ${t.message}", t)
      emptyList()
    }
  }

  private fun jsonObjectToMap(value: JSONObject): Map<String, Any?> {
    val map = LinkedHashMap<String, Any?>()
    val keys = value.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      val raw = value.opt(key)
      map[key] =
        when (raw) {
          is JSONObject -> jsonObjectToMap(raw)
          is JSONArray -> jsonArrayToList(raw)
          JSONObject.NULL -> null
          else -> raw
        }
    }
    return map
  }

  private fun jsonArrayToList(value: JSONArray): List<Any?> {
    val list = ArrayList<Any?>(value.length())
    for (index in 0 until value.length()) {
      val raw = value.opt(index)
      list.add(
        when (raw) {
          is JSONObject -> jsonObjectToMap(raw)
          is JSONArray -> jsonArrayToList(raw)
          JSONObject.NULL -> null
          else -> raw
        }
      )
    }
    return list
  }
}

