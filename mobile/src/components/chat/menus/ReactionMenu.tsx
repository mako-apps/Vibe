import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import SafeLiquidGlass from '../../native/SafeLiquidGlass';

interface ReactionMenuProps {
    tint: 'light' | 'dark';
    blurIntensity?: number;
    presets: readonly string[];
    chipColor: string;
    onSelect: (emoji: string, sourcePoint?: { x: number; y: number }) => void;
}

export default function ReactionMenu({
    tint,
    blurIntensity = 10,
    presets,
    chipColor,
    onSelect,
}: ReactionMenuProps) {
    return (
        <SafeLiquidGlass
            style={styles.glass}
            tint={tint as any}
            blurIntensity={blurIntensity}
        >
            <View style={styles.content}>
                {presets.map((emoji) => (
                    <Pressable
                        key={emoji}
                        style={[styles.chip, { backgroundColor: chipColor }]}
                        onPress={(event) => {
                            onSelect(emoji, {
                                x: event.nativeEvent.pageX,
                                y: event.nativeEvent.pageY,
                            });
                        }}
                    >
                        <Text style={styles.emoji}>{emoji}</Text>
                    </Pressable>
                ))}
            </View>
        </SafeLiquidGlass>
    );
}

const styles = StyleSheet.create({
    glass: {
        borderRadius: 24,
        position: 'relative',
        overflow: 'hidden',
        backfaceVisibility: 'hidden',
        alignSelf: 'flex-start',
    },
    content: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 10,
        paddingVertical: 8,
        gap: 8,
    },
    chip: {
        width: 36,
        height: 36,
        borderRadius: 18,
        alignItems: 'center',
        justifyContent: 'center',
    },
    emoji: {
        fontSize: 21,
    },
});
