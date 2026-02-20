import React from 'react'
import { View, StyleSheet } from 'react-native'
import { Award, Star, BadgeCheck, Check } from 'lucide-react-native'
import Animated, {
    useAnimatedStyle,
    withRepeat,
    withSequence,
    withTiming,
    useSharedValue,
} from 'react-native-reanimated'
import { UserTier } from '../../lib/stores/subscription-store'

interface BadgeIconProps {
    tier: UserTier
    size?: number
    showGlow?: boolean
    animated?: boolean
}

const BADGE_COLORS: Record<UserTier, string> = {
    free: 'transparent',
    bronze: '#CD7F32',
    silver: '#C0C0C0',
    gold: '#B8860B',
    verified: '#3897f0', // Instagram Blue
    admin: '#3897f0', // Instagram Blue
}

const GLOW_COLORS: Record<UserTier, string> = {
    free: 'transparent',
    bronze: 'rgba(205, 127, 50, 0.3)',
    silver: 'rgba(192, 192, 192, 0.3)',
    gold: 'rgba(184, 134, 11, 0.4)',
    verified: 'rgba(56, 151, 240, 0.4)',
    admin: 'rgba(56, 151, 240, 0.4)',
}

const BadgeContent = ({ tier, size, color }: { tier: UserTier; size: number; color: string }) => {
    // Premium tiers use BadgeCheck shape with a separate white checkmark on top
    const isPremium = tier === 'gold' || tier === 'verified' || tier === 'admin'

    if (isPremium) {
        return (
            <View style={{ alignItems: 'center', justifyContent: 'center' }}>
                <BadgeCheck
                    size={size}
                    color={color}
                    fill={color}
                    strokeWidth={1}
                />
                <View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }]}>
                    <Check
                        size={size * 0.45}
                        color="#fff"
                        strokeWidth={4}
                    />
                </View>
            </View>
        )
    }

    const Icon = tier === 'silver' ? Star : Award
    return (
        <Icon
            size={size}
            color={color}
            fill={color === 'transparent' ? 'transparent' : `${color}40`}
            strokeWidth={2}
        />
    )
}

export const BadgeIcon = ({
    tier,
    size = 20,
    showGlow = false,
    animated = false,
}: BadgeIconProps) => {
    const scale = useSharedValue(1)

    React.useEffect(() => {
        if (animated && tier !== 'free') {
            scale.value = withRepeat(
                withSequence(
                    withTiming(1.1, { duration: 1000 }),
                    withTiming(1, { duration: 1000 })
                ),
                -1,
                true
            )
        }
    }, [animated, tier])

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [{ scale: scale.value }],
    }))

    if (tier === 'free') return null

    const color = BADGE_COLORS[tier]

    return (
        <Animated.View style={[styles.container, animatedStyle]}>
            {showGlow && (
                <View
                    style={[
                        styles.glow,
                        {
                            backgroundColor: GLOW_COLORS[tier],
                            width: size * 2,
                            height: size * 2,
                            borderRadius: size,
                        },
                    ]}
                />
            )}
            <BadgeContent tier={tier} size={size} color={color} />
        </Animated.View>
    )
}

// Compact badge for inline display (next to username)
export const InlineBadge = ({ tier, size = 16 }: { tier: UserTier; size?: number }) => {
    if (tier === 'free') return null
    const color = BADGE_COLORS[tier]
    return (
        <View style={styles.inlineContainer}>
            <BadgeContent tier={tier} size={size} color={color} />
        </View>
    )
}

// Badge with background circle
export const CircleBadge = ({
    tier,
    size = 32,
    backgroundColor,
}: {
    tier: UserTier
    size?: number
    backgroundColor?: string
}) => {
    if (tier === 'free') return null

    const color = BADGE_COLORS[tier]
    const iconSize = size * 0.55

    return (
        <View
            style={[
                styles.circleBadge,
                {
                    width: size,
                    height: size,
                    borderRadius: size / 2,
                    backgroundColor: backgroundColor || `${color}15`,
                },
            ]}
        >
            <BadgeContent tier={tier} size={iconSize} color={color} />
        </View>
    )
}

const styles = StyleSheet.create({
    container: {
        alignItems: 'center',
        justifyContent: 'center',
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.15,
        shadowRadius: 4,
        elevation: 3,
    },
    glow: {
        position: 'absolute',
    },
    inlineContainer: {
        marginLeft: 6,
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 1 },
        shadowOpacity: 0.2,
        shadowRadius: 2,
        elevation: 2,
    },
    circleBadge: {
        alignItems: 'center',
        justifyContent: 'center',
    },
})

export default BadgeIcon
