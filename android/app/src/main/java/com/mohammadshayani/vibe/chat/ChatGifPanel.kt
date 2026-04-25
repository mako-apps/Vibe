package com.mohammadshayani.vibe.chat

import android.content.Context
import android.widget.Toast
import androidx.fragment.app.FragmentActivity

data class ChatGifSelection(
  val id: String,
  val url: String,
  val previewUrl: String,
  val width: Int,
  val height: Int,
)

object ChatGifPanelConfig {
  @Volatile
  private var storedApiKey: String = ""

  val apiKey: String
    get() = storedApiKey

  fun setApiKey(nextValue: String) {
    val trimmed = nextValue.trim()
    if (trimmed.isNotEmpty()) {
      storedApiKey = trimmed
    }
  }
}

class ChatGifPanel(
  private val context: Context,
  private val onGifSelected: (ChatGifSelection) -> Unit,
  private val onClosed: () -> Unit,
) {
  fun setApiKey(nextValue: String) {
    ChatGifPanelConfig.setApiKey(nextValue)
  }

  fun show(activity: FragmentActivity, keyboardHeightPx: Int?) {
    val apiKey = ChatGifPanelConfig.apiKey.trim()
    if (apiKey.isEmpty()) {
      Toast.makeText(context, "GIF search is unavailable", Toast.LENGTH_SHORT).show()
      onClosed()
      return
    }
    Toast.makeText(activity, "GIF search is not bundled in this native build", Toast.LENGTH_SHORT).show()
    onClosed()
  }

  fun dismiss() {
    onClosed()
  }
}
