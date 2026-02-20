import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity, Dimensions } from 'react-native';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../../lib/stores/wallpaper-store';
import { Moon, Sun, Smartphone, ArrowLeft } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useRouter } from 'expo-router';
import { LinearGradient } from 'expo-linear-gradient';
import SafeLiquidGlass from '../native/SafeLiquidGlass';

import TelegramDoodleWallpaper from '../chat/wallpapers/TelegramDoodleWallpaper';
import MusicWallpaper from '../chat/wallpapers/MusicWallpaper';
import FoodWallpaper from '../chat/wallpapers/FoodWallpaper';
import TravelWallpaper from '../chat/wallpapers/TravelWallpaper';
import WeatherWallpaper from '../chat/wallpapers/WeatherWallpaper';
import TechWallpaper from '../chat/wallpapers/TechWallpaper';
import PatternWallpaper from '../chat/wallpapers/PatternWallpaper';
import { MessageBubbleBody } from '../chat/bubbles';
import { Message } from '../../lib/types';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

const WallpaperComponents: Record<string, React.ComponentType<any>> = {
    doodles: TelegramDoodleWallpaper,
    music: MusicWallpaper,
    food: FoodWallpaper,
    travel: TravelWallpaper,
    weather: WeatherWallpaper,
    tech: TechWallpaper,
    geometric: (props: any) => <PatternWallpaper {...props} patternType="geometric" />,
    nature: (props: any) => <PatternWallpaper {...props} patternType="nature" />,
    space: (props: any) => <PatternWallpaper {...props} patternType="space" />,
    abstract: (props: any) => <PatternWallpaper {...props} patternType="abstract" />,
};

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

export default function AppearancePage() {
    const insets = useSafeAreaInsets();
    const router = useRouter();
    const { theme, setTheme, colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();

    const isDark = effectiveTheme === 'dark';
    const themeToRender = resolveThemeVariant(activeTheme, isDark);
    const WallpaperComp = WallpaperComponents[themeToRender.patternType || 'doodles'] || TelegramDoodleWallpaper;

    const dummyMessages: { msg: Message; isMe: boolean }[] = [
        { msg: { id: '1', fromId: 'them', type: 'text', plaintext: "Testing the appearance!", encryptedContent: '', timestamp: Date.now() }, isMe: false },
        { msg: { id: '2', fromId: 'me', type: 'text', plaintext: "Everything looks sharp.", encryptedContent: '', timestamp: Date.now() }, isMe: true }
    ];

    const options = [
        { key: 'light', label: 'Light', icon: Sun },
        { key: 'dark', label: 'Dark', icon: Moon },
        { key: 'system', label: 'System', icon: Smartphone },
    ] as const;

    const handleBack = () => {
        router.back();
    };

    return (
        <View style={styles.container}>
            {/* Full Screen Wallpaper Preview */}
            <View style={StyleSheet.absoluteFill}>
                <WallpaperComp theme={themeToRender} width={SCREEN_WIDTH} height={SCREEN_HEIGHT} />

            </View>

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
                        style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.4) }]} // Lower opacity for background visibility
                    />
                </MaskedView>
            </View>

            {/* HEADER CONTENT */}
            <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }]}>
                <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <TouchableOpacity onPress={handleBack} style={styles.iconBtnCircle}>
                        <ArrowLeft size={24} color={colors.text} />
                    </TouchableOpacity>
                </SafeLiquidGlass>
                <Text style={[styles.headerTitle, { color: colors.text }]}>Appearance</Text>
                <View style={{ width: 44 }} />
            </View>

            {/* Bubbles Preview */}
            <View style={styles.previewContent}>
                <View style={[styles.bubblesContainer, { marginTop: insets.top + 60 }]}>
                    {dummyMessages.map((item) => {
                        const resolvedBubbleTheme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
                        const gradient = item.isMe
                            ? (resolvedBubbleTheme.bubbleMeGradient && resolvedBubbleTheme.bubbleMeGradient.length >= 2 ? resolvedBubbleTheme.bubbleMeGradient : [resolvedBubbleTheme.bubbleMe, resolvedBubbleTheme.bubbleMe])
                            : (resolvedBubbleTheme.bubbleThemGradient && resolvedBubbleTheme.bubbleThemGradient.length >= 2 ? resolvedBubbleTheme.bubbleThemGradient : [resolvedBubbleTheme.bubbleThem, resolvedBubbleTheme.bubbleThem]);

                        return (
                            <View key={item.msg.id} style={{
                                marginBottom: 12,
                                alignItems: item.isMe ? 'flex-end' : 'flex-start'
                            }}>
                                <LinearGradient
                                    colors={gradient as any}
                                    start={{ x: 0, y: 0 }}
                                    end={{ x: 1, y: 1 }}
                                    style={[
                                        {
                                            padding: 8,
                                            paddingHorizontal: 12,
                                            borderRadius: 18,
                                            maxWidth: '85%',
                                        },
                                        item.isMe ? { borderBottomRightRadius: 4 } : { borderBottomLeftRadius: 4 }
                                    ]}
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

            {/* Glass Mode Toggle at Bottom */}
            <View style={[styles.footer, { paddingBottom: insets.bottom + 20 }]}>
                <SafeLiquidGlass style={styles.glassToggle} blurIntensity={40} tint="dark">
                    {options.map((option) => {
                        const IconComponent = option.icon;
                        const isActive = theme === option.key;

                        return (
                            <TouchableOpacity
                                key={option.key}
                                style={[
                                    styles.toggleItem,
                                    isActive && { backgroundColor: 'rgba(255,255,255,0.15)' }
                                ]}
                                onPress={() => setTheme(option.key)}
                                activeOpacity={0.7}
                            >
                                <IconComponent size={18} color={isActive ? '#fff' : 'rgba(255,255,255,0.6)'} />
                                <Text style={[
                                    styles.toggleLabel,
                                    { color: isActive ? '#fff' : 'rgba(255,255,255,0.6)' }
                                ]}>
                                    {option.label}
                                </Text>
                            </TouchableOpacity>
                        );
                    })}
                </SafeLiquidGlass>
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    // HEADER STYLES
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
        fontSize: 16,
        fontWeight: '500',

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

    previewContent: {
        flex: 1,
        justifyContent: 'center',
        paddingHorizontal: 20,
    },
    bubblesContainer: {
        gap: 8,
    },
    footer: {
        paddingHorizontal: 20,
    },
    glassToggle: {
        flexDirection: 'row',
        borderRadius: 24,
        padding: 4,
        gap: 4,
        overflow: 'hidden',
    },
    toggleItem: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
        paddingVertical: 12,
        borderRadius: 20,
    },
    toggleLabel: {
        fontSize: 14,
        fontWeight: '600',
    },
});
