import React, { useState, useEffect } from 'react'
import { View, Text, StyleSheet, Pressable, Modal, Dimensions, TouchableWithoutFeedback, Image } from 'react-native'
import { Audio } from 'expo-av'
import { useThemeStore } from '../../lib/stores/theme-store'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    withRepeat,
    withSequence,
    interpolate,
    FadeIn,
    FadeInDown,
    LinearTransition,
    Easing,
    cancelAnimation,
    runOnJS,
    withDelay,
} from 'react-native-reanimated'
import { LinearGradient } from 'expo-linear-gradient'
import MaskedView from '@react-native-masked-view/masked-view'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import { ChevronRightIcon, MicIcon, PlayIcon, PauseIcon, CheckIcon, SendIcon, WaveformIcon, TelegramIcon, InstagramIcon, GlobeIcon, GmailIcon, MessageCircleIcon } from '../Icons'
import { Gesture, GestureDetector } from 'react-native-gesture-handler'

// Platform icon mapper
const getPlatformIcon = (platform: string, size = 12, color: string) => {
    const p = platform.toLowerCase()
    if (p.includes('telegram')) return <TelegramIcon size={size} />
    if (p.includes('instagram')) return <InstagramIcon size={size} />
    if (p.includes('gmail') || p.includes('email')) return <GmailIcon size={size} />
    if (p.includes('web') || p.includes('whatsapp')) return <GlobeIcon size={size} color={color} />
    if (p.includes('sms') || p.includes('message')) return <MessageCircleIcon size={size} color={color} />
    return null
}

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window')
const MaskedViewAny = MaskedView as any
const AnimatedView = Animated.View as any

// Helper
const withAlpha = (hex: string, alpha: number): string => {
    if (!hex) return `rgba(128,128,128,${alpha})`
    if (hex.startsWith('#')) {
        const r = parseInt(hex.slice(1, 3), 16)
        const g = parseInt(hex.slice(3, 5), 16)
        const b = parseInt(hex.slice(5, 7), 16)
        return `rgba(${r},${g},${b},${alpha})`
    }
    return hex
}

// Progress Item Type
export interface ProgressItem {
    label: string
    badges: Array<{
        label?: string
        query?: string
        domain?: string
        sublabel?: string
        url?: string
        image?: string
    }>
    eventType?: 'progress' | 'result'
    data?: any
    // Message-specific fields
    recipient?: string
    platform?: string
    format?: 'text' | 'voice'
    messageContent?: string
    messagePreview?: string
    voiceUrl?: string
    voiceDuration?: number
    status?: 'preparing' | 'sending' | 'recording' | 'sent' | 'failed' | 'crawling' | 'extracting' | 'completed'
    isRecording?: boolean
    recordingStartTime?: number
    // Knowledge-specific fields
    tool?: string
    image?: string
    itemType?: string
    sourceUrl?: string
}

// Animated Voice Recording Icon with Waveform
// Animated Voice Recording Icon with Waveform
// Animated Voice Recording Icon with Waveform (Matches WaveformIcon style)
const VoiceRecordingIndicator = ({ color }: { color: string }) => {
    const sv1 = useSharedValue(0.4)
    const sv2 = useSharedValue(0.6)
    const sv3 = useSharedValue(0.5)
    const sv4 = useSharedValue(0.3)

    useEffect(() => {
        sv1.value = withRepeat(withSequence(withTiming(0.7, { duration: 300 }), withTiming(0.3, { duration: 300 })), -1, true)
        sv2.value = withRepeat(withSequence(withTiming(1, { duration: 400 }), withTiming(0.4, { duration: 400 })), -1, true)
        sv3.value = withRepeat(withSequence(withTiming(0.8, { duration: 350 }), withTiming(0.3, { duration: 350 })), -1, true)
        sv4.value = withRepeat(withSequence(withTiming(0.6, { duration: 450 }), withTiming(0.2, { duration: 450 })), -1, true)
    }, [])

    const style1 = useAnimatedStyle(() => ({ height: interpolate(sv1.value, [0, 1], [4, 12]) }))
    const style2 = useAnimatedStyle(() => ({ height: interpolate(sv2.value, [0, 1], [6, 16]) }))
    const style3 = useAnimatedStyle(() => ({ height: interpolate(sv3.value, [0, 1], [5, 14]) }))
    const style4 = useAnimatedStyle(() => ({ height: interpolate(sv4.value, [0, 1], [3, 10]) }))

    return (
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 2, height: 16, justifyContent: 'center' }}>
            <AnimatedView style={[{ width: 2, borderRadius: 1, backgroundColor: color }, style1]} />
            <AnimatedView style={[{ width: 2, borderRadius: 1, backgroundColor: color }, style2]} />
            <AnimatedView style={[{ width: 2, borderRadius: 1, backgroundColor: color }, style3]} />
            <AnimatedView style={[{ width: 2, borderRadius: 1, backgroundColor: color }, style4]} />
        </View>
    )
}

// Voice Player Component (no emojis, using icons)
const VoicePlayer = ({
    url,
    colors,
    isLight,
    duration: providedDuration
}: {
    url: string
    colors: any
    isLight: boolean
    duration?: number
}) => {
    const [sound, setSound] = useState<Audio.Sound | null>(null)
    const [isPlaying, setIsPlaying] = useState(false)
    const [duration, setDuration] = useState(providedDuration ? providedDuration * 1000 : 0)
    const [position, setPosition] = useState(0)

    useEffect(() => {
        return () => {
            if (sound) {
                sound.unloadAsync()
            }
        }
    }, [sound])

    const playPause = async () => {
        try {
            if (sound) {
                if (isPlaying) {
                    await sound.pauseAsync()
                    setIsPlaying(false)
                } else {
                    await sound.playAsync()
                    setIsPlaying(true)
                }
            } else {
                const { sound: newSound } = await Audio.Sound.createAsync(
                    { uri: url },
                    { shouldPlay: true },
                    (status) => {
                        if (status.isLoaded) {
                            setDuration(status.durationMillis || 0)
                            setPosition(status.positionMillis || 0)
                            if (status.didJustFinish) {
                                setIsPlaying(false)
                                setPosition(0)
                            }
                        }
                    }
                )
                setSound(newSound)
                setIsPlaying(true)
            }
        } catch (error) {
            console.error('Error playing voice:', error)
        }
    }

    const progress = duration > 0 ? (position / duration) * 100 : 0

    return (
        <View style={{
            flexDirection: 'row',
            alignItems: 'center',
            backgroundColor: withAlpha(colors.primary, 0.1),
            borderRadius: 20,
            padding: 8,
            marginTop: 8
        }}>
            <Pressable
                onPress={playPause}
                style={{
                    width: 36,
                    height: 36,
                    borderRadius: 18,
                    backgroundColor: colors.primary,
                    justifyContent: 'center',
                    alignItems: 'center'
                }}
            >
                {isPlaying ? (
                    <PauseIcon size={16} color="#fff" />
                ) : (
                    <PlayIcon size={16} color="#fff" />
                )}
            </Pressable>
            <View style={{ flex: 1, marginLeft: 12, marginRight: 8 }}>
                <View style={{
                    height: 4,
                    backgroundColor: withAlpha(colors.text, 0.1),
                    borderRadius: 2,
                    overflow: 'hidden'
                }}>
                    <View style={{
                        height: '100%',
                        width: `${progress}%`,
                        backgroundColor: colors.primary,
                        borderRadius: 2
                    }} />
                </View>
                <Text style={{
                    fontSize: 10,
                    color: withAlpha(colors.text, 0.5),
                    marginTop: 4
                }}>
                    {Math.floor(position / 1000)}s / {Math.floor(duration / 1000)}s
                </Text>
            </View>
        </View>
    )
}

export interface AgentLoaderProps {
    text?: string
    size?: number
    statusText?: string
    progressHistory?: ProgressItem[]
    isStreaming?: boolean
    isComplete?: boolean
    showProgress?: boolean
    style?: any
}

// Ultra Smooth Shimmer (Wide Gradient Sweep)
const ShimmeringText = ({
    text,
    color,
    style,
    isLight,
    icon
}: {
    text: string
    color: string
    style?: any
    isLight: boolean
    icon?: React.ReactNode
}) => {
    const shimmer = useSharedValue(0)

    useEffect(() => {
        shimmer.value = withRepeat(
            withTiming(1, { duration: 2000, easing: Easing.linear }),
            -1,
            false
        )
        return () => cancelAnimation(shimmer)
    }, [])

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [{
            translateX: interpolate(
                shimmer.value,
                [0, 1],
                [-400, 400]
            )
        }]
    }))

    const highlightColor = isLight ? 'rgba(0,0,0,0.8)' : 'rgba(255,255,255,0.9)'
    const baseColor = isLight ? 'rgba(0,0,0,0.3)' : 'rgba(255,255,255,0.3)'

    return (
        <View style={{ position: 'relative' }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                {icon}
                <Text style={[style, { color: baseColor }]} numberOfLines={1}>{text}</Text>
            </View>

            <MaskedViewAny
                style={StyleSheet.absoluteFill}
                maskElement={
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, flex: 1 }}>
                        {icon}
                        <Text style={[style, { backgroundColor: 'transparent' }]} numberOfLines={1}>{text}</Text>
                    </View>
                }
            >
                <AnimatedView style={[{ flex: 1, flexDirection: 'row' }, animatedStyle]}>
                    <LinearGradient
                        colors={[
                            'transparent',
                            highlightColor,
                            'transparent'
                        ]}
                        start={{ x: 0, y: 0 }}
                        end={{ x: 1, y: 0 }}
                        style={StyleSheet.absoluteFill}
                    />
                </AnimatedView>
            </MaskedViewAny>
        </View>
    )
}

// Pulsing Dot
const PulsingDot = ({ color }: { color: string }) => {
    const pulse = useSharedValue(0.4)
    useEffect(() => {
        pulse.value = withRepeat(
            withTiming(1, { duration: 1000 }),
            -1,
            true
        )
    }, [])
    const style = useAnimatedStyle(() => ({
        opacity: pulse.value,
        transform: [{ scale: interpolate(pulse.value, [0.4, 1], [0.8, 1.2]) }]
    }))
    return <AnimatedView style={[{ width: 5, height: 5, borderRadius: 4, backgroundColor: withAlpha(color, 0.8) }, style]} />
}

// Progress Modal
const ProgressModal = ({
    visible,
    onClose,
    progressHistory,
    colors,
    isLight,
}: {
    visible: boolean
    onClose: () => void
    progressHistory: ProgressItem[]
    colors: any
    isLight: boolean
}) => {
    const filteredHistory = progressHistory.filter(p => !p.label.toLowerCase().includes('understanding your request'))

    const itemHeight = 60
    const headerHeight = 80
    const footerPadding = 40
    const calculatedHeight = Math.min(
        headerHeight + (filteredHistory.length * itemHeight) + footerPadding,
        SCREEN_HEIGHT * 0.75
    ) || 200

    const translateY = useSharedValue(calculatedHeight)
    const backdrop = useSharedValue(0)
    const startY = useSharedValue(0)

    const onCloseJS = () => onClose()

    useEffect(() => {
        if (visible) {
            translateY.value = withTiming(0, { duration: 300, easing: Easing.out(Easing.cubic) })
            backdrop.value = withTiming(0.4, { duration: 250 })
        } else {
            translateY.value = withTiming(calculatedHeight, { duration: 250 })
            backdrop.value = withTiming(0, { duration: 200 })
        }
    }, [visible, calculatedHeight])

    const gesture = Gesture.Pan()
        .activeOffsetY([-10, 10])
        .onBegin(() => {
            startY.value = translateY.value
        })
        .onUpdate((e) => {
            const nextY = startY.value + e.translationY
            translateY.value = Math.max(0, Math.min(calculatedHeight, nextY))
        })
        .onEnd((e) => {
            if (translateY.value > 80 || e.velocityY > 800) {
                backdrop.value = withTiming(0, { duration: 200 })
                translateY.value = withTiming(calculatedHeight, { duration: 250 }, () => {
                    runOnJS(onCloseJS)()
                })
            } else {
                translateY.value = withTiming(0, { duration: 250 })
            }
        })

    const panelStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }]
    }))

    const overlayStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value
    }))

    const dimColor = isLight ? 'rgba(0,0,0,0.5)' : 'rgba(255,255,255,0.5)'
    const lineColor = isLight ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.1)'

    return (
        <Modal visible={visible} transparent animationType="none" onRequestClose={onCloseJS} statusBarTranslucent>
            {visible && (
                <AnimatedView
                    style={[styles.overlay, overlayStyle, { backgroundColor: isLight ? 'rgba(0,0,0,0.3)' : 'rgba(0,0,0,0.5)' }]}
                    pointerEvents={visible ? 'auto' : 'none'}
                >
                    <TouchableWithoutFeedback onPress={onCloseJS}>
                        <View style={StyleSheet.absoluteFill} />
                    </TouchableWithoutFeedback>
                </AnimatedView>
            )}

            <GestureDetector gesture={gesture}>
                <AnimatedView style={[styles.panelWrapper, panelStyle]} pointerEvents={visible ? 'auto' : 'none'}>
                    <SafeLiquidGlass
                        style={[styles.glassPanel, { minHeight: calculatedHeight }]}
                        interactive={false}
                        effect="regular"
                        tint={isLight ? 'light' : 'dark'}
                    >
                        <View style={styles.handleContainer}>
                            <View style={[styles.handle, { backgroundColor: lineColor }]} />
                        </View>

                        <View style={styles.modalHeader}>
                            <Text style={[styles.modalTitle, { color: colors.text }]}>Process Details</Text>
                        </View>

                        <View style={styles.timelineContainer}>
                            {filteredHistory.map((item, idx) => {
                                const isLast = idx === filteredHistory.length - 1
                                const isResult = item.eventType === 'result'
                                const isVoice = item.format === 'voice' || item.data?.format === 'voice'
                                const isSent = item.status === 'sent' || item.data?.status === 'sent'

                                return (
                                    <AnimatedView
                                        key={idx}
                                        entering={FadeInDown.delay(idx * 60).duration(500).easing(Easing.out(Easing.cubic))}
                                        style={styles.timelineRow}
                                    >
                                        <View style={styles.timelineLeft}>
                                            {!isLast && (
                                                <AnimatedView
                                                    entering={FadeIn.delay(idx * 60 + 300).duration(400)}
                                                    style={[styles.verticalLine, { backgroundColor: lineColor }]}
                                                />
                                            )}
                                            <View style={[
                                                styles.dot,
                                                { backgroundColor: isResult ? colors.text : dimColor, zIndex: 2 }
                                            ]} />
                                        </View>
                                        <View style={styles.timelineRight}>
                                            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                                                {/* Status Icon */}
                                                {isSent && <CheckIcon size={14} color="#22c55e" />}
                                                {isVoice && !isSent && <MicIcon size={14} color={colors.primary} />}

                                                <Text style={[styles.stepLabel, { color: isResult ? colors.text : dimColor, flex: 1 }]}>
                                                    {isVoice && item.status === 'sending' ? (
                                                        <Text>
                                                            Sending voice to <Text style={{ fontWeight: '600', color: colors.text }}>{item.recipient || item.data?.recipient || 'user'}</Text>
                                                        </Text>
                                                    ) : (
                                                        item.label
                                                    )}
                                                </Text>

                                                {/* INLINE Platform Icons */}
                                                {(item.platform || item.badges?.some(b => b.label?.toLowerCase() === 'telegram')) && (
                                                    <TelegramIcon size={14} />
                                                )}
                                                {(item.platform === 'instagram' || item.badges?.some(b => b.label?.toLowerCase() === 'instagram')) && (
                                                    <InstagramIcon size={14} />
                                                )}
                                            </View>

                                            {/* Enhanced Message Preview Card */}
                                            {(item.messageContent || item.data?.messageContent || item.data?.message) && (
                                                <View style={{
                                                    marginTop: 8,
                                                    padding: 12,
                                                    backgroundColor: withAlpha(colors.text, 0.04),
                                                    borderRadius: 12,
                                                    borderWidth: 1,
                                                    borderColor: withAlpha(colors.text, 0.06)
                                                }}>
                                                    <Text style={{
                                                        fontSize: 14,
                                                        color: colors.text,
                                                        lineHeight: 20,
                                                        fontStyle: 'italic'
                                                    }}>
                                                        "{item.messageContent || item.data?.messageContent || item.data?.message}"
                                                    </Text>

                                                    {/* Voice Player */}
                                                    {(item.voiceUrl || item.data?.voiceUrl) && (
                                                        <View style={{ marginTop: 8 }}>
                                                            <VoicePlayer
                                                                url={item.voiceUrl || item.data?.voiceUrl}
                                                                colors={colors}
                                                                isLight={isLight}
                                                                duration={item.voiceDuration || item.data?.voiceDuration}
                                                            />
                                                        </View>
                                                    )}
                                                </View>
                                            )}

                                            {/* Knowledge Items Grid - show images for extracted items */}
                                            {item.tool === 'analyze_website' && item.badges?.some(b => b.image) && (
                                                <View style={{
                                                    marginTop: 10,
                                                    flexDirection: 'row',
                                                    flexWrap: 'wrap',
                                                    gap: 8
                                                }}>
                                                    {item.badges.filter(b => b.image).slice(0, 4).map((badge, bi) => (
                                                        <View
                                                            key={bi}
                                                            style={{
                                                                width: 70,
                                                                backgroundColor: withAlpha(colors.text, 0.04),
                                                                borderRadius: 10,
                                                                overflow: 'hidden'
                                                            }}
                                                        >
                                                            <Image
                                                                source={{ uri: badge.image }}
                                                                style={{
                                                                    width: 70,
                                                                    height: 50,
                                                                    backgroundColor: withAlpha(colors.text, 0.1)
                                                                }}
                                                                resizeMode="cover"
                                                            />
                                                            <View style={{ padding: 6 }}>
                                                                <Text
                                                                    style={{ fontSize: 9, color: colors.text, fontWeight: '500' }}
                                                                    numberOfLines={2}
                                                                >
                                                                    {badge.label}
                                                                </Text>
                                                                {badge.sublabel && (
                                                                    <Text
                                                                        style={{ fontSize: 8, color: dimColor, marginTop: 2 }}
                                                                        numberOfLines={1}
                                                                    >
                                                                        {badge.sublabel}
                                                                    </Text>
                                                                )}
                                                            </View>
                                                        </View>
                                                    ))}
                                                </View>
                                            )}
                                        </View>
                                    </AnimatedView>
                                )
                            })}
                        </View>
                    </SafeLiquidGlass>
                </AnimatedView>
            </GestureDetector>
        </Modal >
    )
}

// Main AgentLoader Component
export const AgentLoader: React.FC<AgentLoaderProps> = ({
    text = 'Working...',
    statusText,
    progressHistory = [],
    isStreaming = false,
    isComplete = false,
    showProgress = true,
    style,
}) => {
    const { colors, effectiveTheme } = useThemeStore()
    const isLight = effectiveTheme === 'light'
    const [modalVisible, setModalVisible] = useState(false)
    const dimColor = isLight ? 'rgba(0,0,0,0.5)' : 'rgba(255,255,255,0.5)'
    const lineColor = isLight ? 'rgba(0,0,0,0.1)' : 'rgba(255,255,255,0.1)'

    // Filter out "Understanding your request"
    const filteredHistory = progressHistory.filter(p =>
        !p.label.toLowerCase().includes('understanding your request')
    )

    const totalSources = filteredHistory.reduce((acc, item) => {
        if (item.eventType === 'result' && item.badges?.length) {
            return acc + item.badges.length
        }
        return acc
    }, 0)

    // Get current step and check if it's a voice recording
    const currentItem = filteredHistory.length > 0 ? filteredHistory[filteredHistory.length - 1] : null
    const currentStep = currentItem?.label || (text && !text.toLowerCase().includes('understanding your request') ? text : 'Working...')
    const isVoiceRecording = currentItem?.isRecording || currentItem?.status === 'recording' || currentItem?.format === 'voice'

    const showShimmer = isStreaming && !isComplete
    const showSummary = !isStreaming && filteredHistory.length > 0 && showProgress
    const showInlineTimeline = isStreaming && filteredHistory.length > 0 && showProgress

    if (!showShimmer && !showSummary) return null

    return (
        <View style={[styles.container, style]}>
            {/* ===== STREAMING: Shimmer + Animated Inline Timeline ===== */}
            {showShimmer && (
                <View>
                    <ShimmeringText
                        text={currentStep}
                        color={colors.text}
                        isLight={isLight}
                        style={styles.shimmerText}
                        icon={isVoiceRecording ? <VoiceRecordingIndicator color={colors.text} /> : undefined}
                    />

                    {/* Recording Timer for Voice Messages */}


                    {/* Compact inline badges - with image support for knowledge items */}
                    {showInlineTimeline && filteredHistory.length > 0 && (
                        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginTop: 8 }}>
                            {filteredHistory.slice(-3).flatMap((item, idx) =>
                                (item.badges || []).slice(0, 4).map((b, bi) => {
                                    const badgeText = b.label || b.query || b.domain || ''
                                    const hasImage = !!b.image
                                    const isKnowledge = item.tool === 'analyze_website' || item.tool === 'search_knowledge'
                                    const platformIcon = !hasImage ? getPlatformIcon(badgeText, 12, dimColor) : null

                                    return (
                                        <View
                                            key={`${idx}-${bi}`}
                                            style={{
                                                flexDirection: 'row',
                                                alignItems: 'center',
                                                gap: 6,
                                                backgroundColor: withAlpha(colors.text, 0.06),
                                                paddingHorizontal: hasImage ? 4 : 8,
                                                paddingVertical: 4,
                                                borderRadius: hasImage ? 12 : 8,
                                                maxWidth: 150
                                            }}
                                        >
                                            {/* Image thumbnail for knowledge items */}
                                            {hasImage && (
                                                <Image
                                                    source={{ uri: b.image }}
                                                    style={{
                                                        width: 24,
                                                        height: 24,
                                                        borderRadius: 6,
                                                        backgroundColor: withAlpha(colors.text, 0.1)
                                                    }}
                                                    resizeMode="cover"
                                                />
                                            )}
                                            {/* Icon for non-image badges */}
                                            {!hasImage && isKnowledge && (
                                                <GlobeIcon size={12} color={dimColor} />
                                            )}
                                            {platformIcon}
                                            <Text
                                                style={{ fontSize: 11, color: dimColor, flexShrink: 1 }}
                                                numberOfLines={1}
                                            >
                                                {badgeText}
                                            </Text>
                                            {/* Sublabel */}
                                            {b.sublabel && (
                                                <Text style={{ fontSize: 9, color: withAlpha(dimColor, 0.6) }} numberOfLines={1}>
                                                    {b.sublabel}
                                                </Text>
                                            )}
                                        </View>
                                    )
                                })
                            )}
                        </View>
                    )}
                </View>
            )}

            {/* ===== COMPLETE: Summary Row ===== */}
            {showSummary && (
                <Pressable
                    onPress={() => setModalVisible(true)}
                    style={({ pressed }) => [
                        styles.summaryRow,
                        { opacity: pressed ? 0.6 : 1 }
                    ]}
                >
                    <View style={styles.summaryLeft}>
                        <Text style={[styles.summaryText, { color: dimColor }]}>
                            {totalSources > 0
                                ? `Reviewed ${totalSources} source${totalSources > 1 ? 's' : ''}`
                                : `${filteredHistory.length} step${filteredHistory.length > 1 ? 's' : ''} completed`
                            }
                        </Text>
                    </View>
                    <ChevronRightIcon size={14} color={dimColor} strokeWidth={2} />
                </Pressable>
            )}

            <ProgressModal
                visible={modalVisible}
                onClose={() => setModalVisible(false)}
                progressHistory={progressHistory}
                colors={colors}
                isLight={isLight}
            />
        </View>
    )
}

const styles = StyleSheet.create({
    container: { marginBottom: 4 },
    shimmerText: { fontSize: 12, fontWeight: '500', letterSpacing: -0.2 },
    summaryRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingVertical: 8 },
    summaryLeft: { flexDirection: 'row', alignItems: 'center', gap: 8 },
    summaryDot: { width: 6, height: 6, borderRadius: 3 },
    summaryText: { fontSize: 13, fontWeight: '500' },
    overlay: { ...StyleSheet.absoluteFillObject, zIndex: 999 },
    panelWrapper: { position: 'absolute', bottom: 0, left: 0, right: 0, zIndex: 1000 },
    glassPanel: { width: '100%', borderRadius: 29, overflow: 'hidden' },
    handleContainer: { alignItems: 'center', paddingTop: 12, paddingBottom: 8 },
    handle: { width: 36, height: 4, borderRadius: 2 },
    modalHeader: { paddingHorizontal: 20, paddingBottom: 12 },
    modalTitle: { fontSize: 17, fontWeight: '600', letterSpacing: -0.3 },
    timelineContainer: { paddingHorizontal: 20, paddingBottom: 30 },
    timelineRow: { flexDirection: 'row', minHeight: 16 },
    timelineLeft: { width: 20, alignItems: 'center', marginRight: 12 },
    timelineRight: { flex: 1, paddingBottom: 20 },
    verticalLine: { position: 'absolute', top: 12, bottom: -8, width: 1, left: 9.5 },
    dot: { width: 8, height: 8, borderRadius: 4, marginTop: 6 },
    stepLabel: { fontSize: 15, lineHeight: 20 },
    badgeRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginTop: 6 },
    badge: { paddingHorizontal: 8, paddingVertical: 4, borderRadius: 6 },
    badgeText: { fontSize: 12, fontWeight: '500' }
})
