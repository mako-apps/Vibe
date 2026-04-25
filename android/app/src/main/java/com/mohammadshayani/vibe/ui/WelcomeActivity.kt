package com.mohammadshayani.vibe.ui

import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.google.android.material.button.MaterialButton

class WelcomeActivity : AppCompatActivity() {
  private lateinit var backdropView: WelcomeGpuBackdropView
  private lateinit var messageLabel: RevealLabel
  private val messages = listOf(
    "Unbreakable Encryption.",
    "Autonomous AI Agents.",
    "Your Private Sanctuary.",
  )
  private var messageHandler = android.os.Handler(android.os.Looper.getMainLooper())
  private var messageRunnable: Runnable? = null
  private var currentMessageIndex = 0

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)

    val palette = WelcomeSurfacePalette.resolve(this)
    WindowCompat.setDecorFitsSystemWindows(window, false)
    window.statusBarColor = Color.TRANSPARENT
    window.navigationBarColor = palette.navigationBarColor
    WindowInsetsControllerCompat(window, window.decorView).apply {
      isAppearanceLightStatusBars = !palette.isDark
      isAppearanceLightNavigationBars = !palette.isDark
    }

    val root = FrameLayout(this).apply {
      setBackgroundColor(palette.backgroundColor)
    }

    backdropView = WelcomeGpuBackdropView(this)
    root.addView(
      backdropView,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      ),
    )

    val contentColumn =
      LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
      }
    root.addView(
      contentColumn,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      ),
    )

    contentColumn.addView(
      View(this),
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1.12f,
      ),
    )

    val heroContent = buildHeroContent(palette)
    contentColumn.addView(
      heroContent,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    contentColumn.addView(
      View(this),
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        0.94f,
      ),
    )

    val actionPanel = buildActionPanel(palette)
    contentColumn.addView(
      actionPanel,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
      contentColumn.setPadding(
        dp(20f),
        bars.top + dp(12f),
        dp(20f),
        bars.bottom + dp(18f),
      )
      insets
    }

    setContentView(root)

    // Trigger initial reveal
    root.postDelayed({
      messageLabel.reveal(1000L)
    }, 100L)

    setupSyncAnimation()
  }

  private fun setupSyncAnimation() {
    messageRunnable = object : Runnable {
      override fun run() {
        currentMessageIndex = (currentMessageIndex + 1) % messages.size
        messageLabel.transition(messages[currentMessageIndex], 1200L)
        messageHandler.postDelayed(this, 4500L)
      }
    }
    messageHandler.postDelayed(messageRunnable!!, 4500L)
  }

  override fun onResume() {
    super.onResume()
    backdropView.onHostResume()
    if (messageRunnable == null) {
      setupSyncAnimation()
    }
  }

  override fun onPause() {
    messageRunnable?.let { messageHandler.removeCallbacks(it) }
    messageRunnable = null
    backdropView.onHostPause()
    super.onPause()
  }

  private fun buildHeroContent(palette: WelcomeSurfacePalette): LinearLayout {
    return LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      // Narrower width (matching iOS 40dp margins)
      setPadding(dp(44f), 0, dp(44f), 0)

      addView(
        TextView(context).apply {
          text = "VIBE"
          setTextColor(palette.brandTextColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
          typeface = Typeface.create("sans-serif", Typeface.BOLD)
          letterSpacing = 0.4f
          gravity = Gravity.CENTER
        },
      )

      messageLabel = RevealLabel(this@WelcomeActivity).apply {
        text = messages[0]
        // Dimmed contrast (matching iOS 0.88 white)
        setTextColor(Color.parseColor("#E0E0E0"))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 26f)
        typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
        gravity = Gravity.CENTER
        setLineSpacing(0f, 1.0f)
      }
      addView(
        messageLabel,
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
          topMargin = dp(24f)
        },
      )
    }
  }



  private fun buildActionPanel(palette: WelcomeSurfacePalette): LinearLayout {
    return LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      setPadding(dp(32f), dp(22f), dp(32f), dp(24f))

      val signUpButton = makePrimaryButton("Create Account", palette).apply {
        setOnClickListener {
          presentAuth(AuthActivity.Mode.SIGN_UP)
        }
      }
      addView(signUpButton, buttonLayoutParams(0))

      val signInButton = makeSecondaryButton("Sign In", palette).apply {
        setOnClickListener {
          presentAuth(AuthActivity.Mode.SIGN_IN)
        }
      }
      addView(signInButton, buttonLayoutParams(dp(12f)))
    }
  }

  private fun presentAuth(mode: AuthActivity.Mode) {
    AuthSheetPresenter.show(
      activity = this,
      mode = mode,
      onAuthenticated = { launchHome() },
    )
  }

  private fun launchHome() {
    startActivity(
      Intent(this, ChatHomeActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
      },
    )
    finish()
  }

  private fun makePrimaryButton(title: String, palette: WelcomeSurfacePalette): MaterialButton {
    return MaterialButton(this).apply {
      text = title
      isAllCaps = false
      setTextColor(palette.primaryButtonTextColor)
      textSize = 15f
      cornerRadius = dp(27f)
      backgroundTintList = ColorStateList.valueOf(palette.primaryButtonBackgroundColor)
      insetTop = 0
      insetBottom = 0
      minimumHeight = dp(54f)
    }
  }

  private fun makeSecondaryButton(title: String, palette: WelcomeSurfacePalette): MaterialButton {
    return MaterialButton(this).apply {
      text = title
      isAllCaps = false
      setTextColor(palette.secondaryButtonTextColor)
      textSize = 15f
      cornerRadius = dp(27f)
      strokeWidth = dp(1f)
      strokeColor = ColorStateList.valueOf(palette.secondaryButtonBorderColor)
      backgroundTintList = ColorStateList.valueOf(palette.secondaryButtonBackgroundColor)
      insetTop = 0
      insetBottom = 0
      minimumHeight = dp(54f)
    }
  }

  private fun buttonLayoutParams(topMargin: Int): LinearLayout.LayoutParams {
    return LinearLayout.LayoutParams(
      LinearLayout.LayoutParams.MATCH_PARENT,
      LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      this.topMargin = topMargin
    }
  }



  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
}

private data class WelcomeSurfacePalette(
  val isDark: Boolean,
  val backgroundColor: Int,
  val navigationBarColor: Int,
  val brandTextColor: Int,
  val primaryTextColor: Int,
  val secondaryTextColor: Int,
  val panelTopColor: Int,
  val panelBottomColor: Int,
  val panelBorderColor: Int,
  val primaryButtonBackgroundColor: Int,
  val primaryButtonTextColor: Int,
  val primaryButtonBorderColor: Int,
  val secondaryButtonBackgroundColor: Int,
  val secondaryButtonTextColor: Int,
  val secondaryButtonBorderColor: Int,
) {
  fun panelDrawable(context: android.content.Context): GradientDrawable {
    return GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = dp(context, 30f).toFloat()
      colors = intArrayOf(panelTopColor, panelBottomColor)
      setStroke(dp(context, 1f), panelBorderColor)
    }
  }

  companion object {
    fun resolve(context: android.content.Context): WelcomeSurfacePalette {
      return if (isNightMode(context)) {
        WelcomeSurfacePalette(
          isDark = true,
          backgroundColor = Color.rgb(4, 4, 5),
          navigationBarColor = Color.rgb(4, 4, 5),
          brandTextColor = Color.argb(166, 166, 166, 166),
          primaryTextColor = Color.rgb(245, 245, 245),
          secondaryTextColor = Color.argb(166, 166, 166, 166),
          panelTopColor = Color.TRANSPARENT,
          panelBottomColor = Color.TRANSPARENT,
          panelBorderColor = Color.TRANSPARENT,
          primaryButtonBackgroundColor = Color.rgb(242, 242, 242),
          primaryButtonTextColor = Color.BLACK,
          primaryButtonBorderColor = Color.TRANSPARENT,
          secondaryButtonBackgroundColor = Color.argb(13, 255, 255, 255),
          secondaryButtonTextColor = Color.rgb(230, 230, 230),
          secondaryButtonBorderColor = Color.argb(38, 255, 255, 255),
        )
      } else {
        WelcomeSurfacePalette(
          isDark = false,
          backgroundColor = Color.rgb(244, 247, 252),
          navigationBarColor = Color.WHITE,
          brandTextColor = Color.argb(172, 72, 85, 105),
          primaryTextColor = Color.rgb(24, 30, 38),
          secondaryTextColor = Color.argb(196, 78, 91, 108),
          panelTopColor = Color.argb(230, 255, 255, 255),
          panelBottomColor = Color.argb(214, 247, 249, 253),
          panelBorderColor = Color.argb(112, 255, 255, 255),
          primaryButtonBackgroundColor = Color.rgb(18, 24, 34),
          primaryButtonTextColor = Color.WHITE,
          primaryButtonBorderColor = Color.argb(24, 255, 255, 255),
          secondaryButtonBackgroundColor = Color.argb(214, 255, 255, 255),
          secondaryButtonTextColor = Color.rgb(24, 30, 38),
          secondaryButtonBorderColor = Color.rgb(214, 223, 236),
        )
      }
    }
  }
}

private class RevealLabel(context: android.content.Context) : TextView(context) {
  init {
    alpha = 0f
    translationY = 8f * context.resources.displayMetrics.density
    scaleX = 0.96f
    scaleY = 0.96f
  }

  fun reveal(duration: Long) {
    animate()
      .alpha(1f)
      .translationY(0f)
      .scaleX(1.0f)
      .scaleY(1.0f)
      .setDuration(duration)
      .setInterpolator(android.view.animation.DecelerateInterpolator())
      .start()
  }

  fun transition(toText: String, duration: Long) {
    animate()
      .alpha(0f)
      .translationY(8f * context.resources.displayMetrics.density)
      .scaleX(0.96f)
      .scaleY(0.96f)
      .setDuration(400)
      .setInterpolator(android.view.animation.AccelerateInterpolator())
      .withEndAction {
        text = toText
        animate()
          .alpha(1f)
          .translationY(0f)
          .scaleX(1.0f)
          .scaleY(1.0f)
          .setDuration(duration)
          .setInterpolator(android.view.animation.DecelerateInterpolator())
          .start()
      }
      .start()
  }
}

private fun dp(context: android.content.Context, value: Float): Int =
  TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics).toInt()
