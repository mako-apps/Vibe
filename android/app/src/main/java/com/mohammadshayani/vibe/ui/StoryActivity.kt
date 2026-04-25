package com.mohammadshayani.vibe.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.mohammadshayani.vibe.R
import com.mohammadshayani.vibe.session.AppSessionConfig
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

class StoryActivity : AppCompatActivity() {

  private lateinit var root: FrameLayout
  private lateinit var previewImageView: ImageView
  private lateinit var topBar: LinearLayout
  private lateinit var closeButton: ImageView
  private lateinit var loadingIndicator: ProgressBar

  // Main Mode views
  private lateinit var mainContainer: LinearLayout
  private lateinit var cameraButton: MaterialButton
  private lateinit var galleryButton: MaterialButton

  // Edit Mode views
  private lateinit var editContainer: LinearLayout
  private lateinit var aiEditButton: MaterialButton
  private lateinit var publishNextButton: MaterialButton

  private var selectedImageUri: Uri? = null
  private var currentCameraUri: Uri? = null

  private val httpClient = OkHttpClient()
  private val mainHandler = Handler(Looper.getMainLooper())

  private val pickImageLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
    if (result.resultCode == Activity.RESULT_OK) {
      result.data?.data?.let { uri ->
        handleImageSelected(uri)
      }
    }
  }

  private val takePictureLauncher = registerForActivityResult(ActivityResultContracts.TakePicture()) { success ->
    if (success) {
      currentCameraUri?.let { uri ->
        handleImageSelected(uri)
      }
    }
  }

  private val requestCameraPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { isGranted ->
    if (isGranted) {
      launchCamera()
    } else {
      showPermissionSettingsDialog(
        "Camera Permission Required",
        "The app needs access to the camera to take stories. Please grant it in Settings."
      )
    }
  }

  private fun showPermissionSettingsDialog(title: String, message: String) {
    MaterialAlertDialogBuilder(this)
      .setTitle(title)
      .setMessage(message)
      .setPositiveButton("Open Settings") { _, _ ->
        val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
          data = Uri.fromParts("package", packageName, null)
        }
        startActivity(intent)
      }
      .setNegativeButton("Cancel", null)
      .show()
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    AppAppearanceController.applyStoredPreference(this)
    super.onCreate(savedInstanceState)
    overridePendingTransition(android.R.anim.slide_in_left, android.R.anim.slide_out_right)

    // Fullscreen for camera-like experience
    window.setFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
    val palette = resolveAppThemePalette(this)

    root = FrameLayout(this).apply {
      setBackgroundColor(Color.parseColor("#08080A"))
    }

    // 1. Preview Image
    previewImageView = ImageView(this).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
      )
      scaleType = ImageView.ScaleType.CENTER_CROP
      visibility = View.GONE
    }
    root.addView(previewImageView)

    // 2. Top Bar
    topBar = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      setPadding(dp(16f), dp(48f), dp(16f), dp(16f)) // Account for status bar
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT
      ).apply {
        gravity = Gravity.TOP
      }
      background = GradientDrawable(
        GradientDrawable.Orientation.TOP_BOTTOM,
        intArrayOf(Color.parseColor("#99000000"), Color.TRANSPARENT)
      )
    }
    
    closeButton = ImageView(this).apply {
      setImageResource(R.drawable.ic_close)
      setColorFilter(Color.WHITE)
      background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.parseColor("#66000000"))
      }
      setPadding(dp(10f), dp(10f), dp(10f), dp(10f))
      layoutParams = LinearLayout.LayoutParams(dp(44f), dp(44f))
      setOnClickListener { 
        finish() 
      }
    }
    topBar.addView(closeButton)
    root.addView(topBar)

    // 3. Main Container (Camera/Gallery selection)
    mainContainer = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
      )
    }

    val instructions = TextView(this).apply {
      text = "Create a Story"
      setTextColor(Color.WHITE)
      textSize = 24f
      typeface = Typeface.create("sans-serif-bold", Typeface.NORMAL)
      gravity = Gravity.CENTER
      setPadding(0, 0, 0, dp(40f))
    }
    mainContainer.addView(instructions)

    val buttonsLayout = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
    }

    cameraButton = MaterialButton(this).apply {
      text = "Camera"
      isAllCaps = false
      setBackgroundColor(Color.parseColor("#1B1E26"))
      setTextColor(Color.WHITE)
      cornerRadius = dp(24f)
      layoutParams = LinearLayout.LayoutParams(dp(120f), dp(48f)).apply { marginEnd = dp(16f) }
      setOnClickListener { checkCameraPermissionAndLaunch() }
    }
    buttonsLayout.addView(cameraButton)

    galleryButton = MaterialButton(this).apply {
      text = "Gallery"
      isAllCaps = false
      setBackgroundColor(palette.accentColor)
      setTextColor(Color.WHITE)
      cornerRadius = dp(24f)
      layoutParams = LinearLayout.LayoutParams(dp(120f), dp(48f))
      setOnClickListener { launchGallery() }
    }
    buttonsLayout.addView(galleryButton)

    mainContainer.addView(buttonsLayout)
    root.addView(mainContainer)

    // 4. Edit Container (AI Edit / Publish)
    editContainer = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
      setPadding(dp(24f), dp(24f), dp(24f), dp(48f))
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT
      ).apply {
        gravity = Gravity.BOTTOM
      }
      visibility = View.GONE
      background = GradientDrawable(
        GradientDrawable.Orientation.BOTTOM_TOP,
        intArrayOf(Color.parseColor("#B3000000"), Color.TRANSPARENT)
      )
    }

    aiEditButton = MaterialButton(this).apply {
      text = "AI Edit"
      isAllCaps = false
      setBackgroundColor(Color.parseColor("#3B82F6"))
      setTextColor(Color.WHITE)
      cornerRadius = dp(24f)
      layoutParams = LinearLayout.LayoutParams(0, dp(54f), 1f).apply { marginEnd = dp(8f) }
      setOnClickListener { showAIEditPrompt() }
    }
    editContainer.addView(aiEditButton)

    publishNextButton = MaterialButton(this).apply {
      text = "Next >"
      isAllCaps = false
      setBackgroundColor(palette.accentColor)
      setTextColor(Color.WHITE)
      cornerRadius = dp(24f)
      layoutParams = LinearLayout.LayoutParams(0, dp(54f), 1f).apply { marginStart = dp(8f) }
      setOnClickListener { showPublishModal() }
    }
    editContainer.addView(publishNextButton)

    root.addView(editContainer)

    loadingIndicator = ProgressBar(this).apply {
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT
      ).apply {
        gravity = Gravity.CENTER
      }
      visibility = View.GONE
    }
    root.addView(loadingIndicator)

    setContentView(root)
  }

  override fun finish() {
    super.finish()
    overridePendingTransition(android.R.anim.slide_in_left, android.R.anim.slide_out_right)
  }

  private fun dp(value: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()

  private fun checkCameraPermissionAndLaunch() {
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
      launchCamera()
    } else {
      requestCameraPermissionLauncher.launch(Manifest.permission.CAMERA)
    }
  }

  private fun launchCamera() {
    val tempFile = File(cacheDir, "camera_capture_${System.currentTimeMillis()}.jpg")
    currentCameraUri = FileProvider.getUriForFile(this, "${packageName}.provider", tempFile)
    takePictureLauncher.launch(currentCameraUri)
  }

  private fun launchGallery() {
    val intent = Intent(Intent.ACTION_GET_CONTENT)
    intent.type = "image/*"
    pickImageLauncher.launch(intent)
  }

  private fun handleImageSelected(uri: Uri) {
    selectedImageUri = uri
    previewImageView.setImageURI(uri)
    previewImageView.visibility = View.VISIBLE
    mainContainer.visibility = View.GONE
    editContainer.visibility = View.VISIBLE
  }

  private fun showAIEditPrompt() {
    val input = EditText(this).apply {
      hint = "e.g. Make it look like a painting"
      setTextColor(Color.BLACK)
    }
    MaterialAlertDialogBuilder(this)
      .setTitle("AI Image Edit")
      .setMessage("Describe how you want to change this image:")
      .setView(FrameLayout(this).apply {
        setPadding(dp(20f), dp(10f), dp(20f), dp(10f))
        addView(input)
      })
      .setPositiveButton("Generate") { _, _ ->
        val prompt = input.text.toString().trim()
        if (prompt.isNotEmpty()) {
          performAIEdit(prompt)
        }
      }
      .setNegativeButton("Cancel", null)
      .show()
  }

  private fun performAIEdit(prompt: String) {
    // This is a placeholder for actual AI image handling.
    // In a real app, we'd base64 encode the image, POST to an edit API, and receive a new URI.
    setLoading(true)
    mainHandler.postDelayed({
      setLoading(false)
      Toast.makeText(this, "AI Edit applied: $prompt (simulated)", Toast.LENGTH_SHORT).show()
    }, 2000)
  }

  private fun showPublishModal() {
    val palette = resolveAppThemePalette(this)
    val bottomSheet = BottomSheetDialog(this, R.style.ThemeOverlay_Vibe_BottomSheetDialog)
    
    val container = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setBackgroundColor(palette.backgroundColor)
      setPadding(dp(24f), dp(24f), dp(24f), dp(32f))
    }

    val title = TextView(this).apply {
      text = "Publish Story"
      setTextColor(palette.textColor)
      textSize = 24f
      typeface = Typeface.create("sans-serif-bold", Typeface.NORMAL)
      setPadding(0, 0, 0, dp(16f))
    }
    container.addView(title)

    val publicBtn = MaterialButton(this).apply {
      text = "Public (Everyone)"
      isAllCaps = false
      setBackgroundColor(palette.accentColor)
      setTextColor(Color.WHITE)
      cornerRadius = dp(24f)
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(54f)).apply {
        bottomMargin = dp(12f)
      }
      setOnClickListener {
        bottomSheet.dismiss()
        publishStory("everyone")
      }
    }
    container.addView(publicBtn)

    val draftBtn = MaterialButton(this).apply {
      text = "Save as Draft"
      isAllCaps = false
      setBackgroundColor(palette.inputColor)
      setTextColor(palette.textColor)
      cornerRadius = dp(24f)
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(54f))
      setOnClickListener {
        bottomSheet.dismiss()
        Toast.makeText(this@StoryActivity, "Saved to Drafts", Toast.LENGTH_SHORT).show()
        finish()
      }
    }
    container.addView(draftBtn)

    bottomSheet.setContentView(container)
    bottomSheet.window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
    
    bottomSheet.findViewById<View>(com.google.android.material.R.id.design_bottom_sheet)?.let { sheet ->
      sheet.background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        val r = dp(34f).toFloat()
        cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        setColor(palette.backgroundColor)
      }
    }

    bottomSheet.show()
  }

  private fun publishStory(audience: String) {
    val uri = selectedImageUri ?: return
    val config = AppSessionConfig.current(this)
    if (config == null) {
      Toast.makeText(this, "Not authenticated", Toast.LENGTH_SHORT).show()
      return
    }

    setLoading(true)

    Thread {
      try {
        val tempFile = File(cacheDir, "story_upload_${System.currentTimeMillis()}.jpg")
        contentResolver.openInputStream(uri)?.use { input ->
          FileOutputStream(tempFile).use { output ->
            input.copyTo(output)
          }
        }

        val base = config.apiBaseUrl.trim().trimEnd('/')
        val pathBase = if (base.lowercase().endsWith("/api")) base else "$base/api"
        val uploadUrl = "$pathBase/media/upload"

        val requestBody = MultipartBody.Builder()
          .setType(MultipartBody.FORM)
          .addFormDataPart(
            "file",
            tempFile.name,
            tempFile.asRequestBody("image/jpeg".toMediaTypeOrNull())
          )
          .build()

        val uploadRequest = Request.Builder()
          .url(uploadUrl)
          .post(requestBody)
          .header("Authorization", "Bearer ${config.authToken}")
          .build()

        val uploadResponse = httpClient.newCall(uploadRequest).execute()
        val uploadResponseBody = uploadResponse.body?.string()

        if (!uploadResponse.isSuccessful || uploadResponseBody.isNullOrBlank()) {
          throw IOException("Failed to upload media: ${uploadResponse.code}")
        }

        val uploadJson = JSONObject(uploadResponseBody)
        val uploadedUri = uploadJson.optString("uri") ?: uploadJson.optString("url")
        if (uploadedUri.isBlank()) {
          throw IOException("Upload response missing URI")
        }

        val publishUrl = "$pathBase/stories"
        val storyPayload = JSONObject()
          .put("mediaUri", uploadedUri)
          .put("mediaType", "image")
          .put("visibility", audience)
          .toString()

        val publishRequest = Request.Builder()
          .url(publishUrl)
          .post(storyPayload.toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
          .header("Authorization", "Bearer ${config.authToken}")
          .build()

        val publishResponse = httpClient.newCall(publishRequest).execute()
        if (!publishResponse.isSuccessful) {
          throw IOException("Failed to publish story: ${publishResponse.code}")
        }

        mainHandler.post {
          setLoading(false)
          Toast.makeText(this, "Story Published!", Toast.LENGTH_SHORT).show()
          finish()
        }

      } catch (e: Exception) {
        e.printStackTrace()
        mainHandler.post {
          setLoading(false)
          Toast.makeText(this, "Error: ${e.message}", Toast.LENGTH_LONG).show()
        }
      }
    }.start()
  }

  private fun setLoading(isLoading: Boolean) {
    loadingIndicator.visibility = if (isLoading) View.VISIBLE else View.GONE
    editContainer.visibility = if (isLoading) View.GONE else View.VISIBLE
    closeButton.isEnabled = !isLoading
  }
}
