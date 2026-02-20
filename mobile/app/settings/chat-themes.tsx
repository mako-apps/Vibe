import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Dimensions, SafeAreaView } from 'react-native';
import { useRouter } from 'expo-router';
import { ChevronLeft, Check } from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useWallpaperStore, PRESET_THEMES } from '../../src/lib/stores/wallpaper-store';
import { PATTERNS } from '../../src/lib/wallpapers/patterns';
import SpectrumColorPicker from '../../src/components/ui/color-picker/SpectrumColorPicker';
import { isDarkColor } from '../../src/lib/utils/color';
import Slider from '@react-native-community/slider';
const { width } = Dimensions.get('window');

// Helper to lighten a color for gradient
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

// Wallpaper components
import TelegramDoodleWallpaper from '../../src/components/chat/wallpapers/TelegramDoodleWallpaper';
import MusicWallpaper from '../../src/components/chat/wallpapers/MusicWallpaper';
import FoodWallpaper from '../../src/components/chat/wallpapers/FoodWallpaper';
import TravelWallpaper from '../../src/components/chat/wallpapers/TravelWallpaper';
import WeatherWallpaper from '../../src/components/chat/wallpapers/WeatherWallpaper';
import TechWallpaper from '../../src/components/chat/wallpapers/TechWallpaper';
import PatternWallpaper from '../../src/components/chat/wallpapers/PatternWallpaper';

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

export default function ChatThemesPage() {
    const router = useRouter();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme, activeThemeId, setTheme: setChatTheme, updateCustomTheme } = useWallpaperStore();
    const isDark = effectiveTheme === 'dark';

    const handleColorSelect = (color: string) => {
        const base = activeThemeId === 'custom' ? activeTheme : {
            ...activeTheme,
            id: 'custom',
            name: 'Custom',
            isAdaptive: activeTheme.isAdaptive
        };
        const gradientEnd = lighten(color, 20);

        updateCustomTheme({
            ...base,
            bubbleMe: color,
            bubbleMeGradient: [color, gradientEnd],
            patternColor: undefined,
        });
    };

    const handlePatternSelect = (patternKey: string) => {
        const base = activeThemeId === 'custom' ? activeTheme : {
            ...activeTheme,
            id: 'custom',
            name: 'Custom',
            isAdaptive: activeTheme.isAdaptive
        };
        updateCustomTheme({
            ...base,
            patternType: patternKey,
        });
    };

    const handlePatternIntensity = (value: number) => {
        const base = activeThemeId === 'custom' ? activeTheme : { ...activeTheme, id: 'custom', name: 'Custom' };
        updateCustomTheme({
            ...base,
            patternOpacity: value,
        });
    };

    return (
        <SafeAreaView style={[styles.container, { backgroundColor: colors.background }]}>
            {/* Header */}
            <View style={styles.header}>
                <TouchableOpacity onPress={() => router.back()} style={styles.backBtn}>
                    <ChevronLeft size={28} color={colors.primary} />
                </TouchableOpacity>
                <Text style={[styles.title, { color: colors.text }]}>Chat Theme</Text>
                <View style={{ width: 40 }} />
            </View>

            <ScrollView contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
                {/* Theme Selection */}
                <View style={styles.section}>
                    <Text style={[styles.label, { color: colors.textSecondary }]}>SELECT A THEME</Text>
                    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.themeList}>
                        {PRESET_THEMES.map((t) => {
                            const isActive = activeThemeId === t.id;
                            let themeForPreview = t;

                            // Adaptive Logic
                            if (isDark || t.isAdaptive) {
                                const bgStart = t.backgroundGradient?.[0] || '#ffffff';
                                if (isDark && !isDarkColor(bgStart)) {
                                    themeForPreview = { ...t, backgroundGradient: ['#191919', '#191919'], patternColor: undefined };
                                }
                                if (t.id === 'classic' || t.isAdaptive) {
                                    themeForPreview = {
                                        ...themeForPreview,
                                        bubbleThem: colors.bubbleThem,
                                        bubbleMe: t.id === 'classic' ? colors.bubbleMe : t.bubbleMe
                                    };
                                }
                            }

                            return (
                                <TouchableOpacity
                                    key={t.id}
                                    onPress={() => setChatTheme(t.id)}
                                    style={styles.themeThumb}
                                >
                                    <View style={[
                                        styles.themeCircle,
                                        { backgroundColor: themeForPreview.backgroundGradient[0] },
                                        isActive && { borderColor: colors.primary, borderWidth: 2 }
                                    ]}>
                                        <View style={[styles.thumbBubbleMe, { backgroundColor: themeForPreview.bubbleMe }]} />
                                        <View style={[styles.thumbBubbleThem, { backgroundColor: themeForPreview.bubbleThem }]} />
                                        {isActive && (
                                            <View style={[styles.checkBadge, { backgroundColor: colors.primary }]}>
                                                <Check size={8} color="#fff" strokeWidth={4} />
                                            </View>
                                        )}
                                    </View>
                                    <Text style={[styles.themeLabel, { color: isActive ? colors.primary : colors.text }]}>
                                        {t.name}
                                    </Text>
                                </TouchableOpacity>
                            );
                        })}
                    </ScrollView>
                </View>

                {/* Color Customize */}
                <View style={styles.section}>
                    <Text style={[styles.label, { color: colors.textSecondary }]}>ACCENT COLOR</Text>
                    <View style={[styles.card, { backgroundColor: colors.card }]}>
                        <SpectrumColorPicker
                            selectedColor={activeTheme.bubbleMe}
                            onColorSelect={handleColorSelect}
                        />
                    </View>
                </View>

                {/* Pattern Selection */}
                <View style={styles.section}>
                    <Text style={[styles.label, { color: colors.textSecondary }]}>BACKGROUND PATTERN</Text>
                    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.themeList}>
                        {Object.keys(PATTERNS).map((key) => {
                            const isActive = activeTheme.patternType === key;
                            const WallpaperComp = WallpaperComponents[key] || TelegramDoodleWallpaper;
                            return (
                                <TouchableOpacity
                                    key={key}
                                    onPress={() => handlePatternSelect(key)}
                                    style={styles.themeThumb}
                                >
                                    <View style={[
                                        styles.patternCircle,
                                        { backgroundColor: colors.card },
                                        isActive && { borderColor: colors.primary, borderWidth: 2 }
                                    ]}>
                                        <View style={{ opacity: 0.6, width: 64, height: 64 }}>
                                            <WallpaperComp
                                                theme={{ ...activeTheme, patternOpacity: 1, patternColor: colors.primary + '44' }}
                                                width={64}
                                                height={64}
                                            />
                                        </View>
                                        {isActive && (
                                            <View style={[styles.checkBadge, { backgroundColor: colors.primary }]}>
                                                <Check size={8} color="#fff" strokeWidth={4} />
                                            </View>
                                        )}
                                    </View>
                                    <Text style={[styles.themeLabel, { color: isActive ? colors.primary : colors.text }]}>
                                        {key.charAt(0).toUpperCase() + key.slice(1)}
                                    </Text>
                                </TouchableOpacity>
                            );
                        })}
                    </ScrollView>

                    <View style={[styles.card, { backgroundColor: colors.card, marginTop: 16 }]}>
                        <View style={styles.sliderRow}>
                            <Text style={[styles.sliderLabel, { color: colors.text }]}>Pattern Intensity</Text>
                            <Text style={[styles.sliderValue, { color: colors.primary }]}>
                                {Math.round(activeTheme.patternOpacity * 100)}%
                            </Text>
                        </View>
                        <Slider
                            style={{ width: '100%', height: 40 }}
                            minimumValue={0}
                            maximumValue={0.5}
                            step={0.01}
                            value={activeTheme.patternOpacity}
                            onSlidingComplete={handlePatternIntensity}
                            minimumTrackTintColor={colors.primary}
                            maximumTrackTintColor={colors.border}
                            thumbTintColor={colors.primary}
                        />
                    </View>
                </View>

                {/* Info */}
                <View style={styles.infoBox}>
                    <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                        Chat themes include custom gradients and patterns. You can mix and match themes with different accent colors and patterns.
                    </Text>
                </View>
            </ScrollView>
        </SafeAreaView>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 16,
        paddingVertical: 12,
    },
    backBtn: {
        padding: 4,
    },
    title: {
        fontSize: 18,
        fontWeight: 'bold',
    },
    content: {
        padding: 20,
        paddingBottom: 40,
    },
    section: {
        marginBottom: 32,
    },
    label: {
        fontSize: 12,
        fontWeight: '600',
        letterSpacing: 0.5,
        marginBottom: 16,
    },
    themeList: {
        gap: 16,
        paddingRight: 20,
    },
    themeThumb: {
        alignItems: 'center',
        gap: 8,
    },
    themeCircle: {
        width: 64,
        height: 64,
        borderRadius: 32,
        overflow: 'hidden',
        position: 'relative',
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.1)',
        justifyContent: 'center',
        alignItems: 'center',
    },
    patternCircle: {
        width: 64,
        height: 64,
        borderRadius: 20,
        overflow: 'hidden',
        position: 'relative',
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.1)',
        justifyContent: 'center',
        alignItems: 'center',
    },
    thumbBubbleMe: {
        width: 30,
        height: 12,
        borderRadius: 6,
        borderBottomRightRadius: 2,
        marginBottom: 4,
    },
    thumbBubbleThem: {
        width: 24,
        height: 10,
        borderRadius: 5,
        borderBottomLeftRadius: 2,
    },
    themeLabel: {
        fontSize: 12,
        fontWeight: '500',
    },
    checkBadge: {
        position: 'absolute',
        top: 0,
        right: 0,
        width: 18,
        height: 18,
        borderRadius: 9,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 2,
        borderColor: '#000',
    },
    card: {
        padding: 16,
        borderRadius: 16,
    },
    sliderRow: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        marginBottom: 8,
    },
    sliderLabel: {
        fontSize: 14,
        fontWeight: '500',
    },
    sliderValue: {
        fontSize: 14,
        fontWeight: 'bold',
    },
    infoBox: {
        padding: 16,
        borderRadius: 12,
        backgroundColor: 'rgba(128,128,128,0.1)',
        marginTop: 8,
    },
    infoText: {
        fontSize: 14,
        lineHeight: 20,
    },
});
