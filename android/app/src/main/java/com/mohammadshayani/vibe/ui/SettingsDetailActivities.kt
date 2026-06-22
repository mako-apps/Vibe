package com.mohammadshayani.vibe.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.button.MaterialButton
import com.mohammadshayani.vibe.R
import com.mohammadshayani.vibe.packet.PacketRuntime
import com.mohammadshayani.vibe.packet.PacketTransportMode
import com.mohammadshayani.vibe.session.AppSessionConfig
import com.mohammadshayani.vibe.storage.ChatEngineStore
import com.mohammadshayani.vibe.storage.SecureKeyStore

class UserQRDetailActivity : AppCompatActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    val config = AppSessionConfig.current(applicationContext)
    renderDetailPage(
      title = "Your QR",
      subtitle = config?.username?.let { "@$it" } ?: "Private account",
    ) { stack, palette ->
      val content = buildQrPayload(config)
      val image = ImageView(this).apply {
        setImageBitmap(QRCodeRenderer.render(content, dp(236f)))
        setBackgroundColor(Color.WHITE)
        setPadding(dp(16f), dp(16f), dp(16f), dp(16f))
      }
      stack.addView(
        image,
        LinearLayout.LayoutParams(dp(268f), dp(268f)).apply {
          gravity = Gravity.CENTER_HORIZONTAL
        },
      )
      stack.addView(space(18f))
      stack.addView(detailGroup(palette, listOf(
        labelValueRow("Username", config?.username?.let { "@$it" } ?: "Unavailable", palette),
        labelValueRow("User ID", config?.userId ?: "Unavailable", palette),
        labelValueRow("Secure ID", config?.secureId ?: "Unavailable", palette),
      )))
    }
  }

  private fun buildQrPayload(config: AppSessionConfig?): String {
    if (config == null) return "vibe://user"
    return "vibe://user/${config.secureId ?: config.userId}?username=${config.username.orEmpty()}"
  }
}

class SecretKeyDetailActivity : AppCompatActivity() {
  private var revealed = false

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    revealed = savedInstanceState?.getBoolean("revealed") ?: false
    render()
  }

  override fun onSaveInstanceState(outState: Bundle) {
    super.onSaveInstanceState(outState)
    outState.putBoolean("revealed", revealed)
  }

  private fun render() {
    val secret = SecureKeyStore.retrieveSecret(applicationContext, "loginSecret").orEmpty()
    renderDetailPage(
      title = "Secret Key",
      subtitle = if (secret.isBlank()) "No key stored on this device" else "Stored on this device",
    ) { stack, palette ->
      if (secret.isNotBlank()) {
        stack.addView(
          ImageView(this).apply {
            setImageBitmap(QRCodeRenderer.render(secret, dp(236f)))
            setBackgroundColor(Color.WHITE)
            setPadding(dp(16f), dp(16f), dp(16f), dp(16f))
          },
          LinearLayout.LayoutParams(dp(268f), dp(268f)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
          },
        )
        stack.addView(space(28f))
      }

      stack.addView(
        TextView(this).apply {
          text = "YOUR SECRET KEY"
          setTextColor(palette.secondaryTextColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
          typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
          setPadding(dp(4f), 0, 0, dp(8f))
        },
      )

      stack.addView(
        TextView(this).apply {
          text = if (secret.isBlank()) "No secret key stored" else displaySecret(secret, revealed)
          setTextColor(if (secret.isBlank()) palette.secondaryTextColor else palette.textColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
          typeface = Typeface.MONOSPACE
          setTextIsSelectable(true)
          background = roundedRect(palette.cardColor, Color.TRANSPARENT, 16f)
          setPadding(dp(16f), dp(20f), dp(16f), dp(20f))
        },
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ),
      )
      if (secret.isNotBlank()) {
        stack.addView(space(18f))
        val actions = LinearLayout(this).apply {
          orientation = LinearLayout.HORIZONTAL
          gravity = Gravity.CENTER_VERTICAL
        }
        actions.addView(
          detailButton(if (revealed) "Hide Key" else "Reveal Key", palette, filled = false) {
            revealed = !revealed
            render()
          },
          LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        actions.addView(space(10f, horizontal = true))
        actions.addView(
          detailButton("Copy", palette, filled = true) {
            val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("Secret Key", secret))
          },
          LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        stack.addView(actions)
      }
      stack.addView(space(18f))
      stack.addView(
        TextView(this).apply {
          text = "CRITICAL: Never share your secret key. This key provides full access to your identity and encrypted messages."
          setTextColor(palette.dangerColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
          gravity = Gravity.CENTER
        },
      )
    }
  }

  private fun displaySecret(secret: String, revealed: Boolean): String {
    if (revealed || secret.length <= 10) return secret
    return secret.take(6) + "x".repeat(secret.length - 10) + secret.takeLast(4)
  }
}

class ConnectionDetailActivity : AppCompatActivity() {
  private val modes = listOf(
    PacketTransportMode.PACKET_MESH,
    PacketTransportMode.DIRECT,
    PacketTransportMode.OFFLINE,
  )

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    render()
  }

  private fun render() {
    val config = AppSessionConfig.current(applicationContext)
    val storedConfig = ChatEngineStore.getConfig(applicationContext)
    val mode = config?.transportMode ?: PacketTransportMode.PACKET_MESH
    val packetStatus = storedConfig["packetStatus"]?.toString()?.takeIf { it.isNotBlank() }
    val bridgeId = storedConfig["activePacketBridgeId"]?.toString()?.takeIf { it.isNotBlank() }
    val proxyPort = storedConfig["packetProxyPort"]?.toString()?.takeIf { it.isNotBlank() }
    val lastError = storedConfig["packetLastError"]?.toString()?.takeIf { it.isNotBlank() }

    renderDetailPage(
      title = "Connection Manager",
      subtitle = connectionModeTitle(mode),
    ) { stack, palette ->
      stack.addView(detailGroup(palette, listOf(
        labelValueRow("Mode", connectionModeTitle(mode), palette),
        labelValueRow("Status", connectivityStatus(mode, packetStatus), palette),
        labelValueRow("Bridge", bridgeId ?: "Automatic", palette),
        labelValueRow("Proxy", proxyPort?.let { "Local mesh port $it" } ?: "Not running", palette),
        labelValueRow("Last Error", lastError ?: "None", palette),
      )))
      stack.addView(space(22f))
      stack.addView(
        TextView(this).apply {
          text = "MODES"
          setTextColor(palette.secondaryTextColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
          typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
          setPadding(dp(4f), 0, 0, dp(8f))
        },
      )
      stack.addView(
        detailGroup(
          palette,
          modes.map { modeOption ->
            modeRow(
              mode = modeOption,
              selected = modeOption == mode,
              palette = palette,
            ) {
              applyConnectionMode(modeOption)
            }
          },
        ),
      )
    }
  }

  private fun applyConnectionMode(mode: PacketTransportMode) {
    val current = AppSessionConfig.current(applicationContext) ?: return
    val updated = current.copy(transportMode = mode)
    val loginSecret = SecureKeyStore.retrieveSecret(applicationContext, "loginSecret")
    AppSessionConfig.store(applicationContext, updated)
    if (!loginSecret.isNullOrBlank()) {
      SecureKeyStore.storeSecret(applicationContext, "loginSecret", loginSecret)
    }
    PacketRuntime.stop(applicationContext, resetToDirect = mode == PacketTransportMode.DIRECT)
    render()
  }

  private fun connectivityStatus(mode: PacketTransportMode, packetStatus: String?): String {
    return when (mode) {
      PacketTransportMode.PACKET_MESH -> packetStatus ?: "Automatic"
      PacketTransportMode.DIRECT -> "Direct connectivity"
      PacketTransportMode.OFFLINE -> "Remote traffic paused"
      PacketTransportMode.BRIDGE_TEXT -> "Bridge text"
    }
  }

  private fun modeRow(
    mode: PacketTransportMode,
    selected: Boolean,
    palette: AppThemePalette,
    onClick: () -> Unit,
  ): View {
    val row = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      foreground = selectableItemBackground()
      setPadding(dp(16f), dp(14f), dp(16f), dp(14f))
      setOnClickListener { onClick() }
    }
    val textColumn = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
    }
    row.addView(
      textColumn,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )
    textColumn.addView(
      TextView(this).apply {
        text = connectionModeTitle(mode)
        setTextColor(palette.textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      },
    )
    textColumn.addView(
      TextView(this).apply {
        text = connectionModeDescription(mode)
        setTextColor(palette.secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      },
    )
    if (selected) {
      row.addView(
        ImageView(this).apply {
          setImageResource(android.R.drawable.checkbox_on_background)
          imageTintList = ColorStateList.valueOf(palette.accentColor)
        },
        LinearLayout.LayoutParams(dp(22f), dp(22f)).apply {
          marginStart = dp(12f)
        },
      )
    }
    return row
  }
}

private fun AppCompatActivity.renderDetailPage(
  title: String,
  subtitle: String,
  buildContent: (LinearLayout, AppThemePalette) -> Unit,
) {
  val palette = resolveAppThemePalette(this)
  applyThemedSystemBars(this, palette)

  val root = FrameLayout(this).apply {
    setBackgroundColor(palette.backgroundColor)
  }
  val content = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
  }
  root.addView(
    content,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.MATCH_PARENT,
    ),
  )

  val header = LinearLayout(this).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    setPadding(dp(12f), dp(10f), dp(12f), dp(10f))
  }
  content.addView(
    header,
    LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    ),
  )

  header.addView(
    ImageView(this).apply {
      setImageResource(R.drawable.ic_vibe_chevron_left)
      setColorFilter(palette.textColor)
      background = selectableItemBackground()
      setPadding(dp(9f), dp(9f), dp(9f), dp(9f))
      setOnClickListener { finish() }
    },
    LinearLayout.LayoutParams(dp(40f), dp(40f)),
  )

  val titleColumn = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    gravity = Gravity.CENTER
  }
  header.addView(
    titleColumn,
    LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
  )
  titleColumn.addView(
    TextView(this).apply {
      text = title
      setTextColor(palette.textColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      gravity = Gravity.CENTER
    },
  )
  titleColumn.addView(
    TextView(this).apply {
      text = subtitle
      setTextColor(palette.secondaryTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      gravity = Gravity.CENTER
    },
  )
  header.addView(View(this), LinearLayout.LayoutParams(dp(40f), dp(40f)))

  val scrollView = ScrollView(this).apply {
    isFillViewport = true
    clipToPadding = false
  }
  content.addView(
    scrollView,
    LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      0,
      1f,
    ),
  )
  val stack = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(dp(16f), dp(18f), dp(16f), dp(24f))
  }
  scrollView.addView(
    stack,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ),
  )
  buildContent(stack, palette)

  ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
    val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
    header.setPadding(dp(12f), bars.top + dp(10f), dp(12f), dp(10f))
    stack.setPadding(dp(16f), dp(18f), dp(16f), bars.bottom + dp(24f))
    insets
  }

  setContentView(root)
}

private fun AppCompatActivity.labelValueRow(
  label: String,
  value: String,
  palette: AppThemePalette,
): View {
  val row = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(dp(16f), dp(13f), dp(16f), dp(13f))
  }
  row.addView(
    TextView(this).apply {
      text = label
      setTextColor(palette.secondaryTextColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    },
  )
  row.addView(
    TextView(this).apply {
      text = value
      setTextColor(palette.textColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
      setPadding(0, dp(3f), 0, 0)
    },
  )
  return row
}

private fun AppCompatActivity.detailGroup(
  palette: AppThemePalette,
  rows: List<View>,
): LinearLayout {
  val group = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    background = roundedRect(palette.cardColor, Color.TRANSPARENT, 18f)
  }
  rows.forEachIndexed { index, row ->
    group.addView(row)
    if (index != rows.lastIndex) {
      group.addView(View(this).apply {
        setBackgroundColor(palette.dividerColor)
      }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1f)).apply {
        marginStart = dp(16f)
      })
    }
  }
  return group
}

private fun AppCompatActivity.detailButton(
  title: String,
  palette: AppThemePalette,
  filled: Boolean = true,
  onClick: () -> Unit,
): MaterialButton {
  return MaterialButton(this).apply {
    text = title
    isAllCaps = false
    cornerRadius = dp(20f)
    setTextColor(if (filled) palette.buttonTextColor else palette.textColor)
    backgroundTintList = ColorStateList.valueOf(if (filled) palette.buttonColor else palette.cardColor)
    setOnClickListener { onClick() }
  }
}

private fun connectionModeTitle(mode: PacketTransportMode): String {
  return when (mode) {
    PacketTransportMode.PACKET_MESH -> "Automatic"
    PacketTransportMode.DIRECT -> "Direct"
    PacketTransportMode.OFFLINE -> "Offline"
    PacketTransportMode.BRIDGE_TEXT -> "Bridge Text"
  }
}

private fun connectionModeDescription(mode: PacketTransportMode): String {
  return when (mode) {
    PacketTransportMode.PACKET_MESH -> "Use packet mesh when available and fall back automatically."
    PacketTransportMode.DIRECT -> "Connect directly without packet mesh."
    PacketTransportMode.OFFLINE -> "Pause remote chat traffic until you switch back."
    PacketTransportMode.BRIDGE_TEXT -> "Use the text bridge transport."
  }
}

private fun AppCompatActivity.roundedRect(fillColor: Int, strokeColor: Int, radiusDp: Float): GradientDrawable {
  return GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = dp(radiusDp).toFloat()
    setColor(fillColor)
    if (strokeColor != Color.TRANSPARENT) {
      setStroke(dp(1f), strokeColor)
    }
  }
}

private fun AppCompatActivity.selectableItemBackground() =
  obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let { typedArray ->
    val drawable = getDrawable(typedArray.getResourceId(0, 0))
    typedArray.recycle()
    drawable
  }

private fun AppCompatActivity.space(value: Float, horizontal: Boolean = false): View {
  return View(this).apply {
    layoutParams =
      if (horizontal) {
        LinearLayout.LayoutParams(dp(value), 1)
      } else {
        LinearLayout.LayoutParams(1, dp(value))
      }
  }
}

private fun AppCompatActivity.dp(value: Float): Int =
  TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
