import React, { useMemo } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Dimensions, Pressable } from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant, PRESET_THEMES } from '../../lib/stores/wallpaper-store';
import { Check, X } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import TelegramDoodleWallpaper from '../chat/wallpapers/TelegramDoodleWallpaper';
import MusicWallpaper from '../chat/wallpapers/MusicWallpaper';
import FoodWallpaper from '../chat/wallpapers/FoodWallpaper';
import TravelWallpaper from '../chat/wallpapers/TravelWallpaper';
import WeatherWallpaper from '../chat/wallpapers/WeatherWallpaper';
import TechWallpaper from '../chat/wallpapers/TechWallpaper';
import PatternWallpaper from '../chat/wallpapers/PatternWallpaper';

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const COLUMN_COUNT = 3;
const GAP = 12;
const THUMB_SIZE = (SCREEN_WIDTH - 48 - (GAP * (COLUMN_COUNT - 1))) / COLUMN_COUNT;
const THUMB_HEIGHT = THUMB_SIZE * 1.5;

// Beautiful gradient presets
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
];

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

const gradientsMatch = (a: string[] | undefined, b: string[]): boolean => {
    if (!a || a.length < 2) return false;
    return a[0].toLowerCase() === b[0].toLowerCase() && a[1].toLowerCase() === b[1].toLowerCase();
};

export default function PickColor({ onClose }: { onClose: () => void }) {
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { updateCustomTheme, activeTheme, selectedPatternId } = useWallpaperStore();
    const isDark = effectiveTheme === 'dark';

    const patternType = useMemo(() => {
        if (selectedPatternId) {
            const p = PRESET_THEMES.find(t => t.id === selectedPatternId);
            return p?.patternType || 'doodles';
        }
        return activeTheme.patternType || 'doodles';
    }, [selectedPatternId, activeTheme.patternType]);

    const WallpaperComp = WallpaperComponents[patternType] || TelegramDoodleWallpaper;

    const getCurrentGradientId = () => {
        const currentBg = activeTheme.backgroundGradient;
        if (!currentBg) return null;
        for (const preset of GRADIENT_PRESETS) {
            const variant = isDark ? preset.dark : preset.light;
            if (gradientsMatch(currentBg, variant)) return preset.id;
        }
        return null;
    };

    const selectedGradientId = getCurrentGradientId();

    return (
        <View style={styles.modalContainer}>
            <Pressable style={styles.backdrop} onPress={onClose} />
            <SafeLiquidGlass style={[styles.sheet, { paddingBottom: insets.bottom + 20 }]} blurIntensity={40} tint="dark">
                <View style={styles.handle} />
                <View style={styles.header}>
                    <Text style={styles.title}>Accent Color</Text>
                    <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={20} tint="dark">
                        <TouchableOpacity onPress={onClose} style={styles.iconBtnCircle}>
                            <X size={20} color="#fff" />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                </View>

                <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.scrollContent}>
                    <View style={styles.grid}>
                        {GRADIENT_PRESETS.map((preset) => {
                            const isActive = selectedGradientId === preset.id;
                            const displayGradient = isDark ? preset.dark : preset.light;
                            const themeForComp = { ...activeTheme, backgroundGradient: displayGradient, patternOpacity: 0.15 };

                            return (
                                <TouchableOpacity
                                    key={preset.id}
                                    onPress={() => updateCustomTheme({ backgroundGradient: displayGradient })}
                                    style={styles.thumbWrapper}
                                >
                                    <View style={styles.thumbInner}>
                                        <LinearGradient
                                            colors={displayGradient as [string, string]}
                                            style={StyleSheet.absoluteFill}
                                            start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                                        />
                                        <View style={StyleSheet.absoluteFill} pointerEvents="none">
                                            <WallpaperComp theme={themeForComp} width={THUMB_SIZE} height={THUMB_HEIGHT} />
                                        </View>
                                        {isActive && (
                                            <View style={styles.checkCenter}>
                                                <Check size={20} color="#fff" strokeWidth={3} />
                                            </View>
                                        )}
                                    </View>
                                </TouchableOpacity>
                            );
                        })}
                    </View>
                </ScrollView>
            </SafeLiquidGlass>
        </View>
    );
}

const styles = StyleSheet.create({
    modalContainer: { flex: 1, justifyContent: 'flex-end' },
    backdrop: { ...StyleSheet.absoluteFillObject, backgroundColor: 'rgba(0,0,0,0.5)' },
    sheet: { borderTopLeftRadius: 32, borderTopRightRadius: 32, paddingTop: 8, paddingHorizontal: 16, overflow: 'hidden', height: '80%' },
    handle: { width: 40, height: 4, borderRadius: 2, alignSelf: 'center', marginVertical: 12, backgroundColor: 'rgba(255,255,255,0.2)' },
    header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20, paddingHorizontal: 8 },
    title: { fontSize: 20, fontWeight: '700', color: '#fff' },
    closeBtn: { width: 32, height: 32, borderRadius: 16, backgroundColor: 'rgba(255,255,255,0.1)', alignItems: 'center', justifyContent: 'center' },
    scrollContent: { paddingBottom: 40 },
    grid: { flexDirection: 'row', flexWrap: 'wrap', gap: GAP },
    thumbWrapper: { width: THUMB_SIZE, height: THUMB_HEIGHT, borderRadius: 16, overflow: 'hidden' },
    thumbInner: { flex: 1 },
    checkCenter: { ...StyleSheet.absoluteFillObject, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.1)' },
    glassBtnCircle: {
        width: 32,
        height: 32,
        borderRadius: 16,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center'
    },
    iconBtnCircle: {
        width: 32,
        height: 32,
        alignItems: 'center',
        justifyContent: 'center'
    },
});
