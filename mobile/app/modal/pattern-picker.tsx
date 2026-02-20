import React from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Dimensions } from 'react-native';
import { useRouter } from 'expo-router';
import { X, Check } from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useWallpaperStore } from '../../src/lib/stores/wallpaper-store';
import { PATTERNS } from '../../src/lib/wallpapers/patterns';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

// Pattern icons mapping  
const PATTERN_ICONS: Record<string, string> = {
    doodles: '✏️',
    food: '🍕',
    music: '🎵',
    travel: '✈️',
    weather: '☀️',
    tech: '💻',
    geometric: '◆',
    nature: '🌿',
    space: '🚀',
    abstract: '〰️',
};

const { width } = Dimensions.get('window');

export default function PatternPickerModal() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors } = useThemeStore();
    const { activeTheme, activeThemeId, updateCustomTheme } = useWallpaperStore();

    const activePattern = activeTheme.patternType || 'doodles';

    const handlePatternSelect = (patternKey: string) => {
        const base = activeThemeId === 'custom' ? activeTheme : {
            ...activeTheme,
            id: 'custom',
            name: 'Custom',
            // Preserve isAdaptive
            isAdaptive: activeTheme.isAdaptive
        };
        updateCustomTheme({
            ...base,
            patternType: patternKey,
        });
    };

    const patternKeys = Object.keys(PATTERNS);

    return (
        <View style={[styles.container, { backgroundColor: colors.background, paddingTop: insets.top }]}>
            {/* Header */}
            <View style={styles.header}>
                <Text style={[styles.title, { color: colors.text }]}>Background Pattern</Text>
                <TouchableOpacity onPress={() => router.back()} style={styles.closeBtn}>
                    <X size={24} color={colors.text} />
                </TouchableOpacity>
            </View>

            <ScrollView contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
                <Text style={[styles.label, { color: colors.textSecondary }]}>SELECT A PATTERN</Text>

                <View style={styles.grid}>
                    {patternKeys.map((key) => {
                        const isActive = activePattern === key;
                        const label = key.charAt(0).toUpperCase() + key.slice(1);
                        const icon = PATTERN_ICONS[key] || '🎨';

                        return (
                            <TouchableOpacity
                                key={key}
                                onPress={() => handlePatternSelect(key)}
                                style={[
                                    styles.patternCard,
                                    { backgroundColor: colors.card },
                                    isActive && { borderColor: colors.primary, borderWidth: 2 }
                                ]}
                            >
                                <Text style={styles.patternIcon}>{icon}</Text>
                                <Text style={[styles.patternLabel, { color: isActive ? colors.primary : colors.text }]}>
                                    {label}
                                </Text>
                                {isActive && (
                                    <View style={[styles.checkBadge, { backgroundColor: colors.primary }]}>
                                        <Check size={10} color="#fff" strokeWidth={3} />
                                    </View>
                                )}
                            </TouchableOpacity>
                        );
                    })}
                </View>

                {/* Info */}
                <View style={styles.infoBox}>
                    <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                        Patterns automatically adapt their color based on your app theme (light/dark mode).
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
    label: {
        fontSize: 12,
        fontWeight: '600',
        letterSpacing: 0.5,
        marginBottom: 16,
    },
    grid: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: 12,
    },
    patternCard: {
        width: (width - 40 - 12) / 2,
        paddingVertical: 24,
        borderRadius: 16,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 1,
        borderColor: 'rgba(0,0,0,0.05)',
    },
    patternIcon: {
        fontSize: 32,
        marginBottom: 8,
    },
    patternLabel: {
        fontSize: 14,
        fontWeight: '600',
    },
    checkBadge: {
        position: 'absolute',
        top: 8,
        right: 8,
        width: 20,
        height: 20,
        borderRadius: 10,
        alignItems: 'center',
        justifyContent: 'center',
    },
    infoBox: {
        padding: 16,
        borderRadius: 12,
        backgroundColor: 'rgba(128,128,128,0.1)',
        marginTop: 24,
    },
    infoText: {
        fontSize: 14,
        lineHeight: 20,
    },
});
