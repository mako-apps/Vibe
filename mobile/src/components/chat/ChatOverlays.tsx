import React, { useEffect, useState } from 'react'
import { View, Text, StyleSheet, Pressable, Dimensions, TouchableOpacity } from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    withTiming,
    runOnJS
} from 'react-native-reanimated'
import MaskedView from '@react-native-masked-view/masked-view'
import { useThemeStore } from '../../lib/stores/theme-store'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import { DocumentIcon, EditIcon, CheckIcon, PauseIcon, CloseIcon } from '../Icons'
import { useHaptics } from '../../lib/hooks/useHaptics'

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window')
const MaskedViewAny = MaskedView as any
const AnimatedView = Animated.View as any

// RTL Helper
const isRTL = (text: string) => /[\u0591-\u07FF\uFB1D-\uFDFD\uFE70-\uFEFC]/.test(text)


// Helper to make color alpha
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

// ⚡ Glass Toast
export const GlassToast = ({
    visible,
    message = 'Copied to clipboard',
    onClose,
    topInset = 60
}: {
    visible: boolean,
    message?: string,
    onClose: () => void,
    topInset?: number
}) => {
    const { colors, effectiveTheme } = useThemeStore()
    const isLight = effectiveTheme === 'light'

    // Animation State
    const translateY = useSharedValue(-150) // Match SyncedHeader (Start from top -150)
    const [isRendered, setIsRendered] = useState(false)

    useEffect(() => {
        if (visible) {
            setIsRendered(true)
            requestAnimationFrame(() => {
                // Slide Down (Enter) - Exact match to SyncedHeader
                translateY.value = withSpring(0, {
                    duration: 270
                })
            })
            const timer = setTimeout(onClose, 2000)
            return () => clearTimeout(timer)
        } else {
            // Immediate cleanup
            runOnJS(setIsRendered)(false)
            translateY.value = -150 // Reset
        }
    }, [visible])

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }]
    }))

    if (!isRendered && !visible) return null

    return (
        <AnimatedView
            style={[
                styles.toastContainer,
                { top: topInset + 7, width: '70%', zIndex: 1000000 },
                animatedStyle
            ]}
            pointerEvents="none"
        >
            <SafeLiquidGlass
                style={{ width: '100%', height: '100%', borderRadius: 21, overflow: 'hidden' }}
                effect="regular"
            >
                <View style={[styles.toastContent, { justifyContent: 'center' }]}>

                    <Text style={[styles.toastText, { color: colors.text }]}>{message}</Text>
                </View>
            </SafeLiquidGlass>
        </AnimatedView>
    )
}

// ⚡ Message Context Menu - Clean modern design
export const MessageContextMenu = ({
    visible,
    onClose,
    onEdit,
    onCopy,
    isUser = true,
    targetLayout,
    content,
    targetY, // Added back to support simpler positioning if layout missing
}: {
    visible: boolean
    onClose: () => void
    onEdit?: () => void
    onCopy: () => void
    isUser?: boolean
    targetLayout?: { x: number, y: number, width: number, height: number }
    content?: string
    targetY?: number
}) => {
    const haptic = useHaptics()
    const { colors, effectiveTheme } = useThemeStore()
    const isLight = effectiveTheme === 'light'
    const isRtlText = isRTL(content || '')

    // Shared values
    const menuScale = useSharedValue(0.95)
    const menuOpacity = useSharedValue(0)
    const bubbleScale = useSharedValue(1)
    const backdropOpacity = useSharedValue(0)

    useEffect(() => {
        if (visible) {
            // Smooth timing only
            menuScale.value = withTiming(1, { duration: 200 })
            menuOpacity.value = withTiming(1, { duration: 200 })
            bubbleScale.value = withTiming(1.05, { duration: 200 })
            backdropOpacity.value = withTiming(1, { duration: 200 })
        } else {
            menuScale.value = withTiming(0.95, { duration: 150 })
            menuOpacity.value = withTiming(0, { duration: 150 })
            bubbleScale.value = withTiming(1, { duration: 150 })
            backdropOpacity.value = withTiming(0, { duration: 150 })
        }
    }, [visible])

    const menuAnimatedStyle = useAnimatedStyle(() => ({
        transform: [{ scale: menuScale.value }],
        opacity: menuOpacity.value
    }))

    const cloneAnimatedStyle = useAnimatedStyle(() => ({
        transform: [{ scale: bubbleScale.value }],
    }))

    const backdropStyle = useAnimatedStyle(() => ({
        opacity: backdropOpacity.value,
    }))

    // Calculate Position
    let menuTop = targetY ? targetY : SCREEN_HEIGHT / 2
    let menuLeft = (SCREEN_WIDTH - 180) / 2

    // Bubble Clone Layout
    if (targetLayout) {
        // Place menu slightly below the bubble
        menuTop = targetLayout.y + targetLayout.height + 6 // 6px gap

        // Align to right edge for user messages
        if (isUser) {
            menuLeft = targetLayout.x + targetLayout.width - 200 // Align right edge roughly
            // Ensure it doesn't go off screen left
            if (menuLeft < 16) menuLeft = SCREEN_WIDTH - 220 - 16
        } else {
            menuLeft = targetLayout.x
        }

        // Safety check for bottom of screen
        if (menuTop + 100 > SCREEN_HEIGHT) {
            // Flip to top if too close to bottom
            menuTop = targetLayout.y - 120
        }
    }

    if (!visible) return null

    return (
        <View style={[StyleSheet.absoluteFill, { zIndex: 9999 }]}>
            {/* Backdrop */}
            <Pressable style={StyleSheet.absoluteFill} onPress={onClose}>
                <AnimatedView
                    style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.25)' }, backdropStyle]}
                />
            </Pressable>

            {/* Highlighted Bubble Clone (The "Focus" Visual) */}
            {targetLayout && content && (
                <AnimatedView
                    style={[
                        {
                            position: 'absolute',
                            top: targetLayout.y,
                            left: targetLayout.x,
                            width: targetLayout.width,
                            height: targetLayout.height,
                            backgroundColor: colors.background, // Fixed: Opaque background
                            borderRadius: 18,
                            borderBottomRightRadius: 4,
                            zIndex: 10001, // Above backdrop
                            shadowColor: "#000",
                            shadowOffset: { width: 0, height: 4 },
                            shadowOpacity: 0.15,
                            shadowRadius: 12,
                            elevation: 10
                        },
                        cloneAnimatedStyle
                    ]}
                >
                    <View style={{
                        backgroundColor: withAlpha(colors.text, 0.06),
                        flex: 1,
                        paddingHorizontal: 16,
                        paddingVertical: 10,
                        borderRadius: 18,
                        borderBottomRightRadius: 4,
                    }}>
                        <Text style={{
                            fontSize: 16,
                            lineHeight: 24,
                            color: colors.text,
                            writingDirection: isRtlText ? 'rtl' : 'ltr',
                            textAlign: isRtlText ? 'right' : 'left'
                        }}>
                            {content}
                        </Text>
                    </View>
                </AnimatedView>
            )}

            {/* Menu Container */}
            <View
                style={[
                    StyleSheet.absoluteFill,
                    { zIndex: 10002 } // Above Clone
                ]}
                pointerEvents="box-none"
            >
                <AnimatedView
                    style={[
                        { position: 'absolute', top: menuTop, left: menuLeft },
                        menuAnimatedStyle
                    ]}
                >
                    <SafeLiquidGlass
                        style={{ borderRadius: 14, paddingVertical: 6, paddingHorizontal: 4 }}
                        interactive={true}
                        effect="regular"
                        tint={isLight ? 'light' : 'dark'}
                    >
                        {/* Copy Option */}
                        <TouchableOpacity
                            style={styles.menuItemClean}
                            onPress={() => { haptic.light(); onCopy(); onClose() }}
                        >
                            <DocumentIcon size={18} color={withAlpha(colors.text, 0.7)} strokeWidth={1.8} />
                            <Text style={[styles.menuTextClean, { color: withAlpha(colors.text, 0.85) }]}>Copy</Text>
                        </TouchableOpacity>

                        {/* Edit Option - Only for user */}
                        {onEdit && (
                            <TouchableOpacity
                                style={styles.menuItemClean}
                                onPress={() => { haptic.light(); onEdit(); onClose() }}
                            >
                                <EditIcon size={18} color={withAlpha(colors.text, 0.7)} strokeWidth={1.8} />
                                <Text style={[styles.menuTextClean, { color: withAlpha(colors.text, 0.85) }]}>Edit</Text>
                            </TouchableOpacity>
                        )}
                    </SafeLiquidGlass>
                </AnimatedView>
            </View>
        </View>
    )
}

// ⚡ Reusable Menu Overlay - For Telegram config, chat messages, history cards, etc.
// Use this component with different items for different contexts
export interface MenuOverlayItem {
    id: string
    label: string
    icon: React.ReactNode
    onPress: () => void
    destructive?: boolean
}

// Alias for backward compatibility
export type GlassMenuItem = MenuOverlayItem

export const MenuOverlay = ({
    visible,
    onClose,
    items,
    targetY,
}: {
    visible: boolean
    onClose: () => void
    items: MenuOverlayItem[]
    targetY?: number
}) => {
    const haptic = useHaptics()
    const { colors, effectiveTheme } = useThemeStore()
    const isLight = effectiveTheme === 'light'

    // Spring-based scale animation for smoother, more natural feel
    const scale = useSharedValue(0)
    const backdropOpacity = useSharedValue(0)

    useEffect(() => {
        if (visible) {
            // Spring animation for smooth organic bounce
            scale.value = withSpring(1, {
                mass: 0.8,
                damping: 15,
                stiffness: 200,
                overshootClamping: false
            })
            backdropOpacity.value = withTiming(1, { duration: 150 })
        } else {
            // Faster close with easing
            scale.value = withSpring(0, {
                mass: 0.6,
                damping: 20,
                stiffness: 300
            })
            backdropOpacity.value = withTiming(0, { duration: 100 })
        }
    }, [visible])

    // ONLY scale transform - NO opacity (preserves glass effect)
    const menuAnimatedStyle = useAnimatedStyle(() => ({
        transform: [{ scale: scale.value }],
    }))

    const backdropStyle = useAnimatedStyle(() => ({
        opacity: backdropOpacity.value,
    }))

    // Position menu close to touch point (minimal offset)
    const menuTop = targetY ? Math.min(Math.max(targetY - 60, 100), SCREEN_HEIGHT - 160) : SCREEN_HEIGHT / 2 - 60

    if (!visible) return null

    return (
        <View style={[StyleSheet.absoluteFill, { zIndex: 9999 }]}>
            {/* Backdrop */}
            <Pressable style={StyleSheet.absoluteFill} onPress={onClose}>
                <AnimatedView
                    style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.25)' }, backdropStyle]}
                />
            </Pressable>

            {/* Menu Container - Clean modern design */}
            <View
                style={[
                    StyleSheet.absoluteFill,
                    { justifyContent: 'flex-start', alignItems: 'center', zIndex: 10000 }
                ]}
                pointerEvents="box-none"
            >
                <AnimatedView
                    style={[
                        { position: 'absolute', top: menuTop, minWidth: 160 },
                        menuAnimatedStyle
                    ]}
                >
                    <SafeLiquidGlass
                        style={{ borderRadius: 14, paddingVertical: 6, paddingHorizontal: 4 }}
                        interactive={true}
                        effect="regular"
                        tint={isLight ? 'light' : 'dark'}
                    >
                        {items.map((item) => (
                            <TouchableOpacity
                                key={item.id}
                                style={styles.menuItemClean}
                                onPress={() => {
                                    haptic.light()
                                    item.onPress()
                                    onClose()
                                }}
                            >
                                {item.icon}
                                <Text style={[
                                    styles.menuTextClean,
                                    { color: item.destructive ? withAlpha(colors.text, 0.9) : withAlpha(colors.text, 0.85) }
                                ]}>
                                    {item.label}
                                </Text>
                            </TouchableOpacity>
                        ))}
                    </SafeLiquidGlass>
                </AnimatedView>
            </View>
        </View>
    )
}

// Alias for backward compatibility
export const GlassContextMenu = MenuOverlay

const styles = StyleSheet.create({
    toastContainer: {
        position: 'absolute',
        alignSelf: 'center',
        zIndex: 10000,
        height: 42,
        borderRadius: 21,
        overflow: 'hidden',
        // Shadow removed to match SyncedHeader clean look
    },
    toastGlass: {
        width: '100%',
        height: '100%',
        borderRadius: 21,
        overflow: 'hidden'
    },
    toastContent: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 18,
        gap: 8,
    },
    toastText: {
        fontSize: 14,
        fontWeight: '500',
    },
    // Clean modern menu item - no borders, alpha colors
    menuItemClean: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12,
        paddingVertical: 12,
        paddingHorizontal: 14,
        borderRadius: 10,
        // width: 220 - REMOVED FIXED WIDTH to allow container to control
    },
    menuTextClean: {
        fontSize: 16,
        fontWeight: '500',
        letterSpacing: 0.2,
    },
})

// ⚡ Telegram Context Menu
export const TelegramContextMenu = ({
    visible,
    onClose,
    onDeactivate,
    onDelete,
    targetY,
}: {
    visible: boolean
    onClose: () => void
    onDeactivate: () => void
    onDelete: () => void
    targetY?: number
}) => {
    const items = [
        {
            id: 'delete',
            label: 'Delete',
            icon: <CloseIcon size={18} color={undefined} strokeWidth={1.8} />,
            onPress: onDelete,
            destructive: true
        }
    ]

    return (
        <MenuOverlay
            visible={visible}
            onClose={onClose}
            items={items}
            targetY={targetY}
        />
    )
}
