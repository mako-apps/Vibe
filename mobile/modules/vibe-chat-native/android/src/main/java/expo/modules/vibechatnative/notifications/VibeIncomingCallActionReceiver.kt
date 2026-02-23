package expo.modules.vibechatnative.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class VibeIncomingCallActionReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val action = intent.getStringExtra(VibeIncomingCallNotification.EXTRA_ACTION)?.trim().orEmpty()
    if (action.isEmpty()) return

    val payload = linkedMapOf<String, String>()
    intent.extras?.keySet()?.forEach { key ->
      val value = intent.extras?.get(key)?.toString() ?: return@forEach
      payload[key] = value
    }

    val callId = payload["callId"] ?: payload["call_id"]
    VibeIncomingCallNotification.cancelIncomingCall(context, callId)
    VibeNativeCallStore.enqueueAction(context, action, payload)

    if (action == VibeIncomingCallNotification.ACTION_ANSWER) {
      try {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        launchIntent?.putExtra("vibeNativeCallAction", action)
        payload.forEach { (key, value) -> launchIntent?.putExtra(key, value) }
        if (launchIntent != null) {
          context.startActivity(launchIntent)
        }
      } catch (t: Throwable) {
        Log.w("VibeIncomingCall", "Failed to launch app for answer action ${t.message}", t)
      }
    }
  }

  companion object {
    fun intent(context: Context, action: String, payload: Map<String, String>): Intent {
      return Intent(context, VibeIncomingCallActionReceiver::class.java).apply {
        putExtra(VibeIncomingCallNotification.EXTRA_ACTION, action)
        payload.forEach { (key, value) -> putExtra(key, value) }
      }
    }
  }
}

