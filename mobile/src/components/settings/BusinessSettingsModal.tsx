import React, { useEffect, useState } from 'react'
import { View, Text, StyleSheet, Dimensions, Pressable, TouchableOpacity, TextInput, Switch, Alert } from 'react-native'
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
import { X, Briefcase, Clock, MessageSquare, Check, AlertCircle } from 'lucide-react-native'
import AnimatedGlassButton from '../native/AnimatedGlassButton'
import { apiClient } from '../../lib/api-client'

const MaskedViewAny = MaskedView as any
const AnimatedView = Animated.View as any
const GestureHandlerRootViewAny = GestureHandlerRootView as any
const { height: SCREEN_HEIGHT } = Dimensions.get('window')

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

interface BusinessSettings {
    businessProfileEnabled: boolean
    autoReplyEnabled: boolean
    autoReplyMessage: string
    businessHoursStart: string
    businessHoursEnd: string
}

interface BusinessContentProps {
    onClose: () => void
    userId: string
}

const BusinessContent = React.memo(({ onClose, userId }: BusinessContentProps) => {
    const { colors } = useThemeStore()
    const [loading, setLoading] = useState(false)
    const [hasAccess, setHasAccess] = useState(false)
    const [settings, setSettings] = useState<BusinessSettings>({
        businessProfileEnabled: false,
        autoReplyEnabled: false,
        autoReplyMessage: 'Thank you for your message. We will get back to you during business hours.',
        businessHoursStart: '09:00',
        businessHoursEnd: '17:00',
    })
    const [hasChanges, setHasChanges] = useState(false)

    useEffect(() => {
        loadSettings()
    }, [])

    const loadSettings = async () => {
        setLoading(true)
        try {
            const res = await apiClient.getBusinessSettings(userId)
            setHasAccess(res.hasAccess)
            if (res.settings) {
                setSettings({
                    businessProfileEnabled: res.settings.businessProfileEnabled || false,
                    autoReplyEnabled: res.settings.autoReplyEnabled || false,
                    autoReplyMessage: res.settings.autoReplyMessage || settings.autoReplyMessage,
                    businessHoursStart: res.settings.businessHoursStart || '09:00',
                    businessHoursEnd: res.settings.businessHoursEnd || '17:00',
                })
            }
        } catch (e) {
            console.error('Failed to load business settings', e)
        }
        setLoading(false)
    }

    const handleSave = async () => {
        if (!hasChanges) return

        setLoading(true)
        try {
            await apiClient.updateBusinessSettings(userId, settings)
            setHasChanges(false)
            Alert.alert('Success', 'Settings saved successfully')
        } catch (e: any) {
            Alert.alert('Error', e.message || 'Failed to save settings')
        }
        setLoading(false)
    }

    const updateSetting = <K extends keyof BusinessSettings>(key: K, value: BusinessSettings[K]) => {
        setSettings(prev => ({ ...prev, [key]: value }))
        setHasChanges(true)
    }

    if (!hasAccess) {
        return (
            <View style={{ paddingBottom: 40 }}>
                <View style={[styles.noAccessCard, { backgroundColor: colors.card }]}>
                    <View style={[styles.noAccessIcon, { backgroundColor: withAlpha('#f59e0b', 0.1) }]}>
                        <AlertCircle size={32} color="#f59e0b" />
                    </View>
                    <Text style={[styles.noAccessTitle, { color: colors.text }]}>Upgrade Required</Text>
                    <Text style={[styles.noAccessDesc, { color: colors.textSecondary }]}>
                        Business features are available for Silver and Gold subscribers. Upgrade your plan to access auto-reply and business hours settings.
                    </Text>
                    <TouchableOpacity
                        style={[styles.upgradeButton, { backgroundColor: colors.primary }]}
                        onPress={onClose}
                    >
                        <Text style={styles.upgradeButtonText}>View Plans</Text>
                    </TouchableOpacity>
                </View>
            </View>
        )
    }

    return (
        <View style={{ paddingBottom: 40 }}>
            {/* Business Profile Toggle */}
            <View style={styles.sectionWrapper}>
                <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>BUSINESS PROFILE</Text>
                <View style={[styles.sectionContainer, { backgroundColor: colors.card }]}>
                    <View style={styles.settingRow}>
                        <View style={[styles.settingIconContainer, { backgroundColor: withAlpha('#3b82f6', 0.1) }]}>
                            <Briefcase size={18} color="#3b82f6" />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={[styles.settingLabel, { color: colors.text }]}>Enable Business Mode</Text>
                            <Text style={[styles.settingDesc, { color: colors.textSecondary }]}>
                                Show business badge on your profile
                            </Text>
                        </View>
                        <Switch
                            value={settings.businessProfileEnabled}
                            onValueChange={(v) => updateSetting('businessProfileEnabled', v)}
                            trackColor={{ false: '#767577', true: colors.primary }}
                        />
                    </View>
                </View>
            </View>

            {/* Auto-Reply Settings */}
            <View style={styles.sectionWrapper}>
                <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>AUTO-REPLY</Text>
                <View style={[styles.sectionContainer, { backgroundColor: colors.card }]}>
                    <View style={styles.settingRow}>
                        <View style={[styles.settingIconContainer, { backgroundColor: withAlpha('#22c55e', 0.1) }]}>
                            <MessageSquare size={18} color="#22c55e" />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={[styles.settingLabel, { color: colors.text }]}>Enable Auto-Reply</Text>
                            <Text style={[styles.settingDesc, { color: colors.textSecondary }]}>
                                Automatically reply outside business hours
                            </Text>
                        </View>
                        <Switch
                            value={settings.autoReplyEnabled}
                            onValueChange={(v) => updateSetting('autoReplyEnabled', v)}
                            trackColor={{ false: '#767577', true: colors.primary }}
                        />
                    </View>
                </View>

                {settings.autoReplyEnabled && (
                    <View style={[styles.messageContainer, { backgroundColor: colors.card, marginTop: 12 }]}>
                        <Text style={[styles.messageLabel, { color: colors.textSecondary }]}>Auto-Reply Message</Text>
                        <TextInput
                            style={[styles.messageInput, { color: colors.text, backgroundColor: withAlpha(colors.text, 0.05) }]}
                            value={settings.autoReplyMessage}
                            onChangeText={(v) => updateSetting('autoReplyMessage', v)}
                            multiline
                            numberOfLines={4}
                            placeholder="Enter your auto-reply message..."
                            placeholderTextColor={colors.textTertiary}
                        />
                    </View>
                )}
            </View>

            {/* Business Hours */}
            <View style={styles.sectionWrapper}>
                <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>BUSINESS HOURS</Text>
                <View style={[styles.sectionContainer, { backgroundColor: colors.card }]}>
                    <View style={styles.settingRow}>
                        <View style={[styles.settingIconContainer, { backgroundColor: withAlpha('#8b5cf6', 0.1) }]}>
                            <Clock size={18} color="#8b5cf6" />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={[styles.settingLabel, { color: colors.text }]}>Start Time</Text>
                        </View>
                        <TouchableOpacity
                            style={[styles.timeButton, { backgroundColor: withAlpha(colors.text, 0.05) }]}
                        >
                            <Text style={[styles.timeText, { color: colors.text }]}>{settings.businessHoursStart}</Text>
                        </TouchableOpacity>
                    </View>

                    <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />

                    <View style={styles.settingRow}>
                        <View style={[styles.settingIconContainer, { backgroundColor: withAlpha('#8b5cf6', 0.1) }]}>
                            <Clock size={18} color="#8b5cf6" />
                        </View>
                        <View style={{ flex: 1 }}>
                            <Text style={[styles.settingLabel, { color: colors.text }]}>End Time</Text>
                        </View>
                        <TouchableOpacity
                            style={[styles.timeButton, { backgroundColor: withAlpha(colors.text, 0.05) }]}
                        >
                            <Text style={[styles.timeText, { color: colors.text }]}>{settings.businessHoursEnd}</Text>
                        </TouchableOpacity>
                    </View>
                </View>

                <Text style={[styles.hoursHint, { color: colors.textSecondary }]}>
                    Messages received outside these hours will trigger the auto-reply
                </Text>
            </View>

            {/* Save Button */}
            {hasChanges && (
                <View style={styles.sectionWrapper}>
                    <TouchableOpacity
                        style={[styles.saveButton, { backgroundColor: colors.primary, opacity: loading ? 0.6 : 1 }]}
                        onPress={handleSave}
                        disabled={loading}
                    >
                        <Check size={18} color="#fff" />
                        <Text style={styles.saveButtonText}>{loading ? 'Saving...' : 'Save Changes'}</Text>
                    </TouchableOpacity>
                </View>
            )}
        </View>
    )
})

interface BusinessSettingsModalProps {
    visible: boolean
    onClose: () => void
    parentScale: SharedValue<number>
    userId: string
}

export default function BusinessSettingsModal({ visible, onClose, parentScale, userId }: BusinessSettingsModalProps) {
    const { colors, effectiveTheme } = useThemeStore()
    const isLight = effectiveTheme === 'light'
    const bgColor = isLight ? '#f5f5f5' : colors.background

    const translateY = useSharedValue(CLOSED_Y)
    const backdrop = useSharedValue(0)
    const startY = useSharedValue(OPEN_Y)

    useEffect(() => {
        if (visible) {
            translateY.value = withTiming(OPEN_Y, { duration: 250 })
            backdrop.value = withTiming(1, { duration: 250 })
            parentScale.value = withTiming(0.92, SMOOTH_TIMING)
        }
    }, [visible])

    const handleCloseInternal = () => {
        backdrop.value = withTiming(0, { duration: 200 })
        translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => runOnJS(onClose)())
        parentScale.value = withTiming(1, SMOOTH_TIMING)
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
        borderTopLeftRadius: 24,
        borderTopRightRadius: 24,
    }))

    const overlayStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value,
    }))

    const activeHeader = useSharedValue(0)

    if (!visible) return null

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
                            <Text style={[styles.headerTitle, { color: colors.text }]}>Business Settings</Text>
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
                            keyboardShouldPersistTaps="handled"
                        >
                            <BusinessContent onClose={handleCloseInternal} userId={userId} />
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
    sectionContainer: { borderRadius: 16, overflow: 'hidden' },

    // Setting Row
    settingRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 12, paddingHorizontal: 16, minHeight: 52 },
    settingIconContainer: { width: 30, height: 30, borderRadius: 8, alignItems: 'center', justifyContent: 'center', marginRight: 14 },
    settingLabel: { fontSize: 16, fontWeight: '500' },
    settingDesc: { fontSize: 12, marginTop: 2 },
    divider: { height: 1, marginLeft: 56 },

    // Message Input
    messageContainer: { borderRadius: 16, padding: 16 },
    messageLabel: { fontSize: 13, fontWeight: '600', marginBottom: 8 },
    messageInput: { borderRadius: 10, padding: 12, fontSize: 15, minHeight: 100, textAlignVertical: 'top' },

    // Time Button
    timeButton: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: 8 },
    timeText: { fontSize: 15, fontWeight: '600' },

    // Hints
    hoursHint: { fontSize: 12, marginTop: 8, marginLeft: 16 },

    // Save Button
    saveButton: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', paddingVertical: 14, borderRadius: 12, gap: 8 },
    saveButtonText: { color: '#fff', fontSize: 16, fontWeight: '600' },

    // No Access
    noAccessCard: { borderRadius: 16, padding: 24, alignItems: 'center' },
    noAccessIcon: { width: 64, height: 64, borderRadius: 16, alignItems: 'center', justifyContent: 'center', marginBottom: 16 },
    noAccessTitle: { fontSize: 20, fontWeight: '600', marginBottom: 8 },
    noAccessDesc: { fontSize: 14, textAlign: 'center', lineHeight: 20, marginBottom: 20 },
    upgradeButton: { paddingHorizontal: 24, paddingVertical: 12, borderRadius: 10 },
    upgradeButtonText: { color: '#fff', fontSize: 15, fontWeight: '600' },
})
