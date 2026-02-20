import React, { useEffect, useState } from 'react'
import { View, Text, StyleSheet, Dimensions, Pressable, TouchableOpacity, Share, Alert } from 'react-native'
import * as Clipboard from 'expo-clipboard'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    runOnJS,
    Easing,
    SharedValue,
} from 'react-native-reanimated'
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler'
import MaskedView from '@react-native-masked-view/masked-view'
import { BlurView } from 'expo-blur'
import { LinearGradient } from 'expo-linear-gradient'
import { useThemeStore } from '../../lib/stores/theme-store'
import { useReferralStore, calculateBronzeProgress } from '../../lib/stores/referral-store'
import { X, Copy, Share2, Award, Users, Target, Check } from 'lucide-react-native'
import AnimatedGlassButton from '../native/AnimatedGlassButton'
import { apiClient } from '../../lib/api-client'

const MaskedViewAny = MaskedView as any
const AnimatedView = Animated.View as any
const GestureHandlerRootViewAny = GestureHandlerRootView as any
const { height: SCREEN_HEIGHT, width: SCREEN_WIDTH } = Dimensions.get('window')

const MODAL_HEIGHT = SCREEN_HEIGHT * 0.94
const OPEN_Y = 0
const CLOSED_Y = SCREEN_HEIGHT
const SMOOTH_TIMING = { duration: 400, easing: Easing.bezier(0.25, 0.1, 0.25, 1) }

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color
}

const BRONZE_COLOR = '#CD7F32'

interface ReferralContentProps {
    onClose: () => void
    userId: string
}

const ReferralContent = React.memo(({ onClose, userId }: ReferralContentProps) => {
    const { colors } = useThemeStore()
    const { stats, setStats, setLoading } = useReferralStore()
    const [copied, setCopied] = useState(false)
    const [loading, setLocalLoading] = useState(false)

    useEffect(() => {
        loadStats()
    }, [])

    const loadStats = async () => {
        setLocalLoading(true)
        setLoading(true)
        try {
            const statsRes = await apiClient.getReferralStats(userId)
            setStats(statsRes)
        } catch (e) {
            console.error('Failed to load referral stats', e)
        }
        setLoading(false)
        setLocalLoading(false)
    }

    const handleCopyCode = async () => {
        if (stats?.referralCode) {
            await Clipboard.setStringAsync(stats.referralCode)
            setCopied(true)
            setTimeout(() => setCopied(false), 2000)
        }
    }

    const handleShare = async () => {
        if (!stats?.referralCode) return

        try {
            await Share.share({
                message: `Join me on Vibe! Use my referral code: ${stats.referralCode}\n\nDownload: https://vibe.app/invite/${stats.referralCode}`,
            })
        } catch (e) {
            console.error('Share failed', e)
        }
    }

    const progress = stats ? calculateBronzeProgress(stats.verifiedCount, stats.bronzeThreshold) : { progress: 0, remaining: 4000, isComplete: false }

    return (
        <View style={{ paddingBottom: 40 }}>
            {/* Referral Code Card */}
            <View style={styles.sectionWrapper}>
                <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>YOUR REFERRAL CODE</Text>
                <View style={[styles.codeCard, { backgroundColor: colors.card }]}>
                    <View style={[styles.codeContainer, { backgroundColor: withAlpha(BRONZE_COLOR, 0.1), borderColor: withAlpha(BRONZE_COLOR, 0.3) }]}>
                        <Text style={[styles.codeText, { color: colors.text }]}>
                            {stats?.referralCode || '--------'}
                        </Text>
                    </View>

                    <View style={styles.codeActions}>
                        <TouchableOpacity
                            style={[styles.actionButton, { backgroundColor: withAlpha(colors.text, 0.05) }]}
                            onPress={handleCopyCode}
                        >
                            {copied ? (
                                <Check size={18} color="#22c55e" />
                            ) : (
                                <Copy size={18} color={colors.text} />
                            )}
                            <Text style={[styles.actionText, { color: copied ? '#22c55e' : colors.text }]}>
                                {copied ? 'Copied' : 'Copy'}
                            </Text>
                        </TouchableOpacity>

                        <TouchableOpacity
                            style={[styles.actionButton, { backgroundColor: BRONZE_COLOR }]}
                            onPress={handleShare}
                        >
                            <Share2 size={18} color="#fff" />
                            <Text style={[styles.actionText, { color: '#fff' }]}>Share</Text>
                        </TouchableOpacity>
                    </View>
                </View>
            </View>

            {/* Progress to Bronze */}
            <View style={styles.sectionWrapper}>
                <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>PROGRESS TO BRONZE</Text>
                <View style={[styles.progressCard, { backgroundColor: colors.card }]}>
                    <View style={styles.progressHeader}>
                        <View style={[styles.progressIconContainer, { backgroundColor: `${BRONZE_COLOR}20` }]}>
                            <Award size={28} color={BRONZE_COLOR} />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={[styles.progressTitle, { color: colors.text }]}>
                                {progress.isComplete ? 'Bronze Badge Earned!' : 'Earn Bronze Badge'}
                            </Text>
                            <Text style={[styles.progressSubtitle, { color: colors.textSecondary }]}>
                                {progress.isComplete
                                    ? 'You have earned the Bronze badge'
                                    : `Invite ${progress.remaining.toLocaleString()} more friends`}
                            </Text>
                        </View>
                    </View>

                    {/* Progress Bar */}
                    <View style={[styles.progressBarContainer, { backgroundColor: withAlpha(colors.text, 0.1) }]}>
                        <View
                            style={[
                                styles.progressBarFill,
                                {
                                    backgroundColor: BRONZE_COLOR,
                                    width: `${Math.min(100, progress.progress)}%`,
                                },
                            ]}
                        />
                    </View>

                    <View style={styles.progressStats}>
                        <Text style={[styles.progressCount, { color: BRONZE_COLOR }]}>
                            {stats?.verifiedCount?.toLocaleString() || 0}
                        </Text>
                        <Text style={[styles.progressTotal, { color: colors.textSecondary }]}>
                            / {stats?.bronzeThreshold?.toLocaleString() || 4000} referrals
                        </Text>
                    </View>
                </View>
            </View>

            {/* Stats */}
            <View style={styles.sectionWrapper}>
                <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>REFERRAL STATS</Text>
                <View style={[styles.statsGrid]}>
                    <View style={[styles.statCard, { backgroundColor: colors.card }]}>
                        <View style={[styles.statIconContainer, { backgroundColor: withAlpha('#22c55e', 0.1) }]}>
                            <Users size={20} color="#22c55e" />
                        </View>
                        <Text style={[styles.statValue, { color: colors.text }]}>
                            {stats?.verifiedCount?.toLocaleString() || 0}
                        </Text>
                        <Text style={[styles.statLabel, { color: colors.textSecondary }]}>Verified</Text>
                    </View>

                    <View style={[styles.statCard, { backgroundColor: colors.card }]}>
                        <View style={[styles.statIconContainer, { backgroundColor: withAlpha('#f59e0b', 0.1) }]}>
                            <Target size={20} color="#f59e0b" />
                        </View>
                        <Text style={[styles.statValue, { color: colors.text }]}>
                            {stats?.pendingCount?.toLocaleString() || 0}
                        </Text>
                        <Text style={[styles.statLabel, { color: colors.textSecondary }]}>Pending</Text>
                    </View>
                </View>
            </View>

            {/* How it works */}
            <View style={styles.sectionWrapper}>
                <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>HOW IT WORKS</Text>
                <View style={[styles.infoCard, { backgroundColor: colors.card }]}>
                    <View style={styles.infoRow}>
                        <View style={[styles.infoNumber, { backgroundColor: withAlpha(BRONZE_COLOR, 0.1) }]}>
                            <Text style={[styles.infoNumberText, { color: BRONZE_COLOR }]}>1</Text>
                        </View>
                        <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                            Share your referral code with friends
                        </Text>
                    </View>
                    <View style={styles.infoRow}>
                        <View style={[styles.infoNumber, { backgroundColor: withAlpha(BRONZE_COLOR, 0.1) }]}>
                            <Text style={[styles.infoNumberText, { color: BRONZE_COLOR }]}>2</Text>
                        </View>
                        <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                            They sign up and send their first message
                        </Text>
                    </View>
                    <View style={styles.infoRow}>
                        <View style={[styles.infoNumber, { backgroundColor: withAlpha(BRONZE_COLOR, 0.1) }]}>
                            <Text style={[styles.infoNumberText, { color: BRONZE_COLOR }]}>3</Text>
                        </View>
                        <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                            Reach 4,000 referrals to earn Bronze badge
                        </Text>
                    </View>
                </View>
            </View>
        </View>
    )
})

interface ReferralModalProps {
    visible: boolean
    onClose: () => void
    parentScale: SharedValue<number>
    userId: string
}

export default function ReferralModal({ visible, onClose, parentScale, userId }: ReferralModalProps) {
    const { colors, effectiveTheme } = useThemeStore()
    const isLight = effectiveTheme === 'light'
    const bgColor = isLight ? '#f5f5f5' : colors.background

    const translateY = useSharedValue(CLOSED_Y)
    const backdrop = useSharedValue(0)
    const startY = useSharedValue(OPEN_Y)
    const [mounted, setMounted] = useState(visible)

    useEffect(() => {
        if (visible) {
            setMounted(true)
            translateY.value = withTiming(OPEN_Y, { duration: 250 })
            backdrop.value = withTiming(1, { duration: 250 })
            parentScale.value = withTiming(0.92, SMOOTH_TIMING)
        } else {
            backdrop.value = withTiming(0, { duration: 200 })
            translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => {
                runOnJS(setMounted)(false)
                runOnJS(onClose)()
            })
            parentScale.value = withTiming(1, SMOOTH_TIMING)
        }
    }, [visible])

    const handleCloseInternal = () => {
        onClose()
    }

    const gesture = Gesture.Pan()
        .activeOffsetY([-10, 10])
        .onBegin(() => { startY.value = translateY.value })
        .onUpdate((e) => {
            const nextY = startY.value + e.translationY
            translateY.value = Math.max(OPEN_Y, Math.min(CLOSED_Y, nextY))
        })
        .onEnd((e) => {
            if (translateY.value > 120 || e.velocityY > 1000) {
                runOnJS(handleCloseInternal)()
            } else {
                translateY.value = withTiming(OPEN_Y, { duration: 250 })
            }
        })

    const panelStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }],
        opacity: backdrop.value,
        borderTopLeftRadius: 24,
        borderTopRightRadius: 24,
    }))

    const overlayStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value,
    }))

    const activeHeader = useSharedValue(0)

    if (!mounted) return null

    return (
        <GestureHandlerRootViewAny style={[StyleSheet.absoluteFill, { zIndex: 999 }]}>
            <View style={StyleSheet.absoluteFill}>
                <AnimatedView style={[styles.overlay, overlayStyle, { backgroundColor: 'rgba(0,0,0,0.3)' }]}>
                    <Pressable style={StyleSheet.absoluteFill} onPress={handleCloseInternal} />
                </AnimatedView>

                <GestureDetector gesture={gesture}>
                    <AnimatedView style={[styles.modalContainer, panelStyle, { backgroundColor: bgColor }]}>
                        {/* Header Blur */}
                        <View style={styles.headerBlur}>
                            <MaskedViewAny
                                style={StyleSheet.absoluteFill}
                                maskElement={
                                    <LinearGradient
                                        colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0.8)', 'rgba(0,0,0,0)']}
                                        locations={[0, 0.5, 1]}
                                        style={StyleSheet.absoluteFill}
                                    />
                                }
                            >
                                <View style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(bgColor, 0.95) }]} />
                                <BlurView style={StyleSheet.absoluteFill} intensity={12} tint={isLight ? 'light' : 'dark'} />
                            </MaskedViewAny>
                        </View>

                        {/* Title & Close */}
                        <View style={[styles.header, { position: 'absolute', top: 20, left: 0, right: 0, zIndex: 120, justifyContent: 'space-between', alignItems: 'center' }]}>
                            <View style={{ width: 40 }} />
                            <Text style={[styles.headerTitle, { color: colors.text }]}>Invite Friends</Text>
                            <AnimatedGlassButton
                                onPress={handleCloseInternal}
                                progress={activeHeader}
                                showPanelIcon={false}
                                effectiveTheme={effectiveTheme}
                                size={40}
                                homeIcon={<X size={20} color={colors.text} strokeWidth={2} />}
                                panelIcon={<View />}
                                homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                            />
                        </View>

                        <Animated.ScrollView
                            style={styles.scrollView}
                            contentContainerStyle={[styles.scrollContent, { paddingBottom: 100, paddingTop: 100 }]}
                            showsVerticalScrollIndicator={false}
                        >
                            <ReferralContent onClose={handleCloseInternal} userId={userId} />
                        </Animated.ScrollView>
                    </AnimatedView>
                </GestureDetector>
            </View>
        </GestureHandlerRootViewAny>
    )
}

const styles = StyleSheet.create({
    overlay: { ...StyleSheet.absoluteFillObject },
    modalContainer: { position: 'absolute', bottom: 0, left: 0, right: 0, height: MODAL_HEIGHT, overflow: 'hidden' },
    headerBlur: { position: 'absolute', top: 0, left: 0, right: 0, height: 60, zIndex: 5 },
    header: { flexDirection: 'row', paddingHorizontal: 20 },
    headerTitle: { fontSize: 17, fontWeight: '600' },
    scrollView: { flex: 1 },
    scrollContent: { flexGrow: 1, paddingHorizontal: 20 },
    sectionWrapper: { marginBottom: 24 },
    sectionHeader: { fontSize: 13, fontWeight: '600', marginBottom: 8, marginLeft: 16, opacity: 0.6, letterSpacing: 0.5, textTransform: 'uppercase' },

    // Code Card
    codeCard: { borderRadius: 16, padding: 20 },
    codeContainer: { borderRadius: 12, padding: 16, borderWidth: 2, borderStyle: 'dashed', alignItems: 'center', marginBottom: 16 },
    codeText: { fontSize: 28, fontWeight: '700', letterSpacing: 4 },
    codeActions: { flexDirection: 'row', gap: 12 },
    actionButton: { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', paddingVertical: 12, borderRadius: 10, gap: 8 },
    actionText: { fontSize: 15, fontWeight: '600' },

    // Progress Card
    progressCard: { borderRadius: 16, padding: 16 },
    progressHeader: { flexDirection: 'row', alignItems: 'center', marginBottom: 16 },
    progressIconContainer: { width: 56, height: 56, borderRadius: 14, alignItems: 'center', justifyContent: 'center', marginRight: 16 },
    progressTitle: { fontSize: 18, fontWeight: '600', marginBottom: 2 },
    progressSubtitle: { fontSize: 13 },
    progressBarContainer: { height: 8, borderRadius: 4, overflow: 'hidden', marginBottom: 12 },
    progressBarFill: { height: '100%', borderRadius: 4 },
    progressStats: { flexDirection: 'row', alignItems: 'baseline' },
    progressCount: { fontSize: 24, fontWeight: '700' },
    progressTotal: { fontSize: 14, marginLeft: 4 },

    // Stats Grid
    statsGrid: { flexDirection: 'row', gap: 12 },
    statCard: { flex: 1, borderRadius: 16, padding: 16, alignItems: 'center' },
    statIconContainer: { width: 40, height: 40, borderRadius: 10, alignItems: 'center', justifyContent: 'center', marginBottom: 8 },
    statValue: { fontSize: 24, fontWeight: '700', marginBottom: 2 },
    statLabel: { fontSize: 12 },

    // Info Card
    infoCard: { borderRadius: 16, padding: 16 },
    infoRow: { flexDirection: 'row', alignItems: 'center', marginBottom: 12 },
    infoNumber: { width: 28, height: 28, borderRadius: 14, alignItems: 'center', justifyContent: 'center', marginRight: 12 },
    infoNumberText: { fontSize: 14, fontWeight: '700' },
    infoText: { flex: 1, fontSize: 14 },
})
