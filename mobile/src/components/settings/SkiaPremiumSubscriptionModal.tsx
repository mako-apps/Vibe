import React, { useEffect, useState } from 'react'
import { View, Text, StyleSheet, Dimensions, TouchableOpacity, Alert, Modal, ScrollView, Platform } from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    withSpring,
    interpolate,
    SharedValue,
    Easing,
} from 'react-native-reanimated'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { useThemeStore } from '../../lib/stores/theme-store'
import { useSubscriptionStore } from '../../lib/stores/subscription-store'
import { X } from 'lucide-react-native'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import { apiClient } from '../../lib/api-client'
import * as WebBrowser from 'expo-web-browser'
import { SkiaAnimatedBackground } from '../native/SkiaAnimatedBackground'

const { width: SCREEN_WIDTH } = Dimensions.get('window')

// Accent colors for plans
const PLAN_COLORS = {
    silver: {
        glow: '#5EB1B2',
        cyan: '#2DD4BF',
        base: '#111827'
    },
    gold: {
        glow: '#D4A544',
        cyan: '#F59E0B',
        base: '#1A1A10'
    },
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
    userId: string
}

/**
 * Premium Subscription Modal using Skia Animated Background
 * Provides a luxurious, fluid background animation that adapts to the selected plan.
 */
export default function SkiaPremiumSubscriptionModal({ visible, onClose, userId }: SubscriptionModalProps) {
    const { colors, effectiveTheme } = useThemeStore()
    const { plans, userTier, setPlans, setSubscription, setUserTier } = useSubscriptionStore()
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

    const currentColors = PLAN_COLORS[selectedPlan]
    const features = selectedPlan === 'silver' ? SILVER_FEATURES : GOLD_FEATURES

    const silverPlan = plans.find(p => p.name.toLowerCase() === 'silver')
    const goldPlan = plans.find(p => p.name.toLowerCase() === 'gold')
    const currentPlanPrice = selectedPlan === 'silver'
        ? (silverPlan?.priceCents || 2000) / 100
        : (goldPlan?.priceCents || 4900) / 100
    const yearlyPrice = currentPlanPrice * 10

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
                <SkiaAnimatedBackground
                    baseColor={isLight ? '#F9FAFB' : currentColors.base}
                    glowColor={currentColors.glow}
                    cyanColor={currentColors.cyan}
                    backgroundColor={isLight ? '#FFFFFF' : '#000000'}
                />

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
                            <Text style={[styles.labelSmall, { color: currentColors.glow }]}>PREMIUM ACCESS</Text>
                            <Text style={[styles.title, { color: colors.text }]}>Experience the Edge.</Text>
                            <Text style={[styles.subtitle, { color: withAlpha(colors.text, 0.5) }]}>
                                Decentralized intelligence focused on your privacy.
                            </Text>
                        </View>

                        {/* Glass Plan Toggle */}
                        <View style={styles.toggleWrapper}>
                            <SafeLiquidGlass style={styles.tabContainer} blurIntensity={15} tint={isLight ? 'light' : 'dark'}>
                                <Animated.View
                                    style={[
                                        styles.tabIndicator,
                                        { backgroundColor: isLight ? 'rgba(0,0,0,0.04)' : 'rgba(255,255,255,0.06)' },
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
                                        { color: selectedPlan === 'silver' ? colors.text : withAlpha(colors.text, 0.5) }
                                    ]}>
                                        SILVER
                                    </Text>
                                </TouchableOpacity>
                                <TouchableOpacity
                                    activeOpacity={0.8}
                                    style={styles.tab}
                                    onPress={() => setSelectedPlan('gold')}
                                >
                                    <Text style={[
                                        styles.tabText,
                                        { color: selectedPlan === 'gold' ? colors.text : withAlpha(colors.text, 0.5) }
                                    ]}>
                                        GOLD
                                    </Text>
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        </View>

                        {/* Features Minimal List */}
                        <View style={styles.featuresContainer}>
                            {features.map((feature, index) => (
                                <View key={index} style={styles.featureRow}>
                                    <View style={[styles.featureDot, { backgroundColor: withAlpha(currentColors.glow, 0.6) }]} />
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
                                        { borderColor: billingCycle === 'monthly' ? withAlpha(currentColors.glow, 0.3) : 'transparent', borderWidth: 1 }
                                    ]}
                                    blurIntensity={billingCycle === 'monthly' ? 25 : 5}
                                    tint={isLight ? 'light' : 'dark'}
                                >
                                    <Text style={[styles.pricingLabel, { color: withAlpha(colors.text, 0.4) }]}>MONTHLY</Text>
                                    <Text style={[styles.pricingAmount, { color: colors.text }]}>${currentPlanPrice.toFixed(2)}</Text>
                                    <Text style={[styles.pricingPeriod, { color: withAlpha(colors.text, 0.3) }]}>recurring</Text>
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
                                        { borderColor: billingCycle === 'yearly' ? withAlpha(currentColors.glow, 0.3) : 'transparent', borderWidth: 1 }
                                    ]}
                                    blurIntensity={billingCycle === 'yearly' ? 25 : 5}
                                    tint={isLight ? 'light' : 'dark'}
                                >
                                    <View style={[styles.saveBadge, { backgroundColor: withAlpha(currentColors.glow, 0.1) }]}>
                                        <Text style={[styles.saveText, { color: currentColors.glow }]}>-20%</Text>
                                    </View>
                                    <Text style={[styles.pricingLabel, { color: withAlpha(colors.text, 0.4) }]}>ANNUAL</Text>
                                    <Text style={[styles.pricingAmount, { color: colors.text }]}>${yearlyPrice.toFixed(2)}</Text>
                                    <Text style={[styles.pricingPeriod, { color: withAlpha(colors.text, 0.3) }]}>${(yearlyPrice / 12).toFixed(2)}/mo</Text>
                                </SafeLiquidGlass>
                            </TouchableOpacity>
                        </View>
                    </View>
                </ScrollView>

                {/* Bottom Action Area */}
                <View style={[styles.bottomContainer, { paddingBottom: insets.bottom + 24 }]}>
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
                            {loading ? 'PROCESSING...' : isCurrentPlan ? 'MANAGE PLAN' : 'UPGRADE NOW'}
                        </Text>
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
        width: 40,
        height: 40,
        borderRadius: 20,
        alignItems: 'center',
        justifyContent: 'center',
    },
    restoreButton: {
        paddingHorizontal: 8,
    },
    restoreText: {
        fontSize: 10,
        fontWeight: '700',
        letterSpacing: 2,
    },
    scrollView: {
        flex: 1,
    },
    scrollContent: {
        paddingBottom: 40,
    },
    contentWrap: {
        paddingHorizontal: 32,
    },
    infoSection: {
        marginTop: 32,
        marginBottom: 40,
        alignItems: 'flex-start',
    },
    labelSmall: {
        fontSize: 10,
        fontWeight: '900',
        letterSpacing: 3,
        marginBottom: 16,
    },
    title: {
        fontSize: 38,
        fontWeight: '600',
        letterSpacing: -1.5,
        lineHeight: 42,
        marginBottom: 12,
    },
    subtitle: {
        fontSize: 15,
        lineHeight: 22,
        fontWeight: '400',
    },
    toggleWrapper: {
        marginBottom: 48,
    },
    tabContainer: {
        flexDirection: 'row',
        borderRadius: 12,
        padding: 4,
        height: 48,
        overflow: 'hidden',
    },
    tabIndicator: {
        position: 'absolute',
        top: 4,
        left: 4,
        width: (SCREEN_WIDTH - 64) / 2 - 4,
        height: 40,
        borderRadius: 10,
    },
    tab: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    tabText: {
        fontSize: 11,
        fontWeight: '800',
        letterSpacing: 2,
    },
    featuresContainer: {
        marginBottom: 48,
        gap: 14,
    },
    featureRow: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 14,
    },
    featureDot: {
        width: 3,
        height: 3,
        borderRadius: 1.5,
    },
    featureText: {
        fontSize: 13,
        fontWeight: '400',
        letterSpacing: 0.2,
    },
    pricingContainer: {
        flexDirection: 'row',
        gap: 16,
        height: 140,
    },
    pricingGlassWrap: {
        flex: 1,
    },
    pricingCard: {
        flex: 1,
        borderRadius: 20,
        padding: 16,
        justifyContent: 'center',
        overflow: 'hidden',
    },
    saveBadge: {
        position: 'absolute',
        top: 12,
        right: 12,
        paddingHorizontal: 6,
        paddingVertical: 2,
        borderRadius: 4,
    },
    saveText: {
        fontSize: 9,
        fontWeight: '900',
    },
    pricingLabel: {
        fontSize: 9,
        fontWeight: '800',
        letterSpacing: 1.5,
        marginBottom: 6,
    },
    pricingAmount: {
        fontSize: 26,
        fontWeight: '600',
        letterSpacing: -1,
    },
    pricingPeriod: {
        fontSize: 10,
        fontWeight: '500',
        marginTop: 4,
    },
    bottomContainer: {
        paddingHorizontal: 32,
    },
    ctaButton: {
        borderRadius: 16,
        height: 60,
        alignItems: 'center',
        justifyContent: 'center',
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 4 },
        shadowOpacity: 0.1,
        shadowRadius: 10,
    },
    ctaText: {
        fontSize: 14,
        fontWeight: '800',
        letterSpacing: 1.5,
    },
})
