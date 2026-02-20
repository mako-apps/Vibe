import React, { useRef, useCallback, useState } from 'react'
import {
    View,
    TextInput as RNTextInput,
    Pressable,
    StyleSheet,
    Keyboard,
    ActivityIndicator,
    Text,
} from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    interpolate,
    SharedValue,
} from 'react-native-reanimated'
import { ArrowRight } from 'lucide-react-native'
import { SendFilledIcon } from '../Icons'

const AnimatedView = Animated.View as any
const AnimatedTextInput = Animated.createAnimatedComponent(RNTextInput)

import { useThemeStore } from '../../lib/stores/theme-store'
import { theme } from '../../lib/theme'
import { useHaptics } from '../../lib/hooks/useHaptics'
import { spacing } from '../../lib/theme'
import SafeLiquidGlass from '../native/SafeLiquidGlass'

// Constants for sizing
const COLLAPSED_HEIGHT = 52
const EXPANDED_HEIGHT = 100
const NEXT_BUTTON_WIDTH = 80

interface StoryInputProps {
    onSend: (prompt: string) => void
    onNext: () => void
    loading?: boolean
    placeholder?: string
    keyboardProgress?: SharedValue<number>
    isEditing?: boolean
}

const withAlpha = (color: string, alpha: number): string => {
    try {
        const a = Math.max(0, Math.min(1, alpha))
        if (/^rgba\(/i.test(color)) {
            return color.replace(/rgba\((\s*\d+\s*,\s*\d+\s*,\s*\d+)\s*,\s*[\d.]+\s*\)/i, `rgba($1, ${a})`)
        }
        if (color.startsWith('#')) {
            const hex = color.replace('#', '')
            const r = parseInt(hex.substring(0, 2), 16)
            const g = parseInt(hex.substring(2, 4), 16)
            const b = parseInt(hex.substring(4, 6), 16)
            return `rgba(${r}, ${g}, ${b}, ${a})`
        }
    } catch { }
    return `rgba(255,255,255,${alpha})`
}

export default function StoryInput({
    onSend,
    onNext,
    loading = false,
    placeholder = "Ask AI to edit...",
    keyboardProgress,
}: StoryInputProps) {
    const [value, setValue] = useState('')
    const { colors, effectiveTheme } = useThemeStore()
    const haptics = useHaptics()
    const isLight = effectiveTheme === 'light'
    const inputRef = useRef<any>(null)

    // Fallback shared value if keyboardProgress not provided (safety)
    const fallbackProgress = useSharedValue(0)
    const expandProgress = keyboardProgress ?? fallbackProgress

    // Colors from theme
    const iconColor = withAlpha('#5A5A66', 0.6)
    const bubbleColor = colors.bubbleMe
    const bubbleAlpha = withAlpha(bubbleColor, 0.12)

    const handleSend = useCallback(() => {
        if (value.trim() && !loading) {
            onSend(value)
            setValue('')
            Keyboard.dismiss()
        }
    }, [value, loading, onSend])

    const handleNext = useCallback(() => {
        haptics.light()
        onNext()
    }, [haptics, onNext])

    const inputWrapperStyle = useAnimatedStyle(() => {
        // Now on the right, so use marginRight
        const right = interpolate(expandProgress.value, [0, 1], [NEXT_BUTTON_WIDTH + spacing.sm, 0])
        return {
            marginRight: right,
            marginLeft: 0,
        }
    })

    const inputContainerStyle = useAnimatedStyle(() => {
        const height = interpolate(expandProgress.value, [0, 1], [COLLAPSED_HEIGHT, EXPANDED_HEIGHT])
        return {
            height: height,
        }
    })

    const nextButtonStyle = useAnimatedStyle(() => {
        const opacity = interpolate(expandProgress.value, [0, 1], [1, 0])
        // Push to the RIGHT
        const translateX = interpolate(expandProgress.value, [0, 1], [0, 50])
        return {
            opacity,
            transform: [{ translateX }],
        }
    })

    const bottomControlsStyle = useAnimatedStyle(() => {
        const opacity = interpolate(expandProgress.value, [0, 1], [0, 1])
        const translateY = interpolate(expandProgress.value, [0, 1], [20, 0])
        return {
            opacity,
            transform: [{ translateY }],
            pointerEvents: expandProgress.value > 0.1 ? 'auto' : 'none',
        }
    })

    // Render content function
    const renderContent = () => (
        <View style={styles.glassContent}>
            {/* Text Input Row */}
            <View style={styles.inputContentWrapper}>
                <AnimatedTextInput
                    ref={inputRef}
                    style={[styles.input, { color: '#E8E6F0' }]}
                    placeholder={placeholder}
                    placeholderTextColor="#E8E6F0"
                    value={value}
                    onChangeText={setValue}
                    multiline
                    maxLength={500}
                    editable={!loading}
                    onSubmitEditing={handleSend}
                    blurOnSubmit={false}
                />
            </View>

            {/* Bottom Controls (Send Button) - visible when expanded */}
            <AnimatedView style={[styles.bottomControls, bottomControlsStyle]}>
                {/* Spacer */}
                <View style={{ flex: 1 }} />

                <Pressable
                    style={({ pressed }) => [
                        styles.sendButton,
                        { backgroundColor: value.trim() ? bubbleColor : 'transparent' },
                        { opacity: pressed ? 0.5 : 1, transform: [{ scale: pressed ? 0.95 : 1 }] }
                    ]}
                    onPress={handleSend}
                    disabled={loading || !value.trim()}
                >
                    {loading ? (
                        <ActivityIndicator size="small" color="#fff" />
                    ) : (
                        <SendFilledIcon size={18} color={value.trim() ? "#fff" : iconColor} />
                    )}
                </Pressable>
            </AnimatedView>
        </View>
    )

    return (
        <View style={styles.container}>
            <AnimatedView style={styles.inputRow}>
                {/* Main Input Container */}
                <AnimatedView style={[styles.inputWrapper, inputWrapperStyle]}>
                    <AnimatedView style={[styles.inputContainerResize, inputContainerStyle]}>
                        <SafeLiquidGlass style={styles.inputGlass} blurIntensity={10}>
                            {renderContent()}
                        </SafeLiquidGlass>
                    </AnimatedView>
                </AnimatedView>

                {/* Next Button (visible when collapsed) - On the Right */}
                <AnimatedView style={[styles.rightButtonWrapper, nextButtonStyle]}>
                    <SafeLiquidGlass style={styles.nextButtonGlass} blurIntensity={10} tintColor={bubbleAlpha}>
                        <Pressable
                            style={({ pressed }) => [
                                styles.nextButton,
                                { backgroundColor: withAlpha(colors.bubbleMe, 0.9) }
                            ]}
                            onPress={handleNext}
                        >
                            <Text style={[styles.nextText, { color: '#E8E6F0' }]}>Next</Text>
                            <ArrowRight size={18} color={'#E8E6F0'} strokeWidth={2} />
                        </Pressable>
                    </SafeLiquidGlass>
                </AnimatedView>
            </AnimatedView>
        </View>
    )
}

const styles = StyleSheet.create({
    container: {
        paddingHorizontal: 10,
        paddingBottom: 0,
        paddingTop: spacing.md,
    },
    inputRow: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    rightButtonWrapper: {
        position: 'absolute',
        right: 0,
        zIndex: 10,
        overflow: 'hidden',
    },
    nextButtonGlass: {
        width: NEXT_BUTTON_WIDTH,
        height: COLLAPSED_HEIGHT,
        borderRadius: 26,
        overflow: 'hidden',
    },
    nextButton: {
        width: NEXT_BUTTON_WIDTH,
        height: COLLAPSED_HEIGHT,
        borderRadius: 26,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 4,
    },
    nextText: {
        fontSize: 15,
        fontWeight: '600',
    },
    inputWrapper: {
        flex: 1,
        position: 'relative',
    },
    inputContainerResize: {
        flex: 1,
    },
    inputGlass: {
        flex: 1,
        borderRadius: 26,
        overflow: 'hidden',
    },
    glassContent: {
        flex: 1,
        flexDirection: 'column',
        justifyContent: 'flex-start',
    },
    inputContentWrapper: {
        flexDirection: 'row',
        alignItems: 'center',
        minHeight: COLLAPSED_HEIGHT,
    },
    input: {
        flex: 1,
        fontSize: 15,
        lineHeight: 20,
        paddingLeft: 18,
        paddingRight: 8,
        paddingVertical: 10,
        textAlignVertical: 'center',
    },
    bottomControls: {
        position: 'absolute',
        left: 12,
        right: 12,
        bottom: 8,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'flex-start',
        gap: 4,
    },
    sendButton: {
        width: 36,
        height: 36,
        borderRadius: 18,
        alignItems: 'center',
        justifyContent: 'center',
    },
})
