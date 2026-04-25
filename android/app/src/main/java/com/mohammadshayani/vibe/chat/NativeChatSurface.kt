package com.mohammadshayani.vibe.chat

import android.app.Activity
import android.content.Context
import android.widget.LinearLayout
import kotlin.reflect.KProperty

class NativeChatContext(
  val currentActivity: Activity? = null,
)

internal interface NativeChatEventHost {
  fun dispatchNativeChatEvent(name: String, payload: Any?)
}

open class NativeChatView(
  context: Context,
  val appContext: NativeChatContext,
) : LinearLayout(context), NativeChatEventHost {
  open val shouldUseAndroidLayout: Boolean = false
  var nativeEventSink: ((Map<String, Any>) -> Unit)? = null
  var viewportEventSink: ((Map<String, Any>) -> Unit)? = null

  override fun dispatchNativeChatEvent(name: String, payload: Any?) {
    @Suppress("UNCHECKED_CAST")
    val mapPayload = payload as? Map<String, Any> ?: return
    when (name) {
      "onViewportChanged" -> viewportEventSink?.invoke(mapPayload)
      else -> nativeEventSink?.invoke(mapPayload)
    }
  }
}

class NativeEventDispatcher<T> {
  operator fun getValue(thisRef: Any?, property: KProperty<*>): (T) -> Unit {
    return { value ->
      (thisRef as? NativeChatEventHost)?.dispatchNativeChatEvent(property.name, value)
    }
  }
}
