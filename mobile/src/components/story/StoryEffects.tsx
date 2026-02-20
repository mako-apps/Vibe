import React from 'react';
import { ScrollView, TouchableOpacity, Text, StyleSheet, View } from 'react-native';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { theme } from '../../lib/theme';

const colors = theme.dark;

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

export type EffectId = 'none' | 'grayscale' | 'sepia' | 'warm' | 'cool' | 'vintage' | 'dramatic';

export interface Effect {
    id: EffectId;
    name: string;
    matrix?: number[];
}

export const EFFECTS: Effect[] = [
    { id: 'none', name: 'Original' },
    {
        id: 'grayscale',
        name: 'Noir',
        matrix: [
            0.21, 0.72, 0.07, 0, 0,
            0.21, 0.72, 0.07, 0, 0,
            0.21, 0.72, 0.07, 0, 0,
            0, 0, 0, 1, 0
        ]
    },
    {
        id: 'sepia',
        name: 'Sepia',
        matrix: [
            0.39, 0.77, 0.19, 0, 0,
            0.35, 0.68, 0.17, 0, 0,
            0.27, 0.53, 0.13, 0, 0,
            0, 0, 0, 1, 0
        ]
    },
    {
        id: 'warm',
        name: 'Warm',
        matrix: [
            1.2, 0, 0, 0, 0,
            0, 1, 0, 0, 0,
            0, 0, 0.8, 0, 0,
            0, 0, 0, 1, 0
        ]
    },
    {
        id: 'cool',
        name: 'Cool',
        matrix: [
            0.8, 0, 0, 0, 0,
            0, 1, 0, 0, 0,
            0, 0, 1.2, 0, 0,
            0, 0, 0, 1, 0
        ]
    },
    {
        id: 'vintage',
        name: 'Retro',
        matrix: [
            0.9, 0.5, 0.1, 0, 0,
            0.3, 0.8, 0.1, 0, 0,
            0.2, 0.3, 0.5, 0, 0,
            0, 0, 0, 1, 0
        ]
    },
    {
        id: 'dramatic',
        name: 'Drama',
        matrix: [
            1.5, 0, 0, 0, -0.2,
            0, 1.5, 0, 0, -0.2,
            0, 0, 1.5, 0, -0.2,
            0, 0, 0, 1, 0
        ]
    }
];

interface StoryEffectsProps {
    selectedEffectId: EffectId;
    onSelectEffect: (effect: Effect) => void;
}

export const StoryEffects = ({ selectedEffectId, onSelectEffect }: StoryEffectsProps) => {
    return (
        <View style={styles.container}>
            <ScrollView
                horizontal
                showsHorizontalScrollIndicator={false}
                contentContainerStyle={styles.scrollContent}
            >
                {EFFECTS.map((effect) => {
                    const isSelected = selectedEffectId === effect.id;
                    return (
                        <TouchableOpacity
                            key={effect.id}
                            onPress={() => onSelectEffect(effect)}
                            style={styles.effectItem}
                        >
                            <SafeLiquidGlass
                                style={styles.glassBase}
                                blurIntensity={15}
                                tint={isSelected ? 'light' : 'dark'}
                            >
                                <View style={[
                                    styles.effectThumbContent,
                                    isSelected && { backgroundColor: colors.text.primary }
                                ]}>
                                    <Text style={[
                                        styles.effectName,
                                        { color: isSelected ? colors.bg.primary : colors.text.primary },
                                        !isSelected && { opacity: 0.8 }
                                    ]}>
                                        {effect.name}
                                    </Text>
                                </View>
                            </SafeLiquidGlass>
                        </TouchableOpacity>
                    );
                })}
            </ScrollView>
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        height: 60,
        marginBottom: 10,
    },
    scrollContent: {
        paddingHorizontal: 16,
        alignItems: 'center',
        gap: 12,
    },
    effectItem: {
        height: 48,
    },
    glassBase: {
        borderRadius: 24,
        overflow: 'hidden',
    },
    effectThumbContent: {
        paddingHorizontal: 16,
        paddingVertical: 10,
        minWidth: 80,
        height: 48,
        alignItems: 'center',
        justifyContent: 'center',
    },
    effectName: {
        fontSize: 12,
        fontWeight: 'bold',
    }
});
