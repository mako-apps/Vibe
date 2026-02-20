import React, { useEffect, useState } from 'react'
import { View, Text, StyleSheet, Dimensions, Pressable, TouchableOpacity, Alert, Image, Modal, ScrollView, Platform } from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    withSpring,
    runOnJS,
    Easing,
    SharedValue,
    interpolate,
} from 'react-native-reanimated'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { BlurView } from 'expo-blur'
import { useThemeStore } from '../../lib/stores/theme-store'
import { useSubscriptionStore, Plan } from '../../lib/stores/subscription-store'
import { X, Check, Sparkles, Zap, MessageSquare, Clock, Users, Shield, Headphones, Crown } from 'lucide-react-native'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import { SkiaAnimatedBackground } from '../native/SkiaAnimatedBackground'
import { apiClient } from '../../lib/api-client'
import * as WebBrowser from 'expo-web-browser'

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window')

// Accent colors for plans
const PLAN_COLORS = {
    silver: '#5EB1B2', // Teal accent (like Perplexity Pro)
    gold: '#D4A544',   // Gold accent (like Perplexity Max)
}

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

// Feature definitions for each plan
const SILVER_FEATURES = [
    'AI Agent for business messaging',
    'Auto-reply outside business hours',
    'Business profile badge',
    'Priority message delivery',
    'Advanced analytics',
    'Custom business hours',
]

const GOLD_FEATURES = [
    'Everything in Silver',
    'Unlimited AI conversations',
    'Advanced AI models',
    'Priority support',
    'Custom branding options',
    'API access',
    'Team collaboration tools',
]

interface SubscriptionModalProps {
    visible: boolean
    onClose: () => void
    parentScale: SharedValue<number>
    userId: string
}

export default function SubscriptionModal({ visible, onClose, parentScale, userId }: SubscriptionModalProps) {
    const { colors, effectiveTheme } = useThemeStore()
    const { plans, userTier, setPlans, setSubscription, setUserTier, currentSubscription } = useSubscriptionStore()
    const insets = useSafeAreaInsets()
    const isLight = effectiveTheme === 'light'

    const [selectedPlan, setSelectedPlan] = useState<'silver' | 'gold'>('silver')
    const [billingCycle, setBillingCycle] = useState<'monthly' | 'yearly'>('monthly')
    const [loading, setLoading] = useState(false)

    // Animation values
    const tabPosition = useSharedValue(0)
    const opacity = useSharedValue(0)

    useEffect(() => {
        if (visible) {
            loadData()
            opacity.value = withTiming(1, { duration: 500 })
        } else {
            opacity.value = 0
        }
    }, [visible])

    useEffect(() => {
        tabPosition.value = withTiming(selectedPlan === 'silver' ? 0 : 1, {
            duration: 400,
            easing: Easing.bezier(0.25, 0.1, 0.25, 1),
        })
    }, [selectedPlan])

    const loadData = async () => {
        try {
            const [plansRes, subRes] = await Promise.all([
                apiClient.getPlans(),
                apiClient.getSubscription(userId),
            ])
            if (plansRes.plans) setPlans(plansRes.plans)
            if (subRes.subscription) setSubscription(subRes.subscription)
            if (subRes.tier) setUserTier(subRes.tier)
        } catch (e) {
            console.error('Failed to load subscription data', e)
        }
    }

    const handleSubscribe = async () => {
        const plan = plans.find(p => p.name.toLowerCase() === selectedPlan)
        if (!plan) return

        try {
            setLoading(true)
            const { checkoutUrl } = await apiClient.createCheckout(userId, plan.id)
            if (checkoutUrl) {
                await WebBrowser.openBrowserAsync(checkoutUrl)
                setTimeout(loadData, 2000)
            }
        } catch (e: any) {
            Alert.alert('Error', e.message || 'Failed to start checkout')
        } finally {
            setLoading(false)
        }
    }

    const handleCancel = async () => {
        Alert.alert(
            'Cancel Subscription',
            'Are you sure you want to revert to the standard tier?',
            [
                { text: 'Keep Premium', style: 'cancel' },
                {
                    text: 'Cancel',
                    style: 'destructive',
                    onPress: async () => {
                        try {
                            setLoading(true)
                            await apiClient.cancelSubscription(userId)
                            await loadData()
                        } catch (e: any) {
                            Alert.alert('Error', e.message || 'Failed to cancel')
                        } finally {
                            setLoading(false)
                        }
                    },
                },
            ]
        )
    }

    const accentColor = selectedPlan === 'silver' ? PLAN_COLORS.silver : PLAN_COLORS.gold
    const features = selectedPlan === 'silver' ? SILVER_FEATURES : GOLD_FEATURES

    const silverPlan = plans.find(p => p.name.toLowerCase() === 'silver')
    const goldPlan = plans.find(p => p.name.toLowerCase() === 'gold')
    const currentPlanPrice = selectedPlan === 'silver'
        ? (silverPlan?.priceCents || 2000) / 100
        : (goldPlan?.priceCents || 4900) / 100
    const yearlyPrice = currentPlanPrice * 10
    const monthlySavings = currentPlanPrice * 2

    const tabIndicatorStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: interpolate(tabPosition.value, [0, 1], [0, (SCREEN_WIDTH - 64) / 2]) }],
    }))

    const isCurrentPlan = userTier === selectedPlan

    if (!visible) return null

    return (
        <Modal
            animationType="slide"
            transparent={true}
            visible={visible}
            onRequestClose={onClose}
        >
            <View style={styles.container}>
                {/* Dynamic Content Background with Skia Animated Background */}
                <View style={[StyleSheet.absoluteFill, { backgroundColor: isLight ? '#fdfdfd' : '#050505' }]}>
                    <SkiaAnimatedBackground
                        baseColor={isLight ? '#ffffff' : '#0a0a0a'}
                        glowColor={accentColor}
                        cyanColor={selectedPlan === 'silver' ? '#06b6d4' : '#ffcc33'}
                        backgroundColor={isLight ? '#fdfdfd' : '#050505'}
                    />
                    <BlurView
                        intensity={Platform.OS === 'ios' ? 20 : 40}
                        tint={isLight ? 'light' : 'dark'}
                        style={StyleSheet.absoluteFill}
                    />
                </View>

                {/* Header */}
                <View style={[styles.header, { paddingTop: insets.top + 12 }]}>
                    <TouchableOpacity
                        onPress={onClose}
                        style={styles.closeButton}
                    >
                        <X size={24} color={colors.text} strokeWidth={1.5} />
                    </TouchableOpacity>

                    <TouchableOpacity style={styles.restoreButton}>
                        <Text style={[styles.restoreText, { color: withAlpha(colors.text, 0.4) }]}>RESTORE</Text>
                    </TouchableOpacity>
                </View>

                <ScrollView
                    style={styles.scrollView}
                    contentContainerStyle={styles.scrollContent}
                    showsVerticalScrollIndicator={false}
                >
                    <View style={styles.contentWrap}>
                        {/* Minimalist Header Info */}
                        <View style={styles.infoSection}>
                            <Text style={[styles.labelSmall, { color: accentColor }]}>PREMIUM ACCESS</Text>
                            <Text style={[styles.title, { color: colors.text }]}>Unlock Vibe Gold.</Text>
                            <Text style={[styles.subtitle, { color: colors.textSecondary }]}>
                                The ultimate experience for power users.
                            </Text>
                        </View>

                        {/* Glass Plan Toggle */}
                        <View style={styles.toggleWrapper}>
                            <SafeLiquidGlass style={styles.tabContainer} blurIntensity={15} tint={isLight ? 'light' : 'dark'}>
                                <Animated.View
                                    style={[
                                        styles.tabIndicator,
                                        { backgroundColor: isLight ? 'rgba(0,0,0,0.03)' : 'rgba(255,255,255,0.05)' },
                                        tabIndicatorStyle
                                    ]}
                                />
                                <TouchableOpacity
                                    activeOpacity={0.8}
                                    style={styles.tab}
                                    onPress={() => setSelectedPlan('silver')}
                                >
                                    <Text style={[
                                        styles.tabText,
                                        { color: selectedPlan === 'silver' ? colors.text : withAlpha(colors.text, 0.4) }
                                    ]}>
                                        Silver
                                    </Text>
                                </TouchableOpacity>
                                <TouchableOpacity
                                    activeOpacity={0.8}
                                    style={styles.tab}
                                    onPress={() => setSelectedPlan('gold')}
                                >
                                    <Text style={[
                                        styles.tabText,
                                        { color: selectedPlan === 'gold' ? colors.text : withAlpha(colors.text, 0.4) }
                                    ]}>
                                        Gold
                                    </Text>
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        </View>

                        {/* Features Minimal List */}
                        <View style={styles.featuresContainer}>
                            {features.map((feature, index) => (
                                <View key={index} style={styles.featureRow}>
                                    <View style={[styles.featureDot, { backgroundColor: withAlpha(accentColor, 0.6) }]} />
                                    <Text style={[styles.featureText, { color: withAlpha(colors.text, 0.7) }]}>
                                        {feature}
                                    </Text>
                                </View>
                            ))}
                        </View>

                        {/* Pricing Selection */}
                        <View style={styles.pricingContainer}>
                            <TouchableOpacity
                                activeOpacity={0.9}
                                style={styles.pricingGlassWrap}
                                onPress={() => setBillingCycle('monthly')}
                            >
                                <SafeLiquidGlass
                                    style={[
                                        styles.pricingCard,
                                        { borderColor: billingCycle === 'monthly' ? withAlpha(accentColor, 0.2) : 'transparent', borderWidth: 1 }
                                    ]}
                                    blurIntensity={billingCycle === 'monthly' ? 20 : 5}
                                    tint={isLight ? 'light' : 'dark'}
                                >
                                    <Text style={[styles.pricingLabel, { color: withAlpha(colors.text, 0.4) }]}>Monthly</Text>
                                    <View style={{ flexDirection: 'row', alignItems: 'flex-end', gap: 4 }}>
                                        <Text style={[styles.pricingAmount, { color: colors.text }]}>${currentPlanPrice.toFixed(2)}</Text>
                                        <Text style={[styles.pricingPeriod, { color: withAlpha(colors.text, 0.4), marginBottom: 4 }]}>/mo</Text>
                                    </View>
                                </SafeLiquidGlass>
                            </TouchableOpacity>

                            <TouchableOpacity
                                activeOpacity={0.9}
                                style={styles.pricingGlassWrap}
                                onPress={() => setBillingCycle('yearly')}
                            >
                                <SafeLiquidGlass
                                    style={[
                                        styles.pricingCard,
                                        { borderColor: billingCycle === 'yearly' ? withAlpha(accentColor, 0.2) : 'transparent', borderWidth: 1 }
                                    ]}
                                    blurIntensity={billingCycle === 'yearly' ? 20 : 5}
                                    tint={isLight ? 'light' : 'dark'}
                                >
                                    <View style={[styles.saveBadge, { backgroundColor: withAlpha(accentColor, 0.1) }]}>
                                        <Text style={[styles.saveText, { color: accentColor }]}>Save 20%</Text>
                                    </View>
                                    <Text style={[styles.pricingLabel, { color: withAlpha(colors.text, 0.4) }]}>Yearly</Text>
                                    <View style={{ flexDirection: 'row', alignItems: 'flex-end', gap: 4 }}>
                                        <Text style={[styles.pricingAmount, { color: colors.text }]}>${(yearlyPrice / 12).toFixed(2)}</Text>
                                        <Text style={[styles.pricingPeriod, { color: withAlpha(colors.text, 0.4), marginBottom: 4 }]}>/mo</Text>
                                    </View>
                                    <Text style={[styles.billedText, { color: withAlpha(colors.text, 0.3) }]}>Billed ${yearlyPrice}</Text>
                                </SafeLiquidGlass>
                            </TouchableOpacity>
                        </View>
                    </View>
                </ScrollView>

                {/* Bottom Action Area */}
                <View style={[styles.bottomContainer, { paddingBottom: insets.bottom + 20 }]}>
                    <TouchableOpacity
                        activeOpacity={0.8}
                        style={[
                            styles.ctaButton,
                            {
                                backgroundColor: isCurrentPlan ? 'transparent' : colors.text,
                                borderWidth: isCurrentPlan ? 1 : 0,
                                borderColor: withAlpha(colors.text, 0.1)
                            }
                        ]}
                        onPress={isCurrentPlan ? handleCancel : handleSubscribe}
                        disabled={loading}
                    >
                        <Text style={[
                            styles.ctaText,
                            { color: isCurrentPlan ? colors.text : colors.background }
                        ]}>
                            {loading ? 'Processing...' : isCurrentPlan ? 'Manage Plan' : 'Subscribe Now'}
                        </Text>
                    </TouchableOpacity>

                    {/* Admin: Collect Gold Badge Button */}
                    <TouchableOpacity
                        style={{ marginTop: 16, alignSelf: 'center', opacity: 0.1 }}
                        onPress={() => {
                            Alert.alert("Admin Access", "Collect Gold Badge?", [
                                { text: "Cancel" },
                                {
                                    text: "Collect", onPress: () => {
                                        setUserTier('gold')
                                        Alert.alert("Success", "You now have the Gold Badge!")
                                    }
                                }
                            ])
                        }}
                    >
                        <Text style={{ color: colors.text, fontSize: 10, letterSpacing: 1 }}>ADMIN: COLLECT BADGE</Text>
                    </TouchableOpacity>
                </View>
            </View>
        </Modal>
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    header: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        paddingHorizontal: 24,
        zIndex: 10,
    },
    closeButton: {
        width: 36,
        height: 36,
        borderRadius: 18,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(0,0,0,0.03)'
    },
    restoreButton: {
        paddingHorizontal: 8,
    },
    restoreText: {
        fontSize: 10,
        fontWeight: '600',
        letterSpacing: 1,
    },
    scrollView: {
        flex: 1,
    },
    scrollContent: {
        paddingBottom: 40,
    },
    contentWrap: {
        paddingHorizontal: 28,
    },
    infoSection: {
        marginTop: 24,
        marginBottom: 32,
        alignItems: 'flex-start',
    },
    labelSmall: {
        fontSize: 9,
        fontWeight: '800',
        letterSpacing: 2,
        marginBottom: 12,
        opacity: 0.9,
    },
    title: {
        fontSize: 32,
        fontWeight: '500',
        letterSpacing: -1,
        lineHeight: 38,
        marginBottom: 8,
    },
    subtitle: {
        fontSize: 14,
        lineHeight: 20,
        fontWeight: '400',
        opacity: 0.6,
    },
    toggleWrapper: {
        marginBottom: 40,
    },
    tabContainer: {
        flexDirection: 'row',
        borderRadius: 12,
        padding: 4,
        height: 44,
        overflow: 'hidden',
    },
    tabIndicator: {
        position: 'absolute',
        top: 4,
        left: 4,
        width: (SCREEN_WIDTH - 56) / 2 - 4, // Adjusted for padding
        height: 36,
        borderRadius: 8,
    },
    tab: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    tabText: {
        fontSize: 13,
        fontWeight: '500',
    },
    featuresContainer: {
        marginBottom: 40,
        gap: 12,
    },
    featureRow: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12,
    },
    featureDot: {
        width: 4,
        height: 4,
        borderRadius: 2,
    },
    featureText: {
        fontSize: 13,
        fontWeight: '400',
        letterSpacing: 0.1,
    },
    pricingContainer: {
        flexDirection: 'row',
        gap: 12,
        height: 120, // Reduced height
    },
    pricingGlassWrap: {
        flex: 1,
    },
    pricingCard: {
        flex: 1,
        borderRadius: 16,
        padding: 16,
        justifyContent: 'center',
        overflow: 'hidden',
    },
    saveBadge: {
        position: 'absolute',
        top: 10,
        right: 10,
        paddingHorizontal: 8,
        paddingVertical: 3,
        borderRadius: 6,
    },
    saveText: {
        fontSize: 9,
        fontWeight: '700',
    },
    pricingLabel: {
        fontSize: 13,
        fontWeight: '500',
        marginBottom: 4,
    },
    pricingAmount: {
        fontSize: 22,
        fontWeight: '600',
        letterSpacing: -0.5,
    },
    pricingPeriod: {
        fontSize: 12,
        fontWeight: '400',
    },
    billedText: {
        fontSize: 10,
        marginTop: 4,
    },
    bottomContainer: {
        paddingHorizontal: 28,
    },
    ctaButton: {
        borderRadius: 14,
        height: 52,
        alignItems: 'center',
        justifyContent: 'center',
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.05,
        shadowRadius: 8,
    },
    ctaText: {
        fontSize: 14,
        fontWeight: '600',
        letterSpacing: 0.5,
    },
})


