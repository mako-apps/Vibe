
import React, { useState } from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import { useThemeStore } from '../../../lib/stores/theme-store';

interface Props {
    selectedColor: string;
    onColorSelect: (color: string) => void;
}

const HUE_COLORS = [
    '#ef4444', // Red
    '#f97316', // Orange
    '#f59e0b', // Amber
    '#eab308', // Yellow
    '#84cc16', // Lime
    '#10b981', // Emerald
    '#06b6d4', // Cyan
    '#3b82f6', // Blue
    '#6366f1', // Indigo
    '#8b5cf6', // Violet
    '#d946ef', // Fuchsia
    '#be185d', // Pink
];

const TINTS = [
    '#ffffff', // White
    '#f3f4f6', // Gray 100
    '#9ca3af', // Gray 400
    '#4b5563', // Gray 600
    '#1f2937', // Gray 800
    '#000000', // Black
];

export default function SimpleColorPicker({ selectedColor, onColorSelect }: Props) {
    const { colors } = useThemeStore();

    return (
        <View style={styles.container}>
            <Text style={[styles.label, { color: colors.textSecondary }]}>ACCENT COLOR</Text>
            <View style={styles.grid}>
                {HUE_COLORS.map(c => (
                    <TouchableOpacity
                        key={c}
                        style={[
                            styles.swatch,
                            { backgroundColor: c },
                            selectedColor === c && { borderWidth: 3, borderColor: colors.background, transform: [{ scale: 1.15 }] }
                        ]}
                        onPress={() => onColorSelect(c)}
                    />
                ))}
            </View>

            <Text style={[styles.label, { color: colors.textSecondary, marginTop: 16 }]}>NEUTRALS</Text>
            <View style={styles.grid}>
                {TINTS.map(c => (
                    <TouchableOpacity
                        key={c}
                        style={[
                            styles.swatch,
                            { backgroundColor: c, borderWidth: 1, borderColor: 'rgba(0,0,0,0.1)' },
                            selectedColor === c && { borderWidth: 3, borderColor: c === '#ffffff' ? '#000' : colors.card, transform: [{ scale: 1.15 }] }
                        ]}
                        onPress={() => onColorSelect(c)}
                    />
                ))}
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        paddingVertical: 10,
    },
    label: {
        fontSize: 11,
        fontWeight: '600',
        marginBottom: 10,
        opacity: 0.7,
        letterSpacing: 0.5,
    },
    grid: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: 12,
    },
    swatch: {
        width: 36,
        height: 36,
        borderRadius: 18,
        elevation: 1,
    }
});
