import React from 'react'
import { View, Pressable, StyleSheet } from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    withTiming,
    interpolate,
    SharedValue
} from 'react-native-reanimated'
import { BlurView } from 'expo-blur'
import SafeLiquidGlass from './SafeLiquidGlass'

const AnimatedView = Animated.View as any

// Very smooth spring config - no bounce, buttery smooth
const SMOOTH_SPRING = { damping: 30, stiffness: 200, mass: 1 }
const QUICK_SPRING = { damping: 20, stiffness: 250, mass: 0.9 }

interface AnimatedGlassButtonProps {
    onPress: () => void
    homeIcon?: React.ReactNode
    panelIcon?: React.ReactNode
    showPanelIcon?: boolean
    progress?: SharedValue<number>
    panelBackgroundColor?: string
    homeBackgroundColor?: string
    effectiveTheme?: 'light' | 'dark'
    size?: number
    disabled?: boolean
    style?: any
}

export const AnimatedGlassButton = ({
    onPress,
    homeIcon,
    panelIcon,
    showPanelIcon = false,
    progress,
    panelBackgroundColor,
    homeBackgroundColor,
    effectiveTheme = 'light',
    size = 40,
    disabled = false,
    style
}: AnimatedGlassButtonProps) => {
    const pressScale = useSharedValue(1)
    const internalProgress = useSharedValue(showPanelIcon ? 1 : 0)

    // Use external progress if provided, otherwise internal
    const animProgress = progress || internalProgress

    const activePanelColor = useSharedValue(panelBackgroundColor || 'transparent')

    React.useEffect(() => {
        activePanelColor.value = panelBackgroundColor || 'transparent'
    }, [panelBackgroundColor])

    // If NO external progress, drive internal progress based on showPanelIcon
    React.useEffect(() => {
        if (!progress) {
            internalProgress.value = withTiming(showPanelIcon ? 1 : 0, { duration: 300 })
        }
    }, [showPanelIcon, progress])

    // Derived Animations based on Progress (0 -> 1)
    const buttonScaleStyle = useAnimatedStyle(() => {
        // More dramatic scale: 1.4 peak
        const scale = interpolate(animProgress.value, [0, 0.5, 1], [1, 1.4, 1])
        return {
            transform: [{ scale: pressScale.value * scale }]
        }
    })

    const maskOpacityStyle = useAnimatedStyle(() => {
        // Blur/Mask peaks at 0.5
        const opacity = interpolate(animProgress.value, [0, 0.5, 1], [0, 1, 0])
        return { opacity }
    })

    const bgStyle = useAnimatedStyle(() => {
        return {
            backgroundColor: animProgress.value > 0.5 ? activePanelColor.value : (homeBackgroundColor || 'transparent')
        }
    })

    const homeIconStyle = useAnimatedStyle(() => ({
        opacity: interpolate(animProgress.value, [0, 0.3], [1, 0])
    }))

    const panelIconStyle = useAnimatedStyle(() => ({
        opacity: interpolate(animProgress.value, [0.3, 0.8], [0, 1])
    }))

    // Theme-based mask color
    const maskColor = effectiveTheme === 'dark'
        ? 'rgba(30, 30, 35, 0.95)' // Darker, matching standard dark mode
        : 'rgba(255, 255, 255, 0.95)'

    const borderRadius = size / 2

    return (
        <AnimatedView style={[{ width: size, height: size, borderRadius }, buttonScaleStyle, bgStyle, style]}>
            <SafeLiquidGlass
                style={{
                    width: size,
                    height: size,
                    borderRadius,
                    overflow: 'hidden',
                }}
                // effect="regular" // removed as SafeLiquidGlass might not have this prop or it defaults
                blurIntensity={10}
            >
                <Pressable
                    onPress={disabled ? undefined : onPress}
                    onPressIn={() => {
                        if (!disabled) {
                            pressScale.value = withSpring(0.9, QUICK_SPRING)
                        }
                    }}
                    onPressOut={() => {
                        pressScale.value = withSpring(1, SMOOTH_SPRING)
                    }}
                    style={StyleSheet.absoluteFill}
                >
                    <View style={[styles.buttonContent, { borderRadius }]}>
                        {/* Icons Container */}
                        <View style={styles.iconContainer}>
                            <AnimatedView style={[styles.absoluteIcon, homeIconStyle]}>
                                {homeIcon}
                            </AnimatedView>
                            <AnimatedView style={[styles.absoluteIcon, panelIconStyle]}>
                                {panelIcon}
                            </AnimatedView>
                        </View>

                        {/* Blur overlay */}
                        <AnimatedView
                            style={[styles.blurOverlay, { borderRadius, backgroundColor: maskColor }, maskOpacityStyle]}
                            pointerEvents="none"
                        >
                            <BlurView
                                style={StyleSheet.absoluteFill}
                                intensity={60}
                                tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                            />
                        </AnimatedView>
                    </View>
                </Pressable>
            </SafeLiquidGlass>
        </AnimatedView>
    )
}

const styles = StyleSheet.create({
    buttonContent: {
        flex: 1,
        width: '100%',
        height: '100%',
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center',
    },
    iconContainer: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        width: '100%',
        height: '100%',
    },
    absoluteIcon: {
        position: 'absolute',
        alignItems: 'center',
        justifyContent: 'center',
    },
    blurOverlay: {
        ...StyleSheet.absoluteFillObject,
        overflow: 'hidden',
    }
})

export default AnimatedGlassButton
