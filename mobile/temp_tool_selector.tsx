import React, { useEffect } from 'react'
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  Dimensions,
  TouchableWithoutFeedback,
  Switch,
  ScrollView,
} from 'react-native'
import { Gesture, GestureDetector } from 'react-native-gesture-handler'
import AnimatedRN, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  withTiming,
  runOnJS,
} from 'react-native-reanimated'

const AnimatedView = AnimatedRN.View as any
import { useThemeStore } from '../../lib/stores/theme-store'
import {
  ImageIcon,
  FileTextIcon,
  CloseIcon,
  CheckIcon,
  VideoIcon,
  SearchIcon,
  GlobeIcon,
  PhoneIcon,
  DollarIcon,
  ZapIcon,
  SocialIcon,
  ContentIcon,
  AnalyticsIcon,
  StudioIcon,
} from '../ui/icons'
import { CameraIcon } from '../ui/icons'
import { Tool } from '../../lib/services/agent-service'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import * as ImagePicker from 'expo-image-picker'
import * as DocumentPicker from 'expo-document-picker'
import { Alert } from 'react-native'

const { height, width } = Dimensions.get('window')

const withAlpha = (color: string, alpha: number): string => {
  if (!color) return `rgba(255, 255, 255, ${alpha})`

  if (color.startsWith('rgba') || color.startsWith('hsla')) {
    return color.replace(/[\d.]+\)$/g, `${alpha})`)
  }

  if (color.startsWith('rgb')) {
    return color.replace('rgb', 'rgba').replace(')', `, ${alpha})`)
  }

  if (color.startsWith('#')) {
    const hex = color.replace('#', '')
    const r = parseInt(hex.substring(0, 2), 16)
    const g = parseInt(hex.substring(2, 4), 16)
    const b = parseInt(hex.substring(4, 6), 16)
    return `rgba(${r}, ${g}, ${b}, ${alpha})`
  }

  return `rgba(255, 255, 255, ${alpha})`
}

interface ToolSelectorProps {
  visible: boolean
  onClose: () => void
  onToolSelect: (tool: Tool) => void
  onImageSelect?: (uri: string) => void
  onDocumentSelect?: (uri: string, name: string) => void
  onCameraPress?: () => void
  isStudioMode?: boolean
  onToggleStudioMode?: (enabled: boolean) => void
}

export default function ToolSelector({
  visible,
  onClose,
  onToolSelect,
  onImageSelect,
  onDocumentSelect,
  onCameraPress,
  isStudioMode = false,
  onToggleStudioMode,
}: ToolSelectorProps) {
  const { colors, effectiveTheme } = useThemeStore()
  const isLight = effectiveTheme === 'light'
  const [selectedTools, setSelectedTools] = React.useState<Set<string>>(new Set())

  // Static tool configuration for immediate loading (no backend dependency)
  const tools: Tool[] = React.useMemo(() => [
    { id: 'web_search', name: 'Web Search', description: 'Search the web with AI', icon: 'search', category: 'data', type: 'text' },


    { id: 'content', name: 'Content Creator', description: 'Generate and edit content', icon: 'content', category: 'document', type: 'text' },

    { id: 'analytics', name: 'Analytics', description: 'Analyze data and insights', icon: 'analytics', category: 'data', type: 'text' },
    { id: 'marketplace_sell', name: 'Sell Item', description: 'List a product for sale', icon: 'finance', category: 'data', type: 'text' },
    { id: 'image_generation', name: 'Image Generator', description: 'Visualize anything', icon: 'image_generation', category: 'media', type: 'image', model: 'gemini-2.5-flash-image' },
    { id: 'video_generation', name: 'Video Generator', description: 'Create video content', icon: 'video_generation', category: 'media', type: 'video', model: 'veo-3.1' }
  ], [])

  const toggleTool = (toolId: string) => {
    setSelectedTools(prev => {
      const newSet = new Set(prev)
      if (newSet.has(toolId)) {
        newSet.delete(toolId)
      } else {
        newSet.add(toolId)
      }
      return newSet
    })
  }

  const handlePickImage = async () => {
    try {
      const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync()
      if (status !== 'granted') {
        Alert.alert('Permission Required', 'Please grant photo library access')
        return
      }

      const result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes: ImagePicker.MediaTypeOptions.Images,
        allowsEditing: true,
        quality: 0.8,
        base64: false,
      })

      if (!result.canceled && result.assets && result.assets.length > 0) {
        const asset = result.assets[0]
        onImageSelect?.(asset.uri)
        onClose()
      }
    } catch (error) {
      console.error('Failed to pick image:', error)
      Alert.alert('Error', 'Failed to pick image')
    }
  }

  const handlePickDocument = async () => {
    try {
      const result = await DocumentPicker.getDocumentAsync({
        type: '*/*',
        copyToCacheDirectory: true,
      })

      if (!result.canceled && result.assets && result.assets.length > 0) {
        const asset = result.assets[0]
        onDocumentSelect?.(asset.uri, asset.name)
        onClose()
      }
    } catch (error) {
      console.error('Failed to pick document:', error)
      Alert.alert('Error', 'Failed to pick document')
    }
  }

  const handleCameraPress = async () => {
    if (onCameraPress) {
      onCameraPress()
      onClose()
      return
    }

    try {
      const { status } = await ImagePicker.requestCameraPermissionsAsync()
      if (status !== 'granted') {
        Alert.alert('Permission Required', 'Please grant camera access')
        return
      }

      const result = await ImagePicker.launchCameraAsync({
        allowsEditing: true,
        quality: 0.8,
        base64: false,
      })

      if (!result.canceled && result.assets && result.assets.length > 0) {
        const asset = result.assets[0]
        onImageSelect?.(asset.uri)
        onClose()
      }
    } catch (error) {
      console.error('Failed to capture photo:', error)
      Alert.alert('Error', 'Failed to capture photo')
    }
  }

  const OPEN_Y = 0 // Panel at bottom edge
  const CLOSED_Y = height // Off-screen (below viewport)
  const translateY = useSharedValue(CLOSED_Y)
  const startY = useSharedValue(OPEN_Y)
  const backdrop = useSharedValue(0)
  const isDragging = useSharedValue(false)

  const sheetStyle = useAnimatedStyle(() => {
    return {
      transform: [{ translateY: translateY.value }],
    }
  })

  const overlayStyle = useAnimatedStyle(() => ({
    opacity: backdrop.value,
  }))

  const onCloseJS = () => onClose()

  const gesture = Gesture.Pan()
    .activeOffsetY([-10, 10])
    .onBegin(() => {
      isDragging.value = true
      startY.value = translateY.value
    })
    .onUpdate((e) => {
      // Only allow panel to move down (dismiss), not up
      const nextY = startY.value + e.translationY
      translateY.value = Math.max(OPEN_Y, Math.min(CLOSED_Y, nextY))
    })
    .onEnd((e) => {
      const currentY = translateY.value
      const shouldClose = currentY > 120 || e.velocityY > 1000

      if (shouldClose) {
        // Close the panel
        backdrop.value = withTiming(0, { duration: 200 })
        translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => {
          runOnJS(onCloseJS)()
        })
      } else {
        // Snap back to default position
        translateY.value = withTiming(OPEN_Y, { duration: 250 })
      }
      isDragging.value = false
    })

  useEffect(() => {
    if (visible) {
      // Use spring for snappier feel - animate immediately
      translateY.value = withSpring(OPEN_Y, { mass: 0.8, damping: 20, stiffness: 300 })
      backdrop.value = withTiming(0.5, { duration: 150 })
    } else {
      translateY.value = withSpring(CLOSED_Y, { mass: 0.8, damping: 25, stiffness: 350 })
      backdrop.value = withTiming(0, { duration: 150 })
    }
  }, [visible])

  const handleToolSelect = (tool: Tool) => {
    // For web_search, we toggle it. For other tools, we select and close.
    if (tool.id === 'web_search') {
      toggleTool(tool.id)
      onToolSelect(tool)
    } else {
      onToolSelect(tool)
      onClose()
    }
  }

  const getToolIcon = (iconName: string, toolType?: string, category?: string, toolId?: string) => {
    // Use consistent icon color
    const iconColor = isLight ? (colors.lime?.[11] || colors.primaryDark) : colors.text

    // Map based on tool ID first (most specific)
    // Web search
    if (toolId === 'web_search') {
      return <GlobeIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (toolId === 'image_generation' || (toolType === 'image' && toolId?.includes('image'))) {
      return <ImageIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (toolId === 'video_generation' || (toolType === 'video' && toolId?.includes('video'))) {
      return <VideoIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (toolId === 'social' || iconName === 'social') {
      return <SocialIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (toolId === 'voice' || iconName === 'phone' || iconName === 'voice') {
      return <PhoneIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (toolId === 'content' || iconName === 'content') {
      return <ContentIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (toolId === 'finance' || iconName === 'finance') {
      return <DollarIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (toolId === 'analytics' || iconName === 'analytics') {
      return <AnalyticsIcon size={18} color={iconColor} strokeWidth={1.5} />
    }

    // Fallback to type-based mapping
    if (toolType === 'image' || iconName === 'image' || iconName === 'image_generation' || iconName?.includes('image')) {
      return <ImageIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (toolType === 'video' || iconName === 'video' || iconName === 'video_generation' || iconName?.includes('video')) {
      return <VideoIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (category === 'document' || iconName === 'document') {
      return <FileTextIcon size={18} color={iconColor} strokeWidth={1.5} />
    }
    if (category === 'data' || iconName === 'search' || iconName === 'analytics') {
      return <SearchIcon size={18} color={iconColor} strokeWidth={1.5} />
    }

    // Default icon
    return <ZapIcon size={18} color={iconColor} strokeWidth={1.5} />
  }

  // Backdrop with soft off-color (not lime)
  const backdropColor = isLight
    ? 'rgba(0, 0, 0, 0.15)' // Soft dark for light mode
    : 'rgba(0, 0, 0, 0.4)'  // Soft dark for dark modeency
  const overlayBackgroundColor = isLight
    ? withAlpha(colors.primaryDeep || colors.text, 0.5) // Light theme: dark overlay
    : withAlpha(colors.primaryDeep || colors.text, 0.7) // Dark theme: darker overlay

  return (
    <>
      {/* Always render backdrop, control interaction via pointerEvents */}
      <AnimatedView
        style={[styles.overlay, overlayStyle, { backgroundColor: overlayBackgroundColor }]}
        pointerEvents={visible ? 'auto' : 'none'}
      >
        <TouchableWithoutFeedback onPress={onClose}>
          <View style={StyleSheet.absoluteFill} />
        </TouchableWithoutFeedback>
      </AnimatedView>

      <GestureDetector gesture={gesture}>
        <AnimatedView style={[styles.panelWrapper, sheetStyle]} pointerEvents={visible ? 'auto' : 'none'}>
          <SafeLiquidGlass
            style={styles.glassPanel}
            interactive={false}
            effect="regular"
            tint={isLight ? 'light' : 'dark'}
          >
            {/* Handle */}
            <View style={styles.handleContainer}>
              <View style={[styles.handle, { backgroundColor: withAlpha(colors.text, 0.1) }]} />
            </View>

            {/* Header */}
            <View style={styles.header}>
              <Text style={[styles.title, {
                color: colors.text,
                fontSize: 22
              }]}>
                Tools
              </Text>
            </View>

            {/* Upload Section with subtle text */}
            <View style={styles.uploadSection}>
              <Text style={[styles.uploadLimit, { color: withAlpha(colors.text, 0.4) }]}>
                3 uploads remaining today
              </Text>
              <View style={styles.uploadButtons}>
                <TouchableOpacity
                  style={[styles.uploadButton, { backgroundColor: withAlpha(colors.text, 0.05) }]}
                  onPress={handlePickImage}
                  activeOpacity={0.6}
                >
                  <ImageIcon size={20} color={colors.text} strokeWidth={1.5} />
                  <Text style={[styles.uploadButtonText, { color: colors.text }]}>
                    Image
                  </Text>
                </TouchableOpacity>

                <TouchableOpacity
                  style={[styles.uploadButton, { backgroundColor: withAlpha(colors.text, 0.05) }]}
                  onPress={handleCameraPress}
                  activeOpacity={0.6}
                >
                  <CameraIcon size={20} color={colors.text} strokeWidth={1.5} />
                  <Text style={[styles.uploadButtonText, { color: colors.text }]}>
                    Camera
                  </Text>
                </TouchableOpacity>

                <TouchableOpacity
                  style={[styles.uploadButton, { backgroundColor: withAlpha(colors.text, 0.05) }]}
                  onPress={handlePickDocument}
                  activeOpacity={0.6}
                >
                  <FileTextIcon size={20} color={colors.text} strokeWidth={1.5} />
                  <Text style={[styles.uploadButtonText, { color: colors.text }]}>
                    File
                  </Text>
                </TouchableOpacity>
              </View>

              {/* Studio Mode Toggle - Moved to bottom of files section */}
              <ScrollView
                style={styles.toolsList}
                contentContainerStyle={{ paddingBottom: 40, paddingTop: 20 }}
                showsVerticalScrollIndicator={false}
              >
                {/* Studio Mode Toggle */}
                <View style={[styles.toolToggleItem, { marginBottom: 16, paddingVertical: 12 }]}>
                  <View style={styles.toolInfo}>
                    <View style={styles.toolIconWrapper}>
                      <StudioIcon size={18} color={isLight ? (colors.lime?.[11] || colors.primaryDark) : colors.text} strokeWidth={1.5} />
                    </View>
                    <View style={styles.toolTextContent}>
                      <Text style={[styles.toolName, { color: colors.text }]} numberOfLines={1}>
                        Studio Mode
                      </Text>
                      <Text style={[styles.toolDesc, { color: withAlpha(colors.text, 0.5) }]} numberOfLines={1}>
                        Enhanced creative tools
                      </Text>
                    </View>
                  </View>
                  <Switch
                    value={isStudioMode}
                    onValueChange={(val) => {
                      onToggleStudioMode?.(val)
                    }}
                    trackColor={{
                      false: withAlpha(colors.text, 0.1),
                      true: colors.lime?.[6] || colors.primary
                    }}
                    thumbColor={colors.background}
                    ios_backgroundColor={withAlpha(colors.text, 0.1)}
                    style={{ transform: [{ scaleX: 0.85 }, { scaleY: 0.85 }] }}
                  />
                </View>

                {tools.length > 0 ? (
                  tools.map((tool, index) => {
                    const isSelected = selectedTools.has(tool.id)
                    const isWebSearch = tool.id === 'web_search'

                    return (
                      <View key={tool.id}>
                        <TouchableOpacity
                          style={styles.toolToggleItem}
                          onPress={() => {
                            handleToolSelect(tool)
                          }}
                          activeOpacity={0.6}
                        >
                          <View style={styles.toolInfo}>
                            <View style={styles.toolIconWrapper}>
                              {getToolIcon(tool.icon, tool.type, tool.category, tool.id)}
                            </View>
                            <View style={styles.toolTextContent}>
                              <Text style={[styles.toolName, { color: colors.text }]} numberOfLines={1}>
                                {tool.name}
                              </Text>
                              <Text style={[styles.toolDesc, { color: withAlpha(colors.text, 0.5) }]} numberOfLines={1}>
                                {tool.description}
                              </Text>
                            </View>
                          </View>
                          {isWebSearch ? (
                            <Switch
                              value={isSelected}
                              onValueChange={() => toggleTool(tool.id)}
                              trackColor={{
                                false: withAlpha(colors.text, 0.1),
                                true: colors.lime?.[6] || colors.primary
                              }}
                              thumbColor={colors.background}
                              ios_backgroundColor={withAlpha(colors.text, 0.1)}
                              style={{ transform: [{ scaleX: 0.85 }, { scaleY: 0.85 }] }}
                            />
                          ) : null}
                        </TouchableOpacity>
                        {index < tools.length - 1 && (
                          <View style={{ height: 0 }} />
                        )}
                      </View>
                    )
                  })
                ) : null}
              </ScrollView>
            </View>
          </SafeLiquidGlass>
        </AnimatedView>
      </GestureDetector>
    </>
  )
}

const styles = StyleSheet.create({
  overlay: {
    ...StyleSheet.absoluteFillObject,
    zIndex: 999,
  },
  panelWrapper: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    paddingHorizontal: 0,
    paddingBottom: 0,
    zIndex: 1000,
  },
  glassPanel: {
    width: '100%',
    height: height * 0.6,
    borderRadius: 29,
    overflow: 'hidden',
  },

  // Handle
  handleContainer: {
    alignItems: 'center',
    paddingTop: 15,
    paddingBottom: 6,
  },
  handle: {
    width: 36,
    height: 4,
    borderRadius: 2,
  },

  // Header
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 20,
    paddingTop: 8,
    paddingBottom: 16,
  },
  title: {
    fontSize: 20,
    fontWeight: '600',
    letterSpacing: -0.3,
  },
  studioToggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 12,
    marginTop: 4,
  },
  studioToggleInfo: {
    gap: 2,
  },
  studioToggleLabel: {
    fontSize: 14,
    fontWeight: '600',
  },
  studioToggleDesc: {
    fontSize: 11,
    fontWeight: '400',
  },

  // Upload Section
  uploadSection: {
    paddingHorizontal: 20,
    paddingBottom: 20,
    gap: 10,
  },
  uploadLimit: {
    fontSize: 12,
    fontWeight: '400',
    letterSpacing: -0.1,
  },
  uploadButtons: {
    flexDirection: 'row',
    gap: 8,
  },
  uploadButton: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    paddingVertical: 14,
    borderRadius: 12,
  },
  uploadButtonText: {
    fontSize: 14,
    fontWeight: '500',
    letterSpacing: -0.2,
  },

  // Content
  content: {
    flex: 1,
  },
  toolsList: {
    paddingHorizontal: 5,
  },

  // Tool Toggle Item
  toolToggleItem: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 12,
  },
  toolInfo: {
    flexDirection: 'row',
    alignItems: 'center',
    flex: 1,
    gap: 12,
  },
  toolIconWrapper: {
    width: 32,
    height: 32,
    alignItems: 'center',
    justifyContent: 'center',
  },
  toolTextContent: {
    flex: 1,
    gap: 2,
  },
  toolName: {
    fontSize: 14,
    fontWeight: '500',
    letterSpacing: -0.2,
  },
  toolDesc: {
    fontSize: 11,
    fontWeight: '400',
    letterSpacing: -0.1,
  },
  separator: {
    height: 1,
    marginLeft: 44,
  },
  checkmarkContainer: {
    width: 20,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
  },
})