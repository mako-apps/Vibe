package expo.modules.vibechatnative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.vibechatnative.notifications.VibeIncomingCallNotification
import expo.modules.vibechatnative.notifications.VibeNativeCallStore
import expo.modules.vibechatnative.notifications.VibeNativeCallUiBridge

class VibeNativeCallModule : Module() {
  init {
    VibeNativeCallUiBridge.attachModule(this)
  }

  override fun definition() = ModuleDefinition {
    Name("VibeNativeCall")

    Events("onCallUiEvent")

    Function("isSupported") {
      true
    }

    Function("supportsInAppUi") {
      true
    }

    Function("drainPendingEvents") {
      VibeNativeCallStore.drainEvents(appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function emptyList<Map<String, Any?>>())
    }

    Function("getPushTokens") {
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext
      val fcm = context?.let { VibeNativeCallStore.getFcmToken(it) }
      mapOf(
        "platform" to "android",
        "fcm" to fcm,
      )
    }

    Function("clearIncomingCallUi") { payload: Map<String, Any?> ->
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function
      val callId = (payload["callId"] ?: payload["call_id"])?.toString()
      VibeIncomingCallNotification.cancelIncomingCall(context, callId)
    }

    Function("setCallUiState") { payload: Map<String, Any?> ->
      val context = appContext.reactContext ?: appContext.currentActivity?.applicationContext ?: return@Function
      VibeNativeCallUiBridge.setState(payload)
      val visible = (payload["visible"] as? Boolean)
        ?: (((payload["mode"] as? String) ?: "hidden") != "hidden")
      if (visible) {
        VibeNativeCallUiBridge.present(context)
      } else {
        VibeNativeCallUiBridge.hide()
      }
    }

    Function("hideCallUi") {
      VibeNativeCallUiBridge.hide()
    }

    OnDestroy {
      VibeNativeCallUiBridge.detachModule(this@VibeNativeCallModule)
    }
  }

  internal fun emitCallUiEvent(payload: Map<String, Any?>) {
    try {
      sendEvent("onCallUiEvent", payload)
    } catch (_: Throwable) {
    }
  }
}
