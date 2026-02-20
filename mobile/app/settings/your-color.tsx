import React, { useState, useMemo, useEffect, useRef } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Dimensions, PanResponder } from 'react-native';
import { useRouter } from 'expo-router';
import { ArrowLeft, Check, Sun, Moon, ChevronUp, ChevronDown, RotateCcw } from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useWallpaperStore, ChatTheme } from '../../src/lib/stores/wallpaper-store';
import { useToastStore } from '../../src/lib/stores/toast-store';
import { LinearGradient } from 'expo-linear-gradient';
import SpectrumColorPicker from '../../src/components/ui/color-picker/SpectrumColorPicker';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { MessageBubbleBody } from '../../src/components/chat/bubbles';
import { resolveThemeVariant } from '../../src/lib/stores/wallpaper-store';
import { Message } from '../../src/lib/types';
import Animated, { useSharedValue, useAnimatedStyle, withTiming, interpolate, Extrapolate, runOnJS, Easing } from 'react-native-reanimated';

// Wallpaper components
import TelegramDoodleWallpaper from '../../src/components/chat/wallpapers/TelegramDoodleWallpaper';
import { PATTERNS } from '../../src/lib/wallpapers/patterns';

const WallpaperComponents = Object.keys(PATTERNS).reduce((acc, key) => {
    acc[key] = TelegramDoodleWallpaper;
    return acc;
}, {} as Record<string, React.ComponentType<any>>);

const { width, height: screenHeight } = Dimensions.get('window');

type TabId = 'background' | 'accent' | 'messages';

// Expanded Color Palette
const PRESET_COLORS = [
    // Vivids
    '#FF3B30', '#FF9500', '#FFCC00', '#4CD964', '#5AC8FA', '#007AFF', '#5856D6', '#FF2D55',
    // Pastels
    '#FFB3BA', '#FFDFBA', '#FFFFBA', '#BAFFC9', '#BAE1FF', '#E6E6FA', '#F0E68C', '#D8BFD8',
    // Darks/Neutrals
    '#FFFFFF', '#EFEFF4', '#E5E5EA', '#D1D1D6', '#C7C7CC', '#8E8E93', '#48484A', '#000000',
    '#1A1A1A', '#2C2C2E', '#3A3A3C', '#121212'
];

export default function YourColorPage() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme, updateCustomTheme } = useWallpaperStore();
    const { showToast } = useToastStore();

    const [activeTab, setActiveTab] = useState<TabId>('accent');
    const [isExpanded, setIsExpanded] = useState(true);

    // Preview Mode State (Independent of Global Theme)
    const [previewMode, setPreviewMode] = useState<'light' | 'dark'>(effectiveTheme === 'dark' ? 'dark' : 'light');

    // Reanimated Shared Value for Panel Height/Expansion
    const expansion = useSharedValue(1);
    const startExpansion = useSharedValue(1);

    // Get current color for active tab
    const getActiveColor = () => {
        if (activeTab === 'background') return activeTheme.backgroundGradient?.[0] || '#000000';
        if (activeTab === 'accent') return activeTheme.backgroundGradient?.[1] || activeTheme.backgroundGradient?.[0] || '#000000';
        return activeTheme.bubbleMe || colors.primary;
    };

    const currentActiveColor = getActiveColor();

    const updateOpacity = (percentage: number) => {
        const opacity = Math.max(0, Math.min(0.5, percentage / 200));
        updateCustomTheme({
            ...activeTheme,
            patternOpacity: opacity
        });
    };

    const intensityPan = useMemo(() => PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onMoveShouldSetPanResponder: () => true,
        onPanResponderGrant: (evt) => {
            const specWidth = width - 32;
            const x = Math.max(0, Math.min(evt.nativeEvent.locationX, specWidth));
            const percent = (x / specWidth) * 100;
            updateOpacity(percent);
        },
        onPanResponderMove: (evt) => {
            const specWidth = width - 32;
            const x = Math.max(0, Math.min(evt.nativeEvent.locationX, specWidth));
            const percent = (x / specWidth) * 100;
            updateOpacity(percent);
        },
    }), [activeTheme]);

    const handleColorSelect = (color: string) => {
        const updates: Partial<ChatTheme> = { id: 'custom', name: 'Custom' };
        const currentBg = activeTheme.backgroundGradient || ['#000000', '#000000'];

        if (activeTab === 'background') {
            updates.backgroundGradient = [color, currentBg[1] || color];
            updates.patternColor = color.includes('hsl') ? color.replace('50%)', '30%)') : undefined;
        } else if (activeTab === 'accent') {
            updates.backgroundGradient = [currentBg[0] || color, color];
        } else {
            updates.bubbleMe = color;
            updates.bubbleMeGradient = [color, lighten(color, 15)];
        }
        updateCustomTheme(updates);
    };

    const handleSave = () => {
        showToast('Theme Saved', 'success');
        router.back();
    };

    const handleReset = () => {
        // Reset to a basic default state for Custom theme
        updateCustomTheme({
            id: 'custom',
            name: 'Custom',
            backgroundGradient: undefined, // Will fallback to default or transparent
            bubbleMe: undefined,
            bubbleMeGradient: undefined,
            patternColor: undefined,
            patternOpacity: 0.1
        });
        showToast('Reset to Default', 'info');
    };

    const togglePanel = () => {
        const target = isExpanded ? 0 : 1;
        expansion.value = withTiming(target, { duration: 300, easing: Easing.out(Easing.quad) });
        setIsExpanded(!isExpanded);
    };

    // Real-time Drag Logic
    const panelPan = useMemo(() => PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onMoveShouldSetPanResponder: (_, gestureState) => Math.abs(gestureState.dy) > 5,
        onPanResponderGrant: () => {
            startExpansion.value = expansion.value;
        },
        onPanResponderMove: (_, gestureState) => {
            const delta = -gestureState.dy / 200;
            let newValue = startExpansion.value + delta;
            newValue = Math.max(0, Math.min(1, newValue));
            expansion.value = newValue;
        },
        onPanResponderRelease: (_, gestureState) => {
            const target = expansion.value > 0.5 ? 1 : 0;
            if (gestureState.vy > 1) {
                expansion.value = withTiming(0, { duration: 250, easing: Easing.out(Easing.quad) });
                runOnJS(setIsExpanded)(false);
            } else if (gestureState.vy < -1) {
                expansion.value = withTiming(1, { duration: 250, easing: Easing.out(Easing.quad) });
                runOnJS(setIsExpanded)(true);
            } else {
                expansion.value = withTiming(target, { duration: 300, easing: Easing.out(Easing.quad) });
                runOnJS(setIsExpanded)(target === 1);
            }
        }
    }), []);


    const spectrumStyle = useAnimatedStyle(() => ({
        opacity: interpolate(expansion.value, [0, 0.5, 1], [0, 0, 1]),
        height: interpolate(expansion.value, [0, 1], [0, 200], Extrapolate.CLAMP),
        transform: [{ scale: interpolate(expansion.value, [0, 1], [0.95, 1]) }]
    }));

    const presetsStyle = useAnimatedStyle(() => ({
        opacity: interpolate(expansion.value, [0, 1], [1, 0]),
        height: interpolate(expansion.value, [0, 1], [60, 0], Extrapolate.CLAMP),
        transform: [{ translateY: interpolate(expansion.value, [0, 1], [0, 20]) }]
    }));

    const dummyMessages: { msg: Message; isMe: boolean }[] = [
        { msg: { id: '1', fromId: 'them', type: 'text', plaintext: "How does this look?", encryptedContent: '', timestamp: Date.now(), status: 'read' }, isMe: false },
        { msg: { id: '2', fromId: 'me', type: 'text', plaintext: "It looks amazing! ✨", encryptedContent: '', timestamp: Date.now(), status: 'read' }, isMe: true }
    ];

    const lighten = (hex: string, percent: number) => {
        if (!hex) return '#000';
        if (!hex.startsWith('#')) return hex;
        const num = parseInt(hex.replace('#', ''), 16);
        const amt = Math.round(2.55 * percent);
        const R = (num >> 16) + amt;
        const G = (num >> 8 & 0x00FF) + amt;
        const B = (num & 0x0000FF) + amt;
        return '#' + (0x1000000 + (R < 255 ? R < 1 ? 0 : R : 255) * 0x10000 + (G < 255 ? G < 1 ? 0 : G : 255) * 0x100 + (B < 255 ? B < 1 ? 0 : B : 255)).toString(16).slice(1);
    };

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>

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
                        style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(28,28,28,0.8)' }]}
                    />
                </MaskedView>
            </View>

            {/* HEADER CONTENT */}
            <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }]}>
                <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <TouchableOpacity onPress={() => router.back()} style={styles.iconBtnCircle}>
                        <ArrowLeft size={24} color="#fff" />
                    </TouchableOpacity>
                </SafeLiquidGlass>

                <Text style={[styles.headerTitle, { color: '#fff' }]}>Your Color</Text>

                <View style={{ flexDirection: 'row', gap: 12 }}>

                    {/* Reset Button */}
                    <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={handleReset} style={styles.iconBtnCircle}>
                            <RotateCcw size={20} color="#fff" />
                        </TouchableOpacity>
                    </SafeLiquidGlass>

                    {/* Theme Toggle (Local Preview) */}
                    <SafeLiquidGlass style={styles.glassToggle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={() => setPreviewMode(m => m === 'dark' ? 'light' : 'dark')} style={styles.toggleBtnHeader}>
                            {previewMode === 'dark' ? <Moon size={20} color="#fff" /> : <Sun size={20} color="#000" />}
                        </TouchableOpacity>
                    </SafeLiquidGlass>

                    {/* Save Button */}
                    <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={handleSave} style={styles.iconBtnCircle}>
                            <Check size={20} color="#fff" />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                </View>
            </View>

            {/* MAIN CONTENT AREA */}
            <View style={{ flex: 1 }}>
                <ScrollView contentContainerStyle={{ paddingTop: insets.top + 80, paddingBottom: 320 }} showsVerticalScrollIndicator={false}>

                    {/* Top Tabs */}
                    <View style={styles.tabContainer}>
                        <View style={styles.tabBar}>
                            {(['background', 'accent', 'messages'] as TabId[]).map((tab) => (
                                <TouchableOpacity
                                    key={tab}
                                    onPress={() => setActiveTab(tab)}
                                    style={[
                                        styles.tabItem,
                                        activeTab === tab && styles.activeTabItem,
                                        { backgroundColor: activeTab === tab ? '#3d3d3d' : 'transparent' }
                                    ]}
                                >
                                    <Text style={[
                                        styles.tabText,
                                        { color: activeTab === tab ? '#fff' : '#8e8e8e' }
                                    ]}>
                                        {tab.charAt(0).toUpperCase() + tab.slice(1)}
                                    </Text>
                                </TouchableOpacity>
                            ))}
                        </View>
                    </View>

                    {/* Chat Preview */}
                    <View style={styles.previewContainer}>
                        <View style={[styles.previewWrapper, { backgroundColor: previewMode === 'dark' ? '#111' : '#f0f0f0' }]}>
                            {/* Wallpaper Background */}
                            <View style={StyleSheet.absoluteFill}>
                                {(() => {
                                    const Comp = WallpaperComponents[activeTheme.patternType || 'doodles'] || TelegramDoodleWallpaper;
                                    return <Comp theme={activeTheme} width={width - 32} height={400} />;
                                })()}
                            </View>

                            {/* Messages - Force update with key and forceThemeMode */}
                            <View style={styles.messagesArea}>
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
                        </View>
                        <Text style={{ textAlign: 'center', color: '#666', marginTop: 8, fontSize: 12 }}>
                            {previewMode === 'dark' ? 'Dark Mode Preview' : 'Light Mode Preview'}
                        </Text>
                    </View>
                </ScrollView>
            </View>

            {/* DYNAMIC BOTTOM PANEL */}
            <View style={[styles.bottomPanel, { paddingBottom: insets.bottom + 10 }]}>
                {/* Drag Handle */}
                <View style={styles.panelHeader} {...panelPan.panHandlers}>
                    <View style={styles.dragHandle} />
                    <TouchableOpacity onPress={togglePanel} hitSlop={20}>
                        {isExpanded ? <ChevronDown size={20} color="#666" /> : <ChevronUp size={20} color="#666" />}
                    </TouchableOpacity>
                </View>

                {/* Intensity Slider - Always Visible */}
                <View style={styles.sliderContainer} {...intensityPan.panHandlers}>
                    <Text style={styles.sliderLabel}>Pattern Opacity</Text>
                    <View style={styles.sliderTrack}>
                        <LinearGradient
                            colors={['#000', getActiveColor(), '#fff']}
                            start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }}
                            style={styles.intensityGradient}
                        />
                        <View style={[styles.sliderThumb, { left: `${(activeTheme.patternOpacity || 0) * 200}%` } as any]} />
                    </View>
                </View>

                {/* EXPANDED: SPECTRUM */}
                <Animated.View style={[styles.spectrumWrapper, spectrumStyle]}>
                    <SpectrumColorPicker
                        selectedColor={getActiveColor()}
                        onColorSelect={handleColorSelect}
                    />
                </Animated.View>

                {/* COLLAPSED: PRESETS */}
                <Animated.View style={[styles.presetsWrapper, presetsStyle]}>
                    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.presetsContent}>
                        {PRESET_COLORS.map((color) => (
                            <TouchableOpacity
                                key={color}
                                onPress={() => handleColorSelect(color)}
                                style={[styles.presetCircle, { backgroundColor: color, borderColor: currentActiveColor === color ? '#fff' : 'transparent' }]}
                            />
                        ))}
                    </ScrollView>
                </Animated.View>

            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    headerMaskContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 60, pointerEvents: 'none' },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 130, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingHorizontal: 16 },
    headerTitle: { fontSize: 17, fontWeight: '600' },
    glassBtnCircle: { width: 40, height: 40, borderRadius: 20, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    iconBtnCircle: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
    glassToggle: { height: 40, borderRadius: 20, overflow: 'hidden', justifyContent: 'center', paddingHorizontal: 12 },
    toggleBtnHeader: { alignItems: 'center', justifyContent: 'center' },
    tabContainer: { paddingHorizontal: 16, paddingBottom: 16, paddingTop: 16 },
    tabBar: { flexDirection: 'row', backgroundColor: '#2c2c2c', borderRadius: 12, padding: 4 },
    tabItem: { flex: 1, paddingVertical: 10, alignItems: 'center', borderRadius: 8 },
    activeTabItem: {},
    tabText: { fontSize: 14, fontWeight: '600' },
    previewContainer: { paddingHorizontal: 16 },
    previewWrapper: { height: 400, borderRadius: 24, overflow: 'hidden', position: 'relative', backgroundColor: '#111', borderWidth: 1, borderColor: 'rgba(255,255,255,0.1)' },
    messagesArea: { padding: 16, justifyContent: 'flex-end', flex: 1, paddingBottom: 20 },
    bottomPanel: { position: 'absolute', bottom: 0, left: 0, right: 0, backgroundColor: '#1c1c1c', borderTopLeftRadius: 24, borderTopRightRadius: 24, paddingHorizontal: 16, paddingTop: 12, shadowColor: "#000", shadowOffset: { width: 0, height: -4 }, shadowOpacity: 0.2, shadowRadius: 8, elevation: 10, borderWidth: 1, borderBottomWidth: 0, borderColor: 'rgba(255,255,255,0.05)' },
    panelHeader: { alignItems: 'center', marginBottom: 12, gap: 8 },
    dragHandle: { width: 40, height: 4, backgroundColor: 'rgba(255,255,255,0.2)', borderRadius: 2 },
    sliderContainer: { marginBottom: 16 },
    sliderLabel: { color: '#888', fontSize: 12, marginBottom: 8, marginLeft: 4 },
    sliderTrack: { height: 24, position: 'relative', justifyContent: 'center' },
    intensityGradient: { height: 8, borderRadius: 4, width: '100%' },
    sliderThumb: { position: 'absolute', width: 20, height: 20, borderRadius: 10, backgroundColor: '#fff', marginLeft: -10, shadowColor: "#000", shadowOffset: { width: 0, height: 2 }, shadowOpacity: 0.3, shadowRadius: 2, elevation: 3 },
    spectrumWrapper: { overflow: 'hidden' },
    presetsWrapper: { overflow: 'hidden' },
    presetsContent: { alignItems: 'center', gap: 12, paddingHorizontal: 4 },
    presetCircle: { width: 40, height: 40, borderRadius: 20, borderWidth: 2 }
});
