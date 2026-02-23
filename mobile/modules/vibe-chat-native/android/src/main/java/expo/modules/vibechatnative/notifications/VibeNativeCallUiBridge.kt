package expo.modules.vibechatnative.notifications

import android.content.Context
import android.content.Intent
import java.lang.ref.WeakReference

internal object VibeNativeCallUiBridge {
  private var moduleRef: WeakReference<expo.modules.vibechatnative.VibeNativeCallModule>? = null
  private var activityRef: WeakReference<VibeNativeCallUiActivity>? = null
  @Volatile private var state: Map<String, Any?> = emptyMap()

  fun attachModule(module: expo.modules.vibechatnative.VibeNativeCallModule) {
    moduleRef = WeakReference(module)
  }

  fun detachModule(module: expo.modules.vibechatnative.VibeNativeCallModule) {
    if (moduleRef?.get() === module) {
      moduleRef = null
    }
  }

  fun attachActivity(activity: VibeNativeCallUiActivity) {
    activityRef = WeakReference(activity)
    activity.applyUiState(state)
  }

  fun detachActivity(activity: VibeNativeCallUiActivity) {
    if (activityRef?.get() === activity) {
      activityRef = null
    }
  }

  fun setState(next: Map<String, Any?>) {
    state = next
    activityRef?.get()?.applyUiState(next)
  }

  fun getState(): Map<String, Any?> = state

  fun present(context: Context) {
    val activity = activityRef?.get()
    if (activity != null && !activity.isFinishing) {
      activity.applyUiState(state)
      return
    }
    val intent = Intent(context, VibeNativeCallUiActivity::class.java).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }
    try {
      context.startActivity(intent)
    } catch (_: Throwable) {
      // Activity launches can be denied when the app is backgrounded.
      // Closed/background call surfaces are handled by OS-native call UI paths.
    }
  }

  fun hide() {
    activityRef?.get()?.finish()
  }

  fun emitUiEvent(type: String, payload: Map<String, Any?> = emptyMap()) {
    val body = LinkedHashMap<String, Any?>()
    body["type"] = type
    for ((key, value) in payload) {
      body[key] = value
    }
    moduleRef?.get()?.emitCallUiEvent(body)
  }
}
