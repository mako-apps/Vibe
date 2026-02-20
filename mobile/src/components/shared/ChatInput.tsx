import React, { useRef, useState, useEffect, useMemo } from 'react'
import {
    View,
    Text,
    TextInput,
    TouchableOpacity,
    Pressable,
    StyleSheet,
    Platform,
    Dimensions,
} from 'react-native'
import { useThemeStore } from '../../lib/stores/theme-store'
import { useHaptics } from '../../lib/hooks/useHaptics'
import { spacing, borderRadius } from '../../lib/theme'
import { ArrowUp } from 'lucide-react-native'
import {
    PlusIcon,
    SendIcon,
    StopIcon,
    EditIcon,
    CloseIcon,
    CheckIcon,
} from '../Icons'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import Reanimated, {
    useSharedValue,
    useAnimatedStyle,
    interpolate,
    SharedValue,
} from 'react-native-reanimated'

const { width: SCREEN_WIDTH } = Dimensions.get('window')

interface ChatInputProps {
    value: string
    onChangeText: (text: string) => void
    onSend: () => void
    placeholder?: string
    maxLength?: number
    disabled?: boolean
    multiline?: boolean
    onVoicePress?: () => void
    onWaveformPress?: () => void
    isStreaming?: boolean
    onStopStreaming?: () => void
    isEditing?: boolean
    editingLabel?: string
    onCancelEdit?: () => void
    keyboardProgress?: SharedValue<number>
    onAttachPress?: () => void
}

export default function ChatInput({
    value,
    onChangeText,
    onSend,
    placeholder = "Message Vibe...",
    maxLength = 1000,
    disabled = false,
    multiline = true,
    onVoicePress,
    onWaveformPress,
    isStreaming = false,
    onStopStreaming,
    isEditing = false,
    editingLabel = 'Editing message',
    onCancelEdit,
    keyboardProgress,
    onAttachPress,
}: ChatInputProps) {
    const { colors, effectiveTheme } = useThemeStore()
    const haptic = useHaptics()
    const isLight = effectiveTheme === 'light'

    const MAX_COMPOSER_HEIGHT = 160
    const MIN_COMPOSER_HEIGHT = 40

    const fallbackProgress = useSharedValue(1)
    const expandProgress = keyboardProgress ?? fallbackProgress

    const containerAnimatedStyle = useAnimatedStyle(() => ({
        transform: [{
            scale: interpolate(expandProgress.value, [0, 1], [0.98, 1])
        }]
    }))

    const withAlpha = (color: string, alpha: number) => {
        if (color.startsWith('#')) {
            const hex = color.replace('#', '')
            const r = parseInt(hex.substring(0, 2), 16)
            const g = parseInt(hex.substring(2, 4), 16)
            const b = parseInt(hex.substring(4, 6), 16)
            return `rgba(${r}, ${g}, ${b}, ${alpha})`
        }
        return color
    }

    const liquidTint = isLight ? withAlpha('#FFFFFF', 0.85) : withAlpha(colors.surface || '#121212', 0.75)
    const androidBg = isLight ? withAlpha('#FFFFFF', 0.95) : withAlpha(colors.surface || '#121212', 0.9)

    // Resolo design send button background
    const sendBtnBg = isStreaming
        ? withAlpha(colors.primary, 0.2)
        : (value.trim() ? colors.primary : withAlpha(colors.text, 0.1))

    return (
        <Reanimated.View style={[styles.container, containerAnimatedStyle]}>
            {Platform.OS === 'ios' ? (
                <SafeLiquidGlass
                    style={styles.glassWrapper}
                    interactive={true}
                    effect="regular"
                    tintColor={liquidTint}
                >
                    {renderContent()}
                </SafeLiquidGlass>
            ) : (
                <View style={[styles.androidWrapper, { backgroundColor: androidBg }]}>
                    {renderContent()}
                </View>
            )}
        </Reanimated.View>
    )

    function renderContent() {
        return (
            <View style={styles.contentContainer}>
                {/* Header Badges (Editing) */}
                {isEditing && (
                    <View style={styles.headerBadges}>
                        <View style={[styles.badge, { backgroundColor: withAlpha(colors.primary, 0.3) }]}>
                            <EditIcon size={12} color={colors.primary} />
                            <Text style={[styles.badgeText, { color: colors.primary }]}>{editingLabel}</Text>
                            <TouchableOpacity onPress={onCancelEdit} hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}>
                                <CloseIcon size={12} color={colors.primary} />
                            </TouchableOpacity>
                        </View>
                    </View>
                )}

                {/* Input Area */}
                <View style={styles.inputRow}>
                    <TextInput
                        style={[styles.input, { color: colors.text, maxHeight: MAX_COMPOSER_HEIGHT, minHeight: MIN_COMPOSER_HEIGHT }]}
                        value={value}
                        onChangeText={onChangeText}
                        placeholder={placeholder}
                        placeholderTextColor={withAlpha(colors.text, 0.5)}
                        multiline={multiline}
                        maxLength={maxLength}
                        editable={!disabled}
                    />
                </View>

                {/* Toolbar - Matches Resolo Layout */}
                <View style={styles.toolbar}>
                    <View style={styles.toolbarLeft}>
                        <TouchableOpacity
                            style={styles.iconBtn}
                            onPress={() => {
                                haptic.light()
                                onAttachPress?.()
                            }}
                        >
                            <PlusIcon size={24} color={colors.text} />
                        </TouchableOpacity>
                    </View>

                    <View style={styles.toolbarRight}>
                        <TouchableOpacity
                            style={[styles.sendBtn, { backgroundColor: sendBtnBg }]}
                            disabled={!value.trim() && !isStreaming}
                            onPress={() => {
                                if (isStreaming) {
                                    haptic.medium()
                                    onStopStreaming?.()
                                } else if (value.trim()) {
                                    haptic.success()
                                    onSend()
                                }
                            }}
                        >
                            {isStreaming ? (
                                <StopIcon size={16} color={colors.primary} />
                            ) : (
                                <ArrowUp size={18} color={value.trim() ? '#fff' : withAlpha(colors.text, 0.5)} strokeWidth={3} />
                            )}
                        </TouchableOpacity>
                    </View>
                </View>
            </View>
        )
    }
}

const styles = StyleSheet.create({
    container: {
        marginHorizontal: 16,
        marginBottom: Platform.OS === 'ios' ? 8 : 12,
    },
    glassWrapper: {
        borderRadius: 24,
        overflow: 'hidden',
        padding: 2,
    },
    androidWrapper: {
        borderRadius: 24,
        overflow: 'hidden',
    },
    contentContainer: {
        paddingHorizontal: 12,
        paddingTop: 8,
        paddingBottom: 6,
        gap: 4,
    },
    headerBadges: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: 8,
    },
    badge: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
        paddingHorizontal: 8,
        paddingVertical: 4,
        borderRadius: 100,
    },
    badgeText: {
        fontSize: 11,
        fontWeight: '600',
    },
    inputRow: {
        flexDirection: 'row',
        alignItems: 'flex-end',
    },
    input: {
        flex: 1,
        fontSize: 16,
        paddingTop: 6,
        paddingBottom: 6,
        fontWeight: '400',
    },
    toolbar: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        height: 36,
    },
    toolbarLeft: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    toolbarRight: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 10,
    },
    iconBtn: {
        width: 36,
        height: 36,
        justifyContent: 'center',
        alignItems: 'center',
    },
    sendBtn: {
        width: 38,
        height: 38,
        borderRadius: 19,
        justifyContent: 'center',
        alignItems: 'center',
    }
})
