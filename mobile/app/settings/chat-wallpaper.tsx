import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Dimensions, Pressable } from 'react-native';
import { useRouter } from 'expo-router';
import { ChevronLeft, Check, ChevronRight, Sun, Moon, X } from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useWallpaperStore } from '../../src/lib/stores/wallpaper-store';
import { PATTERNS } from '../../src/lib/wallpapers/patterns';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Animated, { useSharedValue, useAnimatedStyle, withTiming, interpolate, Extrapolate, runOnJS, Easing, SharedValue } from 'react-native-reanimated';
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import { MessageBubbleBody } from '../../src/components/chat/bubbles';
import WallpaperBackground from '../../src/components/chat/WallpaperBackground';
import { resolveThemeVariant } from '../../src/lib/stores/wallpaper-store';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

const MODAL_HEIGHT = SCREEN_HEIGHT * 0.94;
const OPEN_Y = 0;
const CLOSED_Y = SCREEN_HEIGHT;
const SMOOTH_TIMING = { duration: 400, easing: Easing.bezier(0.25, 0.1, 0.25, 1) };

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

interface WallpaperPreviewModalProps {
    visible: boolean;
    onClose: () => void;
    pattern: string | null;
    parentScale: SharedValue<number>;
    onApply: (pattern: string) => void;
}

function WallpaperPreviewModal({ visible, onClose, pattern, parentScale, onApply }: WallpaperPreviewModalProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();
    const insets = useSafeAreaInsets();
    const [previewMode, setPreviewMode] = useState<'light' | 'dark'>(effectiveTheme === 'dark' ? 'dark' : 'light');

    // Keep track of the active pattern even when modal is closing to prevent flashes
    // Initialize with a default to ensure it's always ready to render
    const [activePattern, setActivePattern] = useState<string>('hearts');

    const translateY = useSharedValue(CLOSED_Y);
    const backdrop = useSharedValue(0);
    const startY = useSharedValue(OPEN_Y);

    useEffect(() => {
        if (pattern) {
            setActivePattern(pattern);
        }
    }, [pattern]);

    useEffect(() => {
        if (visible) {
            // Slight delay to allow component to mount/prepare before animating
            requestAnimationFrame(() => {
                translateY.value = withTiming(OPEN_Y, { duration: 250 });
                backdrop.value = withTiming(1, { duration: 250 });
                parentScale.value = withTiming(0.92, SMOOTH_TIMING);
            });
        } else {
            backdrop.value = withTiming(0, { duration: 200 });
            translateY.value = withTiming(CLOSED_Y, { duration: 250 });
            parentScale.value = withTiming(1, SMOOTH_TIMING);
        }
    }, [visible]);

    const handleCloseInternal = () => {
        onClose();
    };

    const gesture = Gesture.Pan()
        .activeOffsetY([-10, 10])
        .onBegin(() => { startY.value = translateY.value })
        .onUpdate((e) => {
            const nextY = startY.value + e.translationY;
            translateY.value = Math.max(OPEN_Y, Math.min(CLOSED_Y, nextY));
        })
        .onEnd((e) => {
            if (translateY.value > 120 || e.velocityY > 1000) {
                runOnJS(handleCloseInternal)();
            } else {
                translateY.value = withTiming(OPEN_Y, { duration: 250 });
            }
        });

    const panelStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }],
    }));

    const overlayStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value,
        pointerEvents: visible ? 'auto' : 'none'
    }));

    // Dummy Messages
    const dummyMessages = [
        { msg: { id: '1', fromId: 'them', type: 'text', plaintext: "How does this look?", encryptedContent: '', timestamp: Date.now() }, isMe: false },
        { msg: { id: '2', fromId: 'me', type: 'text', plaintext: "It looks amazing! ✨", encryptedContent: '', timestamp: Date.now() }, isMe: true }
    ];

    const isPreviewDark = previewMode === 'dark';
    const isRootDark = effectiveTheme === 'dark';
    const currentPattern = pattern || activePattern;

    const mockTheme = {
        ...activeTheme,
        type: 'masked-image',
        maskedImage: currentPattern,
        patternType: currentPattern,
        backgroundGradient: isPreviewDark ? ['#000', '#050507'] : ['#F5F2EB', '#EDE8DF'],
    };

    return (
        <View style={[StyleSheet.absoluteFill, { zIndex: 999 }]} pointerEvents={visible ? 'auto' : 'none'}>
            <Animated.View style={[styles.overlay, overlayStyle, { backgroundColor: 'rgba(0,0,0,0.3)' }]}>
                <Pressable style={StyleSheet.absoluteFill} onPress={handleCloseInternal} />
            </Animated.View>

            <GestureDetector gesture={gesture}>
                <Animated.View style={[styles.modalContainer, panelStyle, { backgroundColor: isPreviewDark ? '#000' : '#fff' }]}>
                    {/* Fullsize Wallpaper Render */}
                    <View style={StyleSheet.absoluteFill}>
                        <WallpaperBackground theme={mockTheme} width={SCREEN_WIDTH} height={MODAL_HEIGHT} />
                    </View>

                    {/* Header Controls (Close & Theme Toggle) wrapped in Glass */}
                    <View style={[styles.modalHeader, { paddingTop: 30 }]}>
                        <View style={{ width: 44 }} />

                        <SafeLiquidGlass style={styles.modalThemeToggleGlass} blurIntensity={20} tint={isRootDark ? 'dark' : 'light'}>
                            <View style={styles.modalThemeToggle}>
                                <Animated.View style={[
                                    styles.toggleTab,
                                    { backgroundColor: isPreviewDark ? colors.primary : (isRootDark ? '#333' : '#fff') },
                                    useAnimatedStyle(() => ({
                                        transform: [{ translateX: withTiming(previewMode === 'light' ? 0 : 36, { duration: 250 }) }]
                                    }))
                                ]} />
                                <TouchableOpacity
                                    onPress={() => setPreviewMode('light')}
                                    style={styles.themeBtn}
                                >
                                    <Sun size={18} color={previewMode === 'light' ? (isPreviewDark ? '#fff' : '#000') : '#888'} />
                                </TouchableOpacity>
                                <TouchableOpacity
                                    onPress={() => setPreviewMode('dark')}
                                    style={styles.themeBtn}
                                >
                                    <Moon size={18} color={previewMode === 'dark' ? (isPreviewDark ? '#fff' : '#000') : '#888'} />
                                </TouchableOpacity>
                            </View>
                        </SafeLiquidGlass>

                        <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={isRootDark ? 'dark' : 'light'}>
                            <TouchableOpacity onPress={handleCloseInternal} style={styles.modalCloseBtn}>
                                <X size={24} color={colors.text} />
                            </TouchableOpacity>
                        </SafeLiquidGlass>
                    </View>

                    <View style={styles.modalMessagesPreview}>
                        {dummyMessages.map((item) => {
                            const resolvedPreviewTheme = resolveThemeVariant(activeTheme, previewMode === 'dark');
                            const previewBubbleTheme = {
                                meGradient: (resolvedPreviewTheme.bubbleMeGradient && resolvedPreviewTheme.bubbleMeGradient.length >= 2
                                    ? [resolvedPreviewTheme.bubbleMeGradient[0], resolvedPreviewTheme.bubbleMeGradient[1]]
                                    : [resolvedPreviewTheme.bubbleMe, resolvedPreviewTheme.bubbleMe]) as [string, string],
                                themGradient: (resolvedPreviewTheme.bubbleThemGradient && resolvedPreviewTheme.bubbleThemGradient.length >= 2
                                    ? [resolvedPreviewTheme.bubbleThemGradient[0], resolvedPreviewTheme.bubbleThemGradient[1]]
                                    : [resolvedPreviewTheme.bubbleThem, resolvedPreviewTheme.bubbleThem]) as [string, string],
                            };

                            return (
                                <View key={item.msg.id} style={{
                                    marginBottom: 12,
                                    alignItems: item.isMe ? 'flex-end' : 'flex-start'
                                }}>
                                    <LinearGradient
                                        colors={item.isMe ? previewBubbleTheme.meGradient : previewBubbleTheme.themGradient}
                                        start={{ x: 0, y: 0 }}
                                        end={{ x: 1, y: 1 }}
                                        style={{
                                            padding: 8,
                                            paddingHorizontal: 12,
                                            borderRadius: 18,
                                            maxWidth: '85%',
                                            ...(item.isMe ? { borderBottomRightRadius: 4 } : { borderBottomLeftRadius: 4 })
                                        }}
                                    >
                                        <MessageBubbleBody
                                            item={{
                                                ...item.msg,
                                                isMe: item.isMe,
                                                text: item.msg.plaintext || '',
                                                timestamp: new Date(item.msg.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                                            } as any}
                                        />
                                    </LinearGradient>
                                </View>
                            );
                        })}
                    </View>

                    {/* Apply Button Overlay wrapped in Glass */}
                    <View style={[styles.applyBtnOverlay, { paddingBottom: insets.bottom + 20 }]}>
                        <SafeLiquidGlass style={styles.applyBtnGlass} blurIntensity={20} tint={isRootDark ? 'dark' : 'light'}>
                            <TouchableOpacity
                                onPress={() => currentPattern && onApply(currentPattern)}
                                style={[styles.applyBtnLarge, { backgroundColor: withAlpha(colors.bubbleMe, 0.7) }]}
                            >
                                <Text style={[styles.applyBtnText, { color: colors.text }]}>Set Wallpaper</Text>
                            </TouchableOpacity>
                        </SafeLiquidGlass>
                    </View>
                </Animated.View>
            </GestureDetector>
        </View>
    );
}

export default function ChatWallpaperPage() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme, updateCustomTheme } = useWallpaperStore();

    // Scale Animation for Background
    const parentScale = useSharedValue(1);

    // Modal State
    const [selectedPattern, setSelectedPattern] = useState<string | null>(null);

    const handleApplyWallpaper = (pattern: string) => {
        const isMusic = pattern === 'music';
        updateCustomTheme({
            ...activeTheme,
            type: 'masked-image',
            maskedImage: pattern, // direct mapping now: music, hearts, food
            patternType: pattern,
            id: 'custom'
        });
        setSelectedPattern(null);
        parentScale.value = withTiming(1, SMOOTH_TIMING);
    };

    const animatedParentStyle = useAnimatedStyle(() => ({
        transform: [{ scale: parentScale.value }],
        borderRadius: interpolate(parentScale.value, [1, 0.92], [0, 24], Extrapolate.CLAMP),
        overflow: 'hidden',
        flex: 1,
        backgroundColor: colors.background
    }));

    // List of all available high-resolution patterns
    const filteredPatterns = ['doodles', 'hearts', 'food', 'music', 'music2', 'animals'];

    return (
        <GestureHandlerRootView style={{ flex: 1, backgroundColor: '#000' }}>
            <Animated.View style={animatedParentStyle}>

                {/* MASKED HEADER */}
                <View style={[styles.headerMaskContainer, { height: insets.top + 60 }]}>
                    <MaskedView
                        style={StyleSheet.absoluteFill}
                        maskElement={
                            <LinearGradient
                                colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']}
                                locations={[0.6, 1]}
                                style={StyleSheet.absoluteFill}
                            />
                        }
                    >
                        <BlurView
                            intensity={20}
                            tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                            style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.8) }]}
                        />
                    </MaskedView>
                </View>

                {/* HEADER CONTENT */}
                <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }]}>
                    <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={() => router.back()} style={styles.iconBtnCircle}>
                            <ChevronLeft size={24} color={colors.text} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                    <Text style={[styles.headerTitle, { color: colors.text }]}>Chat Wallpaper</Text>
                    <View style={{ width: 44 }} />
                </View>

                {/* CONTENT */}
                <ScrollView contentContainerStyle={[styles.scrollContent, { paddingTop: insets.top + 80 }]} showsVerticalScrollIndicator={false}>

                    {/* SET A COLOR ROW */}
                    <TouchableOpacity
                        style={[styles.setCustomColorRow, { backgroundColor: colors.card }]}
                        onPress={() => router.push('/settings/set-color')}
                        activeOpacity={0.7}
                    >
                        <View style={styles.rowLeft}>
                            <Text style={[styles.rowLabel, { color: colors.text }]}>Set a Color</Text>
                        </View>
                        <ChevronRight size={20} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                    </TouchableOpacity>

                    <View style={styles.grid}>
                        {filteredPatterns.map((key) => {
                            const isMusic = key === 'music';
                            const isSelected = activeTheme.patternType === key;

                            const gridWidth = (SCREEN_WIDTH - 48) / 2;
                            const gridHeight = gridWidth * (16 / 9);

                            const gridTheme = {
                                ...activeTheme,
                                type: 'masked-image',
                                maskedImage: key, // 'music', 'hearts', 'food'
                                patternType: key,
                                // Purely for grid preview aesthetics
                                patternOpacity: 0.3,
                            };

                            return (
                                <TouchableOpacity
                                    key={key}
                                    onPress={() => setSelectedPattern(key)}
                                    activeOpacity={0.8}
                                    style={styles.gridItem}
                                >
                                    <View style={[styles.previewWrapper, { width: gridWidth, height: gridHeight }, isSelected && { borderColor: colors.primary, borderWidth: 2 }]}>
                                        <WallpaperBackground
                                            theme={gridTheme}
                                            width={gridWidth}
                                            height={gridHeight}
                                        />

                                        {/* Label Tag */}
                                        <SafeLiquidGlass style={styles.labelTag} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                            <Text style={[styles.labelText, { color: colors.text }]}>
                                                {key.charAt(0).toUpperCase() + key.slice(1)}
                                            </Text>
                                        </SafeLiquidGlass>

                                        {isSelected && (
                                            <View style={[styles.checkBadge, { backgroundColor: colors.primary }]}>
                                                <Check size={12} color="#fff" strokeWidth={3} />
                                            </View>
                                        )}
                                    </View>
                                </TouchableOpacity>
                            );
                        })}
                    </View>
                    <View style={{ height: 40 }} />
                </ScrollView>

            </Animated.View>

            <WallpaperPreviewModal
                visible={!!selectedPattern}
                pattern={selectedPattern}
                onClose={() => {
                    setSelectedPattern(null);
                    parentScale.value = withTiming(1, SMOOTH_TIMING);
                }}
                parentScale={parentScale}
                onApply={handleApplyWallpaper}
            />
        </GestureHandlerRootView>
    );
}

const styles = StyleSheet.create({
    headerMaskContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 60,
        pointerEvents: 'none'
    },
    headerContentContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 130,
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        paddingHorizontal: 16,
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '600'
    },
    glassBtnCircle: {
        width: 40,
        height: 40,
        borderRadius: 20,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center'
    },
    iconBtnCircle: {
        width: 40,
        height: 40,
        alignItems: 'center',
        justifyContent: 'center'
    },
    scrollContent: {
        paddingHorizontal: 16,
        paddingBottom: 40
    },
    grid: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: 16,
    },
    gridItem: {
        width: (SCREEN_WIDTH - 48) / 2,
        marginBottom: 8,
    },
    previewWrapper: {
        borderRadius: 16,
        overflow: 'hidden',
        backgroundColor: '#1a1a1a',
        position: 'relative'
    },
    setCustomColorRow: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: 16,
        borderRadius: 20,
        marginBottom: 24,
        minHeight: 64
    },
    rowLeft: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 16
    },
    rowLabel: {
        fontSize: 17,
        fontWeight: '600'
    },
    labelTag: {
        position: 'absolute',
        bottom: 8,
        left: 8,
        paddingHorizontal: 10,
        paddingVertical: 6,
        borderRadius: 12,
        overflow: 'hidden'
    },
    labelText: {
        fontSize: 12,
        fontWeight: '600'
    },
    checkBadge: {
        position: 'absolute',
        top: 8,
        right: 8,
        width: 24,
        height: 24,
        borderRadius: 12,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 2,
        borderColor: '#fff'
    },

    // Modal Styles
    overlay: { ...StyleSheet.absoluteFillObject },
    modalContainer: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        height: MODAL_HEIGHT,
        borderTopLeftRadius: 32,
        borderTopRightRadius: 32,
        overflow: 'hidden',
        elevation: 10,
        shadowColor: '#000',
        shadowOffset: { width: 0, height: -4 },
        shadowOpacity: 0.25,
        shadowRadius: 10,
    },
    modalHeader: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 16,
        zIndex: 100,
    },
    modalCloseBtn: {
        width: 44,
        height: 44,
        alignItems: 'center',
        justifyContent: 'center',
    },
    modalThemeToggleGlass: {
        borderRadius: 999,
        overflow: 'hidden'
    },
    modalThemeToggle: {
        flexDirection: 'row',
        padding: 4,
        position: 'relative',
        width: 80,

    },
    toggleTab: {
        position: 'absolute',
        top: 4,
        left: 4,
        width: 36,
        height: 36,
        borderRadius: 18,
    },
    themeBtn: {
        width: 36,
        height: 36,
        borderRadius: 18,
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 5,
    },
    themeBtnActive: {
        // bg set inline
    },
    modalMessagesPreview: {
        flex: 1,
        justifyContent: 'center',
        paddingHorizontal: 20,
        zIndex: 50,
    },
    applyBtnOverlay: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        paddingHorizontal: 20,
        zIndex: 100,
    },
    applyBtnGlass: {
        borderRadius: 20,
        overflow: 'hidden'
    },
    applyBtnLarge: {
        height: 56,
        alignItems: 'center',
        justifyContent: 'center',
    },
    applyBtnText: {
        fontSize: 17,
        fontWeight: '700',
    },
});
