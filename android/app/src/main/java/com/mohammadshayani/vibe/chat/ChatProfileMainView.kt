package com.mohammadshayani.vibe.chat

import com.mohammadshayani.vibe.R
import com.mohammadshayani.vibe.network.resolveAvatarUri

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.MediaPlayer
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.net.URL
import java.util.Locale

class ChatProfileMainView(
  context: Context,
  appContext: NativeChatContext,
) : NativeChatView(context, appContext) {
  override val shouldUseAndroidLayout: Boolean = true

  companion object {
    private const val PROFILE_HEADER_COLLAPSE_DISTANCE_DP = 120f
    private val LINK_REGEX = Regex("""https?://\S+|www\.\S+""", RegexOption.IGNORE_CASE)
  }

  private data class ProfileSharedItem(
    val section: String,
    val messageId: String,
    val title: String,
    val subtitle: String,
    val type: String,
    val mediaUrl: String,
    val fileName: String,
  )

  private val onViewportChanged by NativeEventDispatcher<Map<String, Any>>()
  private val onNativeEvent by NativeEventDispatcher<Map<String, Any>>()

  private val headerContainer = FrameLayout(context)
  private val headerGlass = LiquidGlassView(context, appContext)
  private val backButton = ImageView(context)
  private val headerTitleView = TextView(context)
  private val headerNameView = TextView(context)

  private val scrollView = ScrollView(context)
  private val contentView = LinearLayout(context)
  private val heroAvatar = FrameLayout(context)
  private val avatarImage = ImageView(context)
  private val avatarFallback = ImageView(context)
  private val nameView = TextView(context)
  private val handleView = TextView(context)
  private val bioView = TextView(context)
  private val identityCard = LinearLayout(context)
  private val identityTitleView = TextView(context)
  private val identityValueView = TextView(context)
  private val identityCopyView = TextView(context)

  private val actionsRow = LinearLayout(context)
  private val muteAction = ChatMainProfileActionNode(context)
  private val searchAction = ChatMainProfileActionNode(context)
  private val audioAction = ChatMainProfileActionNode(context)
  private val videoAction = ChatMainProfileActionNode(context)

  private val infoCard = LinearLayout(context)
  private val infoTitleView = TextView(context)
  private val membersRow = ChatMainProfileListRowNode(context)
  private val mediaRow = ChatMainProfileListRowNode(context)
  private val audioRow = ChatMainProfileListRowNode(context)
  private val filesRow = ChatMainProfileListRowNode(context)
  private val linksRow = ChatMainProfileListRowNode(context)
  private val pinnedRow = ChatMainProfileListRowNode(context)

  private var surfaceId = ""
  private var headerTitle = "Profile"
  private var headerSubtitle = ""
  private var profileName = "User"
  private var profileHandle = ""
  private var profileBio = ""
  private var avatarUri = ""
  private var isOnline = false
  private var isChatMuted = false
  private var isGroupOrChannel = false
  private var groupMemberCount: Int? = null
  private var groupMemberDisplayNameByUserId: LinkedHashMap<String, String> = linkedMapOf()
  private var groupMemberOrder: MutableList<String> = mutableListOf()
  private var engineChatId = ""
  private var enginePeerUserIdRaw = ""
  private var enginePeerUserId = ""
  private var avatarLoadToken = 0
  private val avatarHttpClient by lazy { ChatPhoenixClient.buildPinnedHttpClient() }
  private var avatarLoadCall: okhttp3.Call? = null

  private var sharedMediaCount = 0
  private var sharedAudioCount = 0
  private var sharedFileCount = 0
  private var sharedLinkCount = 0
  private var sharedPinnedCount = 0
  private var sharedItems: List<ProfileSharedItem> = emptyList()
  private var activeSection: String? = null
  private var profileVoicePlayer: MediaPlayer? = null
  private var profileVoiceMessageId: String? = null

  private var appearance = ChatListAppearance()
  private var textColor: Int = Color.WHITE
  private var secondaryTextColor: Int = Color.argb(220, 220, 220, 220)
  private var surfaceColor: Int = Color.argb(235, 20, 22, 28)
  private var headerBackgroundColor: Int = Color.argb(242, 16, 18, 24)
  private var profileBackgroundColor: Int = Color.argb(255, 16, 18, 24)

  init {
    orientation = VERTICAL
    setBackgroundColor(profileBackgroundColor)
    configureView()
    applyTheme()
    updateProfileTexts()
    updateAvatarViews()
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    if (w <= 0 || h <= 0) return
    onViewportChanged(
      mapOf(
        "width" to w,
        "height" to h,
        "surfaceId" to surfaceId,
      ),
    )
  }

  override fun onDetachedFromWindow() {
    profileVoicePlayer?.release()
    profileVoicePlayer = null
    profileVoiceMessageId = null
    super.onDetachedFromWindow()
  }

  fun setProfileOnly(value: Boolean) {
  }

  fun setSurfaceId(value: String) {
    surfaceId = value.trim()
  }

  fun setRows(rows: List<Map<String, Any?>>) {
    rebuildProfileSummaryFromRows(rows)
    updateProfileTexts()
  }

  fun setEngineSurfaceId(value: String) {
  }

  fun setEngineChatId(value: String) {
    engineChatId = value.trim()
  }

  fun setEngineMyUserId(value: String) {
  }

  fun setEnginePeerUserId(value: String) {
    enginePeerUserIdRaw = value.trim()
    enginePeerUserId = enginePeerUserIdRaw.uppercase(Locale.ROOT)
    updateProfileTexts()
    updateAvatarViews()
  }

  fun setStatusAuthorityEnabled(enabled: Boolean) {
  }

  fun setAppearance(rawAppearance: Map<String, Any?>) {
    parseAppearance(rawAppearance)
    applyTheme()
    updateProfileTexts()
  }

  fun setHeaderTitle(value: String) {
    headerTitle = value.trim().ifBlank { "Profile" }
    updateProfileTexts()
  }

  fun setHeaderSubtitle(value: String) {
    headerSubtitle = value.trim()
    updateProfileTexts()
  }

  fun setProfileName(value: String) {
    profileName = value.trim()
    updateProfileTexts()
  }

  fun setProfileHandle(value: String) {
    profileHandle = value.trim()
    updateProfileTexts()
  }

  fun setProfileBio(value: String) {
    profileBio = value.trim()
    updateProfileTexts()
  }

  fun setAvatarUri(value: String?) {
    avatarUri = (value ?: "").trim()
    updateAvatarViews()
  }

  fun setIsOnline(value: Boolean) {
    isOnline = value
    applyTheme()
    updateProfileTexts()
  }

  fun setIsChatMuted(value: Boolean) {
    if (isChatMuted == value) return
    isChatMuted = value
    updateProfileActionState()
  }

  fun setIsGroupOrChannel(value: Boolean) {
    isGroupOrChannel = value
    applyTheme()
    updateProfileTexts()
    updateAvatarViews()
  }

  fun setGroupMembers(rawMembers: List<Map<String, Any?>>) {
    val nextNamesByUserId = linkedMapOf<String, String>()
    val nextOrder = mutableListOf<String>()
    rawMembers.forEach { raw ->
      val rawId =
        normalized(raw["userId"] ?: raw["id"] ?: raw["memberId"])
          ?.trim()
          ?.takeIf { it.isNotEmpty() }
          ?: return@forEach
      val normalizedId = rawId.uppercase(Locale.ROOT)
      val displayName =
        normalized(raw["name"] ?: raw["username"] ?: raw["label"])
          ?.trim()
          ?.takeIf { it.isNotEmpty() }
          ?: rawId
      if (!nextNamesByUserId.containsKey(normalizedId)) {
        nextOrder.add(normalizedId)
      }
      nextNamesByUserId[normalizedId] = displayName
    }
    groupMemberDisplayNameByUserId = nextNamesByUserId
    groupMemberOrder = nextOrder
    updateProfileTexts()
  }

  fun setGroupMemberCount(value: Int?) {
    groupMemberCount = value?.coerceAtLeast(0)
    updateProfileTexts()
  }

  fun setAgentConfig(value: Map<String, Any?>?) {
  }

  fun setPage(value: String, animated: Boolean) {
  }

  private fun configureView() {
    val statusTop = statusBarHeightPx()

    headerContainer.layoutParams = LayoutParams(
      LayoutParams.MATCH_PARENT,
      statusTop + dp(56),
    )
    addView(headerContainer)

    headerGlass.alpha = 0f
    headerGlass.setCornerRadius(20.0)
    headerGlass.setBlurIntensity(14.0)
    headerGlass.setInteractive(false)
    headerGlass.setPressFeedbackEnabled(false)
    headerContainer.addView(
      headerGlass,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        dp(44),
        Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
      ).apply {
        marginStart = dp(12)
        marginEnd = dp(12)
        bottomMargin = dp(6)
      },
    )

    backButton.scaleType = ImageView.ScaleType.CENTER_INSIDE
    backButton.setImageResource(R.drawable.ic_chevron_left)
    backButton.setPadding(dp(10), dp(10), dp(10), dp(10))
    backButton.setOnClickListener {
      if (activeSection != null) {
        showProfileRootFromSection()
        return@setOnClickListener
      }
      onNativeEvent(mapOf("type" to "headerBack"))
    }
    headerContainer.addView(
      backButton,
      FrameLayout.LayoutParams(dp(44), dp(44), Gravity.START or Gravity.BOTTOM).apply {
        marginStart = dp(12)
        bottomMargin = dp(6)
      },
    )

    headerTitleView.setTypeface(Typeface.DEFAULT_BOLD)
    headerTitleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    headerTitleView.text = "Profile"
    headerTitleView.gravity = Gravity.CENTER
    headerContainer.addView(
      headerTitleView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
      ).apply {
        bottomMargin = dp(18)
      },
    )

    headerNameView.setTypeface(Typeface.DEFAULT_BOLD)
    headerNameView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    headerNameView.gravity = Gravity.CENTER
    headerNameView.alpha = 0f
    headerContainer.addView(
      headerNameView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.WRAP_CONTENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
        Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
      ).apply {
        bottomMargin = dp(18)
      },
    )

    scrollView.overScrollMode = View.OVER_SCROLL_ALWAYS
    scrollView.isFillViewport = true
    scrollView.setOnScrollChangeListener { _, _, scrollY, _, _ ->
      updateProfileHeaderChrome(scrollY)
    }
    addView(
      scrollView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        0,
        1f,
      ),
    )

    contentView.orientation = LinearLayout.VERTICAL
    contentView.gravity = Gravity.CENTER_HORIZONTAL
    contentView.setPadding(dp(20), dp(24), dp(20), dp(32))
    scrollView.addView(
      contentView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    heroAvatar.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(59))
    heroAvatar.clipToOutline = true
    contentView.addView(
      heroAvatar,
      LinearLayout.LayoutParams(dp(118), dp(118)),
    )

    avatarImage.scaleType = ImageView.ScaleType.CENTER_CROP
    avatarImage.visibility = View.GONE
    heroAvatar.addView(
      avatarImage,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    avatarFallback.scaleType = ImageView.ScaleType.FIT_CENTER
    avatarFallback.setImageResource(R.drawable.ic_avatar_person)
    avatarFallback.setPadding(dp(32), dp(32), dp(32), dp(32))
    heroAvatar.addView(
      avatarFallback,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      ),
    )

    nameView.setTypeface(Typeface.DEFAULT_BOLD)
    nameView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
    nameView.gravity = Gravity.CENTER
    nameView.setPadding(0, dp(14), 0, 0)
    contentView.addView(
      nameView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    handleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
    handleView.gravity = Gravity.CENTER
    handleView.setPadding(0, dp(2), 0, 0)
    handleView.maxLines = 1
    handleView.ellipsize = TextUtils.TruncateAt.END
    contentView.addView(
      handleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    identityCard.orientation = LinearLayout.HORIZONTAL
    identityCard.gravity = Gravity.CENTER_VERTICAL
    identityCard.setPadding(dp(16), dp(12), dp(14), dp(12))
    identityCard.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(18))
    identityCard.setOnClickListener { copyPeerUserId() }

    val identityTextStack = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
    }
    identityCard.addView(
      identityTextStack,
      LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
    )

    identityTitleView.text = "User ID"
    identityTitleView.setTypeface(Typeface.DEFAULT_BOLD)
    identityTitleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    identityTextStack.addView(
      identityTitleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    identityValueView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    identityValueView.maxLines = 1
    identityValueView.ellipsize = TextUtils.TruncateAt.MIDDLE
    identityValueView.setPadding(0, dp(3), 0, 0)
    identityTextStack.addView(
      identityValueView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    identityCopyView.text = "Copy"
    identityCopyView.setTypeface(Typeface.DEFAULT_BOLD)
    identityCopyView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    identityCopyView.setPadding(dp(12), dp(7), dp(12), dp(7))
    identityCard.addView(
      identityCopyView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    bioView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    bioView.gravity = Gravity.CENTER
    bioView.setLineSpacing(dpF(2f), 1f)
    bioView.setPadding(dp(8), dp(12), dp(8), 0)
    bioView.visibility = View.GONE
    contentView.addView(
      bioView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    actionsRow.orientation = LinearLayout.HORIZONTAL
    actionsRow.gravity = Gravity.CENTER
    actionsRow.setPadding(0, dp(18), 0, 0)
    contentView.addView(
      actionsRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    muteAction.configure(
      title = "Mute",
      iconRes = android.R.drawable.ic_lock_silent_mode,
    )
    muteAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerMenuAction", "action" to "muteToggle"))
    }

    searchAction.configure(
      title = "Search",
      iconRes = R.drawable.ic_search,
    )
    searchAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerSearchPressed"))
    }

    audioAction.configure(
      title = "Call",
      iconRes = R.drawable.ic_call_accept,
    )
    audioAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerAudioCallPressed"))
    }

    videoAction.configure(
      title = "Video",
      iconRes = R.drawable.ic_video,
    )
    videoAction.setOnClickListener {
      onNativeEvent(mapOf("type" to "headerVideoCallPressed"))
    }

    actionsRow.addView(
      audioAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply { marginEnd = dp(4) },
    )
    actionsRow.addView(
      searchAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply {
        marginStart = dp(2)
        marginEnd = dp(2)
      },
    )
    actionsRow.addView(
      muteAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply {
        marginStart = dp(2)
        marginEnd = dp(2)
      },
    )
    actionsRow.addView(
      videoAction,
      LinearLayout.LayoutParams(0, dp(64), 1f).apply { marginStart = dp(4) },
    )

    contentView.addView(
      identityCard,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(14)
      },
    )

    infoCard.orientation = LinearLayout.VERTICAL
    infoCard.background = roundedShape(withAlpha(surfaceColor, 0.92f), dp(24))
    infoCard.clipToOutline = true
    contentView.addView(
      infoCard,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ).apply {
        topMargin = dp(18)
      },
    )

    infoTitleView.setTypeface(Typeface.DEFAULT_BOLD)
    infoTitleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    infoTitleView.setPadding(dp(18), dp(16), dp(18), dp(8))
    infoCard.addView(
      infoTitleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    membersRow.setOnClickListener {
      onNativeEvent(mapOf("type" to "profileMembersPressed", "chatId" to engineChatId))
    }
    infoCard.addView(
      membersRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    mediaRow.setOnClickListener {
      showSection("media")
    }
    infoCard.addView(
      mediaRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    audioRow.setOnClickListener {
      showSection("audio")
    }
    infoCard.addView(
      audioRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    filesRow.setOnClickListener {
      showSection("files")
    }
    infoCard.addView(
      filesRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    linksRow.setOnClickListener {
      showSection("links")
    }
    infoCard.addView(
      linksRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    pinnedRow.setOnClickListener {
      showSection("pinned")
    }
    infoCard.addView(
      pinnedRow,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )
  }

  private fun parseAppearance(raw: Map<String, Any?>) {
    appearance = ChatListAppearance.from(raw)
    val backgroundColor = appearance.wallpaperGradient.firstOrNull() ?: appearance.bubbleThemColor
    textColor = appearance.textColorThem
    secondaryTextColor = appearance.timeColorThem
    surfaceColor = appearance.bubbleThemColor
    headerBackgroundColor = backgroundColor
    profileBackgroundColor = backgroundColor
  }

  private fun applyTheme() {
    background = GradientDrawable(
      GradientDrawable.Orientation.TL_BR,
      appearance.wallpaperGradient,
    ).apply {
      alpha = (appearance.wallpaperOpacity.coerceIn(0f, 1f) * 255f).toInt().coerceIn(0, 255)
    }
    headerContainer.setBackgroundColor(Color.TRANSPARENT)
    val isDarkPalette = contrastForegroundFor(profileBackgroundColor) == Color.WHITE
    headerGlass.setTintColor(withAlpha(surfaceColor, if (isDarkPalette) 0.88f else 0.9f))
    headerGlass.setBorderEnabled(true)
    headerGlass.setShadowEnabled(true)
    val softRgba = if (isDarkPalette) Color.argb(20, 248, 246, 252) else Color.argb(18, 26, 26, 31)

    heroAvatar.background = roundedShape(softRgba, dp(59))
    identityCard.background = roundedShape(withAlpha(surfaceColor, if (isDarkPalette) 0.92f else 0.96f), dp(18))
    identityCopyView.background = roundedShape(withAlpha(textColor, if (isDarkPalette) 0.12f else 0.08f), dp(13))
    infoCard.background = roundedShape(withAlpha(surfaceColor, if (isDarkPalette) 0.92f else 0.96f), dp(24))

    backButton.setColorFilter(textColor, PorterDuff.Mode.SRC_IN)
    headerTitleView.setTextColor(textColor)
    headerNameView.setTextColor(textColor)
    avatarFallback.setColorFilter(textColor, PorterDuff.Mode.SRC_IN)
    nameView.setTextColor(textColor)
    handleView.setTextColor(if (isOnline && !isGroupOrChannel) Color.parseColor("#53E08A") else secondaryTextColor)
    bioView.setTextColor(secondaryTextColor)
    identityTitleView.setTextColor(textColor)
    identityValueView.setTextColor(secondaryTextColor)
    identityCopyView.setTextColor(textColor)
    infoTitleView.setTextColor(textColor)

    listOf(muteAction, searchAction, audioAction, videoAction).forEach { action ->
      action.applyTheme(
        foreground = textColor,
        background = withAlpha(surfaceColor, if (isDarkPalette) 0.92f else 0.96f),
      )
    }

    applyProfileRowTheme(membersRow, Color.parseColor("#3B82F6"))
    applyProfileRowTheme(mediaRow, Color.parseColor("#EC4899"))
    applyProfileRowTheme(audioRow, Color.parseColor("#10B981"))
    applyProfileRowTheme(filesRow, Color.parseColor("#6366F1"))
    applyProfileRowTheme(linksRow, Color.parseColor("#F59E0B"))
    applyProfileRowTheme(pinnedRow, Color.parseColor("#F97316"))
    updateProfileActionState()
    updateProfileHeaderChrome(scrollView.scrollY)
  }

  private fun updateProfileTexts() {
    val resolvedTitle = profileName.ifBlank { headerTitle.ifBlank { "User" } }
    val resolvedHandle = when {
      !isUuidLike(profileHandle) && profileHandle.isNotBlank() -> atHandle(profileHandle)
      resolvedTitle.isNotBlank() && !isUuidLike(resolvedTitle) -> atHandle(resolvedTitle)
      else -> ""
    }
    val resolvedSubtitle = when {
      isGroupOrChannel -> {
        val count = resolvedGroupMemberCount()
        if (count > 0) "$count members" else "group chat"
      }
      isOnline -> "online"
      headerSubtitle.isNotBlank() -> headerSubtitle
      else -> if (enginePeerUserId.isNotBlank()) "offline" else ""
    }

    val resolvedBio = profileBio.takeIf { it.isNotBlank() }.orEmpty()
    headerNameView.text = resolvedTitle
    if (activeSection == null) {
      headerTitleView.text = resolvedTitle
    }
    nameView.text = resolvedTitle
    handleView.text = resolvedSubtitle
    val userIdDisplay = resolvedUserIdDisplay()
    identityValueView.text = userIdDisplay
    identityCard.visibility = if (userIdDisplay.isBlank() || isSavedMessagesProfile()) View.GONE else View.VISIBLE
    bioView.text = resolvedBio
    bioView.visibility = if (resolvedBio.isBlank()) View.GONE else View.VISIBLE

    if (activeSection == null) {
      configureProfileSummaryRows()
    } else {
      configureSectionRows(activeSection.orEmpty())
    }
    updateProfileHeaderChrome(scrollView.scrollY)
  }

  private fun updateProfileHeaderChrome(scrollY: Int) {
    headerGlass.alpha = 0f
    headerGlass.translationY = 0f
    headerTitleView.alpha = 1f
    headerTitleView.translationY = 0f
    headerNameView.alpha = 0f
    headerNameView.translationY = 0f
    headerContainer.elevation = 0f
  }

  private fun rebuildProfileSummaryFromRows(rows: List<Map<String, Any?>>) {
    var mediaCount = 0
    var audioCount = 0
    var fileCount = 0
    var linkCount = 0
    var pinnedCount = 0
    val nextItems = mutableListOf<ProfileSharedItem>()

    rows.forEach { row ->
      if (normalized(row["kind"]) != "message") return@forEach
      val message = row["message"] as? Map<*, *> ?: return@forEach
      val type = normalized(message["type"])?.lowercase(Locale.ROOT).orEmpty()
      val text = normalized(message["text"]).orEmpty()
      val caption = normalized(message["caption"]).orEmpty()
      val mediaUrl = normalized(message["mediaUrl"]).orEmpty()
      val fileName = normalized(message["fileName"] ?: message["file_name"]).orEmpty()
      val messageId = normalized(message["id"] ?: message["messageId"] ?: row["id"] ?: row["messageId"]).orEmpty()
      val isPinned = (message["isPinned"] as? Boolean) == true
      val title = profileItemTitle(type, text, caption, fileName)
      val subtitle = profileItemSubtitle(type, mediaUrl, fileName)

      if (type == "image" || type == "gif" || type == "video" || type == "sticker") {
        mediaCount += 1
        if (messageId.isNotBlank()) {
          nextItems.add(ProfileSharedItem("media", messageId, title, subtitle, type, mediaUrl, fileName))
        }
      }
      if (type == "voice" || type == "music" || type == "audio") {
        audioCount += 1
        if (messageId.isNotBlank()) {
          nextItems.add(ProfileSharedItem("audio", messageId, title, subtitle, type, mediaUrl, fileName))
        }
      }
      if (type == "file" || type == "document") {
        fileCount += 1
        if (messageId.isNotBlank()) {
          nextItems.add(ProfileSharedItem("files", messageId, title, subtitle, type, mediaUrl, fileName))
        }
      }
      if (containsProfileLink(text) || containsProfileLink(caption)) {
        linkCount += 1
        if (messageId.isNotBlank()) {
          nextItems.add(ProfileSharedItem("links", messageId, linkTitle(text, caption), subtitle, type, mediaUrl, fileName))
        }
      }
      if (isPinned) {
        pinnedCount += 1
        if (messageId.isNotBlank()) {
          nextItems.add(ProfileSharedItem("pinned", messageId, title, subtitle, type, mediaUrl, fileName))
        }
      }
    }

    sharedMediaCount = mediaCount
    sharedAudioCount = audioCount
    sharedFileCount = fileCount
    sharedLinkCount = linkCount
    sharedPinnedCount = pinnedCount
    sharedItems = nextItems
  }

  private fun configureProfileSummaryRows() {
    activeSection = null
    headerTitleView.text = profileName.ifBlank { headerTitle.ifBlank { "Profile" } }
    heroAvatar.visibility = View.VISIBLE
    nameView.visibility = View.VISIBLE
    handleView.visibility = View.VISIBLE
    identityCard.visibility = if (resolvedUserIdDisplay().isBlank() || isSavedMessagesProfile()) View.GONE else View.VISIBLE
    bioView.visibility = if (profileBio.isBlank()) View.GONE else View.VISIBLE
    actionsRow.visibility = View.VISIBLE
    infoCard.removeAllViews()
    val isDarkPalette = contrastForegroundFor(profileBackgroundColor) == Color.WHITE
    infoCard.background = roundedShape(withAlpha(surfaceColor, if (isDarkPalette) 0.92f else 0.96f), dp(24))
    infoCard.clipToOutline = true
    infoTitleView.text = if (isGroupOrChannel) "Overview" else "Shared Content"
    infoCard.addView(
      infoTitleView,
      LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
      ),
    )

    val visibleRows = mutableListOf<ChatMainProfileListRowNode>()

    membersRow.visibility = if (isGroupOrChannel) View.VISIBLE else View.GONE
    if (membersRow.visibility == View.VISIBLE) {
      visibleRows.add(membersRow)
    }
    visibleRows.add(mediaRow)
    visibleRows.add(audioRow)
    visibleRows.add(filesRow)
    visibleRows.add(linksRow)
    visibleRows.add(pinnedRow)
    visibleRows.forEach { row ->
      if (row.parent == null) {
        infoCard.addView(
          row,
          LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
          ),
        )
      }
    }

    visibleRows.forEachIndexed { index, row ->
      val isLast = index == visibleRows.lastIndex
      row.configure(
        title = when (row) {
          membersRow -> "Members"
          mediaRow -> "Media"
          audioRow -> "Audio"
          filesRow -> "Files"
          linksRow -> "Links"
          else -> "Pinned"
        },
        value = when (row) {
          membersRow -> resolvedGroupMemberCount().toString()
          mediaRow -> sharedMediaCount.toString()
          audioRow -> sharedAudioCount.toString()
          filesRow -> sharedFileCount.toString()
          linksRow -> sharedLinkCount.toString()
          else -> sharedPinnedCount.toString()
        },
        iconRes = when (row) {
          membersRow -> R.drawable.ic_profile_members
          mediaRow -> R.drawable.ic_profile_media
          audioRow -> R.drawable.ic_profile_audio
          filesRow -> R.drawable.ic_profile_files
          linksRow -> R.drawable.ic_profile_links
          else -> R.drawable.ic_profile_pinned
        },
        showsSeparator = !isLast,
      )
    }
  }

  private fun applyProfileRowTheme(row: ChatMainProfileListRowNode, accentColor: Int) {
    row.applyTheme(
      titleColor = textColor,
      subtitleColor = secondaryTextColor,
      valueColor = secondaryTextColor,
      separatorColor = withAlpha(textColor, 0.08f),
      highlightedColor = withAlpha(textColor, 0.06f),
      iconTintColor = accentColor,
      iconBackgroundColor = withAlpha(accentColor, 0.12f),
    )
  }

  private fun showSection(section: String) {
    if (activeSection == section) return
    activeSection = section
    configureSectionRows(section)
    scrollView.smoothScrollTo(0, 0)
    animateContentPush(forward = true)
  }

  private fun showProfileRootFromSection() {
    activeSection = null
    configureProfileSummaryRows()
    scrollView.smoothScrollTo(0, 0)
    animateContentPush(forward = false)
  }

  private fun animateContentPush(forward: Boolean) {
    val width = width.takeIf { it > 0 } ?: resources.displayMetrics.widthPixels
    contentView.animate().cancel()
    contentView.alpha = 0f
    contentView.translationX = if (forward) width * 0.18f else -width * 0.18f
    contentView.animate()
      .alpha(1f)
      .translationX(0f)
      .setDuration(220L)
      .start()
  }

  private fun configureSectionRows(section: String) {
    val title = sectionTitle(section)
    headerTitleView.text = title
    heroAvatar.visibility = View.GONE
    nameView.visibility = View.GONE
    handleView.visibility = View.GONE
    identityCard.visibility = View.GONE
    bioView.visibility = View.GONE
    actionsRow.visibility = View.GONE
    infoCard.removeAllViews()
    infoCard.background = roundedStrokeShape(Color.TRANSPARENT, withAlpha(textColor, 0.12f), dp(24), dp(1))
    infoCard.clipToOutline = false

    val items = sharedItems.filter { it.section == section }
    if (items.isEmpty()) {
      infoCard.addView(
        TextView(context).apply {
          text = "No ${title.lowercase(Locale.ROOT)} yet"
          setTextColor(secondaryTextColor)
          setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
          gravity = Gravity.CENTER
          setPadding(dp(18), dp(24), dp(18), dp(28))
        },
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ),
      )
      return
    }

    if (section == "media") {
      val grid = GridLayout(context).apply {
        columnCount = 2
        setPadding(dp(10), dp(10), dp(10), dp(10))
      }
      items.forEach { item ->
        grid.addView(
          mediaGridCellView(item),
          GridLayout.LayoutParams().apply {
            width = 0
            height = dp(154)
            columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
            setMargins(dp(6), dp(6), dp(6), dp(6))
          },
        )
      }
      infoCard.addView(
        grid,
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ),
      )
      return
    }

    items.forEachIndexed { index, item ->
      val view = if (section == "audio") audioBubbleItemView(item) else listItemView(item)
      infoCard.addView(
        view,
        LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
          leftMargin = dp(10)
          rightMargin = dp(10)
          topMargin = if (index == 0) dp(10) else dp(6)
          bottomMargin = if (index == items.lastIndex) dp(10) else dp(6)
        },
      )
    }
  }

  private fun mediaGridCellView(item: ProfileSharedItem): View {
    val cell = FrameLayout(context).apply {
      background = roundedStrokeShape(withAlpha(surfaceColor, 0.22f), withAlpha(textColor, 0.13f), dp(18), dp(1))
      setOnClickListener { openSharedItemInChat(item) }
    }
    cell.addView(
      ChatMainProfileMediaCellNode(context).apply {
        configure(item.mediaUrl.takeIf { item.type != "video" }, isVideo = item.type == "video")
        applyTheme(
          placeholderTintColor = secondaryTextColor,
          placeholderBackgroundColor = withAlpha(textColor, 0.07f),
        )
      },
      FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
    )
    cell.addView(
      TextView(context).apply {
        text = item.title
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        setPadding(dp(9), dp(5), dp(9), dp(5))
        background = roundedShape(Color.argb(132, 0, 0, 0), dp(10))
      },
      FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
        leftMargin = dp(8)
        rightMargin = dp(8)
        bottomMargin = dp(8)
      },
    )
    return cell
  }

  private fun audioBubbleItemView(item: ProfileSharedItem): View {
    val row = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(14), dp(12), dp(14), dp(12))
      background = roundedStrokeShape(Color.TRANSPARENT, withAlpha(textColor, 0.13f), dp(18), dp(1))
    }
    val playButton = TextView(context).apply {
      text = if (profileVoiceMessageId == item.messageId) "Pause" else "Play"
      setTypeface(Typeface.DEFAULT_BOLD)
      setTextColor(textColor)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
      gravity = Gravity.CENTER
      background = roundedShape(withAlpha(textColor, 0.10f), dp(16))
      setOnClickListener { toggleProfileVoice(item, this) }
    }
    row.addView(playButton, LinearLayout.LayoutParams(dp(64), dp(38)))
    val textStack = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(12), 0, dp(10), 0)
    }
    textStack.addView(
      TextView(context).apply {
        text = item.title
        setTextColor(textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
      },
    )
    textStack.addView(
      TextView(context).apply {
        text = item.subtitle.ifBlank { "Voice message" }
        setTextColor(secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        setPadding(0, dp(3), 0, 0)
      },
    )
    row.addView(textStack, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    row.addView(
      TextView(context).apply {
        text = "Chat"
        setTypeface(Typeface.DEFAULT_BOLD)
        setTextColor(textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        gravity = Gravity.CENTER
        setPadding(dp(12), dp(8), dp(12), dp(8))
        background = roundedShape(withAlpha(textColor, 0.08f), dp(14))
        setOnClickListener { openSharedItemInChat(item) }
      },
      LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT),
    )
    return row
  }

  private fun listItemView(item: ProfileSharedItem): View {
    val row = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      setPadding(dp(14), dp(12), dp(14), dp(12))
      background = roundedStrokeShape(Color.TRANSPARENT, withAlpha(textColor, 0.13f), dp(18), dp(1))
      setOnClickListener { openSharedItemInChat(item) }
    }
    row.addView(
      ImageView(context).apply {
        setImageResource(iconForType(item.type, item.section))
        setColorFilter(accentForSection(item.section), PorterDuff.Mode.SRC_IN)
        background = roundedShape(withAlpha(accentForSection(item.section), 0.10f), dp(15))
        setPadding(dp(8), dp(8), dp(8), dp(8))
      },
      LinearLayout.LayoutParams(dp(40), dp(40)),
    )
    val textStack = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(dp(12), 0, 0, 0)
    }
    textStack.addView(
      TextView(context).apply {
        text = item.title
        setTextColor(textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
      },
    )
    textStack.addView(
      TextView(context).apply {
        text = item.subtitle.ifBlank { "Open in chat" }
        setTextColor(secondaryTextColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        setPadding(0, dp(3), 0, 0)
      },
    )
    row.addView(textStack, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    return row
  }

  private fun toggleProfileVoice(item: ProfileSharedItem, button: TextView) {
    val current = profileVoicePlayer
    if (profileVoiceMessageId == item.messageId && current != null) {
      current.stop()
      current.release()
      profileVoicePlayer = null
      profileVoiceMessageId = null
      button.text = "Play"
      return
    }
    profileVoicePlayer?.release()
    profileVoicePlayer = null
    profileVoiceMessageId = null
    val source = item.mediaUrl.trim()
    if (source.isBlank()) {
      Toast.makeText(context, "Voice is not available", Toast.LENGTH_SHORT).show()
      return
    }
    try {
      val player = MediaPlayer()
      player.setDataSource(source)
      player.setOnPreparedListener {
        profileVoiceMessageId = item.messageId
        button.text = "Pause"
        it.start()
      }
      player.setOnCompletionListener {
        it.release()
        if (profileVoicePlayer === it) {
          profileVoicePlayer = null
          profileVoiceMessageId = null
          button.text = "Play"
        }
      }
      profileVoicePlayer = player
      player.prepareAsync()
    } catch (_: Throwable) {
      profileVoicePlayer?.release()
      profileVoicePlayer = null
      profileVoiceMessageId = null
      button.text = "Play"
      Toast.makeText(context, "Couldn't play voice", Toast.LENGTH_SHORT).show()
    }
  }

  private fun openSharedItemInChat(item: ProfileSharedItem) {
    onNativeEvent(
      mapOf(
        "type" to "profileSharedItemPressed",
        "section" to item.section,
        "chatId" to engineChatId,
        "messageId" to item.messageId,
      ),
    )
  }

  private fun copyPeerUserId() {
    val value = resolvedUserIdDisplay()
    if (value.isBlank()) return
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager)
      ?.setPrimaryClip(ClipData.newPlainText("Vibe user ID", value))
    Toast.makeText(context, "User ID copied", Toast.LENGTH_SHORT).show()
  }

  private fun resolvedUserIdDisplay(): String {
    val title = profileName.ifBlank { headerTitle }
    val handle =
      when {
        !isUuidLike(profileHandle) && profileHandle.isNotBlank() -> atHandle(profileHandle)
        title.isNotBlank() && !isUuidLike(title) -> atHandle(title)
        else -> ""
      }
    return handle
  }

  private fun atHandle(value: String): String {
    val compact =
      value.trim().trimStart('@')
        .lowercase(Locale.ROOT)
        .replace(Regex("[^a-z0-9_]+"), "")
    return if (compact.isBlank()) "" else "@$compact"
  }

  private fun isUuidLike(value: String): Boolean {
    val trimmed = value.trim()
    if (trimmed.length < 24) return false
    return trimmed.count { it == '-' } >= 3 && trimmed.all { it.isLetterOrDigit() || it == '-' }
  }

  private fun isSavedMessagesProfile(): Boolean {
    return engineChatId == "saved_messages"
  }

  private fun sectionTitle(section: String): String {
    return when (section) {
      "media" -> "Media"
      "audio" -> "Voice & Audio"
      "files" -> "Documents"
      "links" -> "Links"
      "pinned" -> "Pinned"
      else -> "Shared Content"
    }
  }

  private fun profileItemTitle(type: String, text: String, caption: String, fileName: String): String {
    val explicit = fileName.ifBlank { caption.ifBlank { text } }.trim()
    if (explicit.isNotBlank()) return explicit.take(80)
    return when (type) {
      "image", "gif" -> "Image"
      "video" -> "Video"
      "voice" -> "Voice message"
      "music", "audio" -> "Audio"
      "file", "document" -> "Document"
      else -> "Message"
    }
  }

  private fun profileItemSubtitle(type: String, mediaUrl: String, fileName: String): String {
    return when {
      fileName.isNotBlank() -> typeLabel(type)
      mediaUrl.isNotBlank() -> "Open in chat"
      else -> typeLabel(type)
    }
  }

  private fun linkTitle(text: String, caption: String): String {
    val candidate = LINK_REGEX.find(text)?.value ?: LINK_REGEX.find(caption)?.value.orEmpty()
    return candidate.ifBlank { "Link" }.take(80)
  }

  private fun typeLabel(type: String): String {
    return when (type) {
      "image", "gif" -> "Image"
      "video" -> "Video"
      "voice" -> "Voice"
      "music", "audio" -> "Audio"
      "file", "document" -> "Document"
      else -> "Open in chat"
    }
  }

  private fun iconForType(type: String, section: String): Int {
    return when {
      section == "links" -> R.drawable.ic_profile_links
      section == "pinned" -> R.drawable.ic_profile_pinned
      type == "voice" || type == "music" || type == "audio" -> R.drawable.ic_profile_audio
      type == "file" || type == "document" -> R.drawable.ic_profile_files
      else -> R.drawable.ic_profile_media
    }
  }

  private fun accentForSection(section: String): Int {
    return when (section) {
      "media" -> Color.parseColor("#EC4899")
      "audio" -> Color.parseColor("#10B981")
      "files" -> Color.parseColor("#6366F1")
      "links" -> Color.parseColor("#F59E0B")
      "pinned" -> Color.parseColor("#F97316")
      else -> Color.parseColor("#3B82F6")
    }
  }

  private fun resolveResolvedAvatarUri(): String {
    return resolveAvatarUri(
      context = context,
      rawAvatar = avatarUri,
      peerUserId = enginePeerUserIdRaw,
      preferPushAvatar = !isGroupOrChannel,
    ).orEmpty()
  }

  private fun updateAvatarViews() {
    val resolvedUri = resolveResolvedAvatarUri()
    if (resolvedUri.isBlank()) {
      avatarLoadCall?.cancel()
      avatarLoadCall = null
      avatarImage.setImageDrawable(null)
      avatarImage.visibility = View.GONE
      avatarFallback.visibility = View.VISIBLE
      return
    }

    val token = ++avatarLoadToken
    avatarLoadCall?.cancel()

    // Note: Assuming ChatPhoenixClient has buildPinnedHttpClient(), otherwise fall back
    val request = okhttp3.Request.Builder()
      .url(resolvedUri)
      .get()
      .header("Accept", "image/*,*/*;q=0.8")
      .header("ngrok-skip-browser-warning", "true")
      .build()

    val call = avatarHttpClient.newCall(request)
    avatarLoadCall = call
    call.enqueue(object : okhttp3.Callback {
      override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
        post {
          if (token != avatarLoadToken) return@post
          avatarImage.setImageDrawable(null)
          avatarImage.visibility = View.GONE
          avatarFallback.visibility = View.VISIBLE
        }
      }
      override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
        response.use { res ->
          if (!res.isSuccessful) {
            post {
              if (token != avatarLoadToken) return@post
              avatarImage.setImageDrawable(null)
              avatarImage.visibility = View.GONE
              avatarFallback.visibility = View.VISIBLE
            }
            return
          }
          val bytes = try {
            res.body?.bytes()
          } catch (_: Throwable) {
            null
          } ?: return
          val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return
          post {
            if (token != avatarLoadToken) return@post
            avatarImage.setImageBitmap(bitmap)
            avatarImage.visibility = View.VISIBLE
            avatarFallback.visibility = View.GONE
          }
        }
      }
    })
  }

  private fun updateProfileActionState() {
    if (isChatMuted) {
      muteAction.setIcon(android.R.drawable.ic_lock_silent_mode_off)
      muteAction.setTitle("Unmute")
    } else {
      muteAction.setIcon(android.R.drawable.ic_lock_silent_mode)
      muteAction.setTitle("Mute")
    }
  }

  private fun resolvedGroupMemberCount(): Int {
    val explicit = groupMemberCount ?: 0
    return if (explicit > 0) explicit else groupMemberOrder.toSet().size
  }

  private fun normalized(value: Any?): String? {
    return when (value) {
      is String -> value
      is Number -> value.toString()
      is Boolean -> value.toString()
      else -> null
    }
  }

  private fun containsProfileLink(text: String): Boolean {
    if (text.isBlank()) return false
    return LINK_REGEX.containsMatchIn(text)
  }

  private fun colorFromAny(raw: Any?): Int? {
    return when (raw) {
      is Int -> raw
      is Number -> raw.toInt()
      is String -> {
        val trimmed = raw.trim()
        if (trimmed.isBlank()) return null
        val hexFormat = if (trimmed.startsWith("#") && trimmed.length == 4) {
          "#" + trimmed[1] + trimmed[1] + trimmed[2] + trimmed[2] + trimmed[3] + trimmed[3]
        } else {
          trimmed
        }
        try {
          Color.parseColor(hexFormat)
        } catch (_: Throwable) {
          null
        }
      }
      else -> null
    }
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt().coerceIn(0, 255)
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun roundedShape(color: Int, radiusPx: Int) = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = radiusPx.toFloat()
    setColor(color)
  }

  private fun roundedStrokeShape(color: Int, strokeColor: Int, radiusPx: Int, strokeWidthPx: Int) =
    GradientDrawable().apply {
      shape = GradientDrawable.RECTANGLE
      cornerRadius = radiusPx.toFloat()
      setColor(color)
      setStroke(strokeWidthPx, strokeColor)
    }

  private fun statusBarHeightPx(): Int {
    val id = resources.getIdentifier("status_bar_height", "dimen", "android")
    return if (id > 0) resources.getDimensionPixelSize(id) else 0
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }

  private fun dpF(value: Float): Float {
    return value * resources.displayMetrics.density
  }

  private fun contrastForegroundFor(background: Int): Int {
    return if (calculateLuminance(background) > 0.5) Color.BLACK else Color.WHITE
  }

  private fun calculateLuminance(color: Int): Double {
    var r = Color.red(color) / 255.0
    var g = Color.green(color) / 255.0
    var b = Color.blue(color) / 255.0

    r = if (r <= 0.03928) r / 12.92 else Math.pow((r + 0.055) / 1.055, 2.4)
    g = if (g <= 0.03928) g / 12.92 else Math.pow((g + 0.055) / 1.055, 2.4)
    b = if (b <= 0.03928) b / 12.92 else Math.pow((b + 0.055) / 1.055, 2.4)

    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }
}
