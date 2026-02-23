package expo.modules.vibechatnative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.vibechatnative.notifications.VibeIncomingCallNotification
import expo.modules.vibechatnative.notifications.VibeNativeCallStore

class VibeNativeCallModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("VibeNativeCall")

    Function("isSupported") {
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
  }
}

