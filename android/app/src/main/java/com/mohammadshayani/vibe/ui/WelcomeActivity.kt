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
  private val animatedWordViews = ArrayList<TextView>()

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
    root.post { startWordAnimation() }
  }

  override fun onResume() {
    super.onResume()
    backdropView.refreshAppearance()
    backdropView.onHostResume()
  }

  override fun onPause() {
    backdropView.onHostPause()
    super.onPause()
  }

  private fun buildHeroContent(palette: WelcomeSurfacePalette): LinearLayout {
    return LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL

      addView(
        TextView(context).apply {
          text = "Vibe"
          setTextColor(palette.brandTextColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
          typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
          gravity = Gravity.CENTER
        },
      )

      addView(
        buildAnimatedWordsRow(palette),
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.WRAP_CONTENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
          topMargin = dp(12f)
        },
      )

      addView(
        TextView(context).apply {
          text = "Use your secret key to return or create a new identity."
          setTextColor(palette.secondaryTextColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
          typeface = Typeface.create("sans-serif", Typeface.NORMAL)
          gravity = Gravity.CENTER
          setLineSpacing(0f, 1.12f)
        },
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
          topMargin = dp(16f)
          marginStart = dp(16f)
          marginEnd = dp(16f)
        },
      )
    }
  }

  private fun buildAnimatedWordsRow(palette: WelcomeSurfacePalette): LinearLayout {
    return LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER

      listOf("Light", "in", "darkness.").forEachIndexed { index, word ->
        val label =
          TextView(context).apply {
            text = word
            alpha = 0f
            translationY = dp(10f).toFloat()
            setTextColor(palette.primaryTextColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, if (index == 2) 23f else 24f)
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            gravity = Gravity.CENTER
          }
        animatedWordViews += label
        addView(
          label,
          LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
          ).apply {
            if (index > 0) {
              marginStart = dp(6f)
            }
          },
        )
      }
    }
  }

  private fun buildActionPanel(palette: WelcomeSurfacePalette): LinearLayout {
    return LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      background = palette.panelDrawable(this@WelcomeActivity)
      elevation = dp(8f).toFloat()
      setPadding(dp(16f), dp(16f), dp(16f), dp(16f))

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
      cornerRadius = dp(26f)
      strokeWidth = dp(1f)
      strokeColor = ColorStateList.valueOf(palette.primaryButtonBorderColor)
      backgroundTintList = ColorStateList.valueOf(palette.primaryButtonBackgroundColor)
      insetTop = 0
      insetBottom = 0
      minimumHeight = dp(52f)
    }
  }

  private fun makeSecondaryButton(title: String, palette: WelcomeSurfacePalette): MaterialButton {
    return MaterialButton(this).apply {
      text = title
      isAllCaps = false
      setTextColor(palette.secondaryButtonTextColor)
      textSize = 15f
      cornerRadius = dp(26f)
      strokeWidth = dp(1f)
      strokeColor = ColorStateList.valueOf(palette.secondaryButtonBorderColor)
      backgroundTintList = ColorStateList.valueOf(palette.secondaryButtonBackgroundColor)
      insetTop = 0
      insetBottom = 0
      minimumHeight = dp(52f)
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

  private fun startWordAnimation() {
    animatedWordViews.forEachIndexed { index, view ->
      view.animate()
        .alpha(1f)
        .translationY(0f)
        .setStartDelay(160L + (index * 210L))
        .setDuration(760L)
        .start()
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
          backgroundColor = Color.rgb(6, 9, 16),
          navigationBarColor = Color.rgb(5, 8, 13),
          brandTextColor = Color.argb(178, 223, 230, 243),
          primaryTextColor = Color.rgb(248, 250, 255),
          secondaryTextColor = Color.argb(196, 200, 210, 225),
          panelTopColor = Color.argb(224, 13, 18, 30),
          panelBottomColor = Color.argb(214, 8, 11, 19),
          panelBorderColor = Color.argb(40, 255, 255, 255),
          primaryButtonBackgroundColor = Color.rgb(227, 235, 248),
          primaryButtonTextColor = Color.rgb(14, 18, 27),
          primaryButtonBorderColor = Color.argb(26, 255, 255, 255),
          secondaryButtonBackgroundColor = Color.argb(22, 255, 255, 255),
          secondaryButtonTextColor = Color.WHITE,
          secondaryButtonBorderColor = Color.argb(44, 255, 255, 255),
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

private fun dp(context: android.content.Context, value: Float): Int =
  TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics).toInt()
