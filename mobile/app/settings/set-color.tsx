import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Dimensions, Pressable } from 'react-native';
import { useRouter } from 'expo-router';
import { ChevronRight, ArrowLeft, Check } from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useWallpaperStore } from '../../src/lib/stores/wallpaper-store';
import { LinearGradient } from 'expo-linear-gradient';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';

const { width } = Dimensions.get('window');
const COLUMN_COUNT = 3;
const GAP = 4;
const CARD_WIDTH = (width - 32 - (GAP * (COLUMN_COUNT - 1))) / COLUMN_COUNT;
const CARD_HEIGHT = CARD_WIDTH * 1.3;

const GRADIENT_PRESETS = [
    { id: 'ocean-deep', dark: ['#0a1f2f', '#0d2840'], light: ['#b8d4e8', '#c5dff0'] },
    { id: 'midnight-indigo', dark: ['#1a1e3a', '#252b4d'], light: ['#c5c8e8', '#d0d4f0'] },
    { id: 'dark-teal', dark: ['#0c2428', '#122d32'], light: ['#bcd4d8', '#c8e0e4'] },
    { id: 'ocean-twilight', dark: ['#122838', '#1a3545'], light: ['#c0d8e8', '#cce4f0'] },
    { id: 'plum-wine', dark: ['#2a1e38', '#352748'], light: ['#d8cce8', '#e4d5f2'] },
    { id: 'chocolate-rose', dark: ['#2a1f1f', '#352828'], light: ['#dcd0d0', '#e6dada'] },
    { id: 'pacific-blue', dark: ['#142535', '#1c3248'], light: ['#c4d8e8', '#d0e4f4'] },
    { id: 'violet-dusk', dark: ['#1e2040', '#282a52'], light: ['#d0d2e8', '#dcdff5'] },
    { id: 'forest-teal', dark: ['#0e2828', '#142f32'], light: ['#c0d8d8', '#cce2e4'] },
    { id: 'charcoal-slate', dark: ['#18191f', '#1e2026'], light: ['#d0d2d6', '#d8dadf'] },
    { id: 'midnight-gray', dark: ['#1a1c20', '#202226'], light: ['#d4d6d8', '#dcdee0'] },
    { id: 'steel-night', dark: ['#161a1e', '#1c2024'], light: ['#ccd0d4', '#d4d8dc'] },
    { id: 'forest-night', dark: ['#121f1a', '#182820'], light: ['#c8d8d2', '#d2e2dc'] },
    { id: 'deep-emerald', dark: ['#0e201c', '#142824'], light: ['#c4d8d4', '#cee2de'] },
    { id: 'pine-forest', dark: ['#101e18', '#16261e'], light: ['#c6d6d0', '#d0e0da'] },
];

const withAlpha = (color: string, alpha: number): string => {
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

// Helper to check if gradient matches
const gradientsMatch = (a: string[] | undefined, b: string[]): boolean => {
    if (!a || !b || a.length < 2 || b.length < 2) return false;
    // Compare first two colors as simplified check
    return a[0].toLowerCase() === b[0].toLowerCase() && a[1].toLowerCase() === b[1].toLowerCase();
};

export default function SetColorPage() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme, updateCustomTheme } = useWallpaperStore();

    const isDark = effectiveTheme === 'dark';

    // Find currently selected gradient
    const getCurrentGradientId = () => {
        const currentBg = activeTheme.backgroundGradient;
        if (!currentBg) return null;

        for (const preset of GRADIENT_PRESETS) {
            const variant = isDark ? preset.dark : preset.light;
            if (gradientsMatch(currentBg, variant)) {
                return preset.id;
            }
        }
        return null;
    };

    const selectedGradientId = getCurrentGradientId();

    const handleGradientSelect = (preset: typeof GRADIENT_PRESETS[0]) => {
        // Set both light and dark variants for proper adaptive support
        updateCustomTheme({
            id: 'custom',
            name: 'Custom',
            backgroundGradient: isDark ? preset.dark : preset.light,
            light: {
                ...activeTheme.light,
                backgroundGradient: preset.light,
            },
            dark: {
                ...activeTheme.dark,
                backgroundGradient: preset.dark,
            },
        } as any);
    };

    const handleCustomColorPress = () => {
        router.push('/settings/your-color');
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
                        style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.8) }]}
                    />
                </MaskedView>
            </View>

            {/* HEADER CONTENT */}
            <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }]}>
                <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <TouchableOpacity onPress={() => router.back()} style={styles.iconBtnCircle}>
                        <ArrowLeft size={24} color={colors.text} />
                    </TouchableOpacity>
                </SafeLiquidGlass>
                <Text style={[styles.headerTitle, { color: colors.text }]}>Accent Color</Text>
                <View style={{ width: 44 }} />
            </View>

            <ScrollView contentContainerStyle={[styles.content, { paddingTop: insets.top + 80 }]} showsVerticalScrollIndicator={false}>
                {/* Set Custom Color Row */}
                <View style={[styles.settingsCard, { backgroundColor: colors.card }]}>
                    <TouchableOpacity
                        style={styles.settingRow}
                        onPress={handleCustomColorPress}
                        activeOpacity={0.7}
                    >
                        <Text style={[styles.settingLabel, { color: colors.text }]}>Set Custom Color</Text>
                        <ChevronRight size={18} color={colors.textSecondary} style={{ opacity: 0.5 }} />
                    </TouchableOpacity>
                </View>

                {/* Gradient Grid */}
                <View style={styles.grid}>
                    {GRADIENT_PRESETS.map((preset) => {
                        const isActive = selectedGradientId === preset.id;
                        // Show the gradient based on current theme (dark/light)
                        const displayGradient = isDark ? preset.dark : preset.light;

                        return (
                            <TouchableOpacity
                                key={preset.id}
                                onPress={() => handleGradientSelect(preset)}
                                style={styles.gradientCard}
                                activeOpacity={0.8}
                            >
                                <LinearGradient
                                    colors={displayGradient as [string, string, ...string[]]}
                                    style={styles.gradientFill}
                                    start={{ x: 0, y: 0 }}
                                    end={{ x: 1, y: 1 }}
                                />

                                {isActive && (
                                    <View style={styles.checkBadge}>
                                        <Check size={16} color="#fff" strokeWidth={3} />
                                    </View>
                                )}
                            </TouchableOpacity>
                        );
                    })}
                </View>
            </ScrollView>
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

    content: {
        padding: 16,
        paddingBottom: 40,
    },
    settingsCard: {
        borderRadius: 16,
        overflow: 'hidden',
        marginBottom: 20,
    },
    settingRow: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingVertical: 12,
        paddingHorizontal: 16,
        minHeight: 52,
    },
    settingLabel: {
        fontSize: 17,
        fontWeight: '400',
    },
    grid: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: GAP,
    },
    gradientCard: {
        width: CARD_WIDTH,
        height: CARD_HEIGHT,
        borderRadius: 12,
        overflow: 'hidden',
    },
    gradientFill: {
        flex: 1,
    },
    checkBadge: {
        position: 'absolute',
        top: '50%',
        left: '50%',
        marginTop: -16,
        marginLeft: -16,
        width: 32,
        height: 32,
        borderRadius: 16,
        backgroundColor: 'rgba(255,255,255,0.25)',
        alignItems: 'center',
        justifyContent: 'center',
    },
});
