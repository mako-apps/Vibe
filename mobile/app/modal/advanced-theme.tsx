import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Dimensions } from 'react-native';
import { useRouter } from 'expo-router';
import { X } from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useWallpaperStore, ChatTheme } from '../../src/lib/stores/wallpaper-store';
import SpectrumColorPicker from '../../src/components/ui/color-picker/SpectrumColorPicker';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { LinearGradient } from 'expo-linear-gradient';

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

export default function AdvancedThemeModal() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors } = useThemeStore();
    const { activeTheme, activeThemeId, updateCustomTheme } = useWallpaperStore();

    const handleColorSelect = (color: string) => {
        const base = activeThemeId === 'custom' ? activeTheme : {
            ...activeTheme,
            id: 'custom',
            name: 'Custom',
            // Preserve isAdaptive if we are branching from a classic/adaptive theme
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

    return (
        <View style={[styles.container, { backgroundColor: colors.background, paddingTop: insets.top }]}>
            {/* Header */}
            <View style={styles.header}>
                <Text style={[styles.title, { color: colors.text }]}>Colors & Bubbles</Text>
                <TouchableOpacity onPress={() => router.back()} style={styles.closeBtn}>
                    <X size={24} color={colors.text} />
                </TouchableOpacity>
            </View>

            <ScrollView contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
                {/* Preview */}
                <View style={styles.previewSection}>
                    <Text style={[styles.label, { color: colors.textSecondary }]}>PREVIEW</Text>
                    <View style={[styles.previewCard, { backgroundColor: colors.card }]}>
                        <View style={[styles.bubblePreview]}>
                            {activeTheme.bubbleMeGradient && (
                                <LinearGradient
                                    colors={activeTheme.bubbleMeGradient as [string, string]}
                                    style={StyleSheet.absoluteFill}
                                    start={{ x: 0, y: 0 }}
                                    end={{ x: 1, y: 1 }}
                                />
                            )}
                            <Text style={{ color: activeTheme.textColorMe, fontSize: 16, zIndex: 1 }}>Your message bubble</Text>
                        </View>
                    </View>
                </View>

                {/* Color Picker */}
                <View style={styles.section}>
                    <Text style={[styles.label, { color: colors.textSecondary }]}>ACCENT COLOR</Text>
                    <SpectrumColorPicker
                        selectedColor={activeTheme.bubbleMe}
                        onColorSelect={handleColorSelect}
                    />
                </View>

                {/* Info */}
                <View style={styles.infoBox}>
                    <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                        Select a color to customize your message bubble. The pattern will automatically adapt to light and dark modes.
                    </Text>
                </View>
            </ScrollView>
        </View>
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
        paddingHorizontal: 20,
        paddingVertical: 16,
    },
    title: {
        fontSize: 20,
        fontWeight: 'bold',
    },
    closeBtn: {
        padding: 4,
    },
    content: {
        padding: 20,
        paddingBottom: 60,
    },
    previewSection: {
        marginBottom: 24,
    },
    label: {
        fontSize: 12,
        fontWeight: '600',
        letterSpacing: 0.5,
        marginBottom: 12,
    },
    previewCard: {
        borderRadius: 16,
        padding: 20,
        alignItems: 'center',
    },
    bubblePreview: {
        paddingVertical: 14,
        paddingHorizontal: 20,
        borderRadius: 18,
        borderBottomRightRadius: 4,
        overflow: 'hidden',
    },
    section: {
        marginBottom: 24,
    },
    infoBox: {
        padding: 16,
        borderRadius: 12,
        backgroundColor: 'rgba(128,128,128,0.1)',
    },
    infoText: {
        fontSize: 14,
        lineHeight: 20,
    },
});
