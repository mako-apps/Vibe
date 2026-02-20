import React, { useEffect } from 'react';
import {
    View,
    Text,
    TouchableOpacity,
    StyleSheet,
    Dimensions,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { X, ChevronRight } from 'lucide-react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    withRepeat,
    runOnJS,
    interpolate,
    SlideInUp,
    SlideOutUp,
    Easing
} from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import MaskedView from '@react-native-masked-view/masked-view';

import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { useThemeStore } from '../../lib/stores/theme-store';
import StreamingText from './StreamingText';

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const MaskedViewAny = MaskedView as any;

interface VibeResponseToastProps {
    visible: boolean;
    response: string;
    userMessage?: string;
    isStreaming: boolean;
    isComplete: boolean;
    error?: string;
    currentTool?: {
        tool: string;
        status: 'running' | 'completed' | 'failed';
        label?: string;
    } | null;
    onClose: () => void;
    onViewFull: () => void;
}

const withAlpha = (color: string, opacity: number) => {
    if (!color) return `rgba(0,0,0,${opacity})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${opacity})`;
    }
    return color;
};

const ShimmeringText = ({ text, style, isLight }: { text: string; style?: any; isLight: boolean }) => {
    const shimmer = useSharedValue(0);
    useEffect(() => {
        shimmer.value = withRepeat(
            withTiming(1, { duration: 1500, easing: Easing.linear }),
            -1,
            false
        );
    }, []);

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [{
            translateX: interpolate(shimmer.value, [0, 1], [-SCREEN_WIDTH * 0.8, SCREEN_WIDTH * 0.8])
        }]
    }));

    const highlightColor = isLight ? 'rgba(0,0,0,0.8)' : 'rgba(255,255,255,0.9)';
    const baseColor = isLight ? 'rgba(0,0,0,0.3)' : 'rgba(255,255,255,0.3)';

    return (
        <View style={{ position: 'relative', height: 20, justifyContent: 'center' }}>
            <Text style={[style, { color: baseColor }]} numberOfLines={1}>{text}</Text>
            <View style={StyleSheet.absoluteFill}>
                <MaskedViewAny
                    style={StyleSheet.absoluteFill}
                    maskElement={
                        <View style={{ flex: 1, backgroundColor: 'transparent', justifyContent: 'center' }}>
                            <Text style={[style, { color: '#000' }]} numberOfLines={1}>{text}</Text>
                        </View>
                    }
                >
                    <Animated.View style={[{ flex: 1, flexDirection: 'row' }, animatedStyle]}>
                        <LinearGradient
                            colors={['transparent', highlightColor, 'transparent']}
                            start={{ x: 0, y: 0 }}
                            end={{ x: 1, y: 0 }}
                            style={StyleSheet.absoluteFill}
                        />
                    </Animated.View>
                </MaskedViewAny>
            </View>
        </View>
    );
};

export default function VibeResponseToast({
    visible,
    response,
    userMessage,
    isStreaming,
    isComplete,
    error,
    currentTool,
    onClose,
    onViewFull
}: VibeResponseToastProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const insets = useSafeAreaInsets();

    // Draggable position
    const translateX = useSharedValue(0);
    const translateY = useSharedValue(0);
    const context = useSharedValue({ x: 0, y: 0 });

    const panGesture = Gesture.Pan()
        .onStart(() => {
            context.value = { x: translateX.value, y: translateY.value };
        })
        .onUpdate((event) => {
            translateX.value = event.translationX + context.value.x;
            translateY.value = event.translationY + context.value.y;
        })
        .onEnd(() => {
            if (translateY.value < -50 || Math.abs(translateX.value) > SCREEN_WIDTH * 0.4) {
                runOnJS(onClose)();
            } else {
                translateX.value = withTiming(0);
                translateY.value = withTiming(0);
            }
        });

    const animatedStyle = useAnimatedStyle(() => {
        return {
            transform: [
                { translateX: translateX.value },
                { translateY: translateY.value }
            ],
            top: insets.top + 60,
        };
    });

    if (!visible) return null;

    const hasContent = response.length > 0;

    return (
        <GestureDetector gesture={panGesture}>
            <Animated.View
                style={[styles.container, animatedStyle]}
                entering={SlideInUp.duration(500).easing(Easing.out(Easing.quad))}
                exiting={SlideOutUp.duration(300)}
            >
                <SafeLiquidGlass
                    style={styles.pillContainer}
                    blurIntensity={30}
                    tint={isLight ? 'light' : 'dark'}
                >
                    <View style={styles.content}>
                        {/* Header Area */}
                        <View style={styles.header}>
                            <View style={styles.headerTitleContainer}>
                                <Text style={[styles.userMessageText, { color: colors.text }]} numberOfLines={1}>
                                    {userMessage || "Vibe Insight"}
                                </Text>
                            </View>
                            <TouchableOpacity onPress={onClose} style={styles.closeBtn} hitSlop={12}>
                                <X size={14} color={withAlpha(colors.text, 0.3)} />
                            </TouchableOpacity>
                        </View>

                        {/* Main Response Area */}
                        <View style={styles.body}>
                            {currentTool && currentTool.status === 'running' && (
                                <ShimmeringText
                                    text={currentTool.label || `${currentTool.tool}...`}
                                    style={[styles.toolText, { color: colors.primary }]}
                                    isLight={isLight}
                                />
                            )}

                            {error ? (
                                <Text style={styles.errorText}>{error}</Text>
                            ) : hasContent ? (
                                <StreamingText
                                    text={response}
                                    isStreaming={isStreaming}
                                    style={{ fontSize: 16, lineHeight: 22, color: colors.text }}
                                />
                            ) : isStreaming && !currentTool && (
                                <ShimmeringText
                                    text="Working..."
                                    style={{ fontSize: 16, fontWeight: '500' }}
                                    isLight={isLight}
                                />
                            )}
                        </View>

                        {/* Minimal Action Footer */}
                        {isComplete && response && (
                            <TouchableOpacity
                                onPress={onViewFull}
                                activeOpacity={0.8}
                                style={[styles.footer, { borderTopColor: withAlpha(colors.text, 0.05) }]}
                            >
                                <Text style={[styles.footerText, { color: colors.primary }]}>
                                    Open Conversation
                                </Text>
                                <ChevronRight size={14} color={colors.primary} />
                            </TouchableOpacity>
                        )}
                    </View>
                </SafeLiquidGlass>
            </Animated.View>
        </GestureDetector>
    );
}

const styles = StyleSheet.create({
    container: {
        position: 'absolute',
        left: 16,
        right: 16,
        zIndex: 10000,
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 8 },
        shadowOpacity: 0.15,
        shadowRadius: 24,
        elevation: 10,
    },
    pillContainer: {
        borderRadius: 24,
        overflow: 'hidden',
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.08)',
    },
    content: {
        padding: 4,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 16,
        paddingTop: 8,
        paddingBottom: 4,
        gap: 8,
    },
    headerTitleContainer: {
        flex: 1,
    },
    userMessageText: {
        fontSize: 16,
        fontWeight: '500',
        opacity: 0.9,
    },
    closeBtn: {
        padding: 4,
    },
    body: {
        paddingHorizontal: 16,
        paddingTop: 8,
        paddingBottom: 10,
        maxHeight: 180,
    },
    toolText: {
        fontSize: 16,
        fontWeight: '500',
    },
    errorText: {
        fontSize: 14,
        color: '#ef4444',
    },
    footer: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        paddingVertical: 12,
        borderTopWidth: 1,
        gap: 4,
    },
    footerText: {
        fontSize: 14,
        fontWeight: '600',
    },
});
