import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import SafeLiquidGlass from '../../native/SafeLiquidGlass';
import type { BubbleMenuAction, BubbleMenuItem } from './menu-config';

interface ContextActionMenuProps {
    tint: 'light' | 'dark';
    blurIntensity?: number;
    items: BubbleMenuItem[];
    textColor: string;
    destructiveColor: string;
    pinActiveColor: string;
    onSelect: (action: BubbleMenuAction) => void;
}

export default function ContextActionMenu({
    tint,
    blurIntensity = 10,
    items,
    textColor,
    destructiveColor,
    pinActiveColor,
    onSelect,
}: ContextActionMenuProps) {
    return (
        <SafeLiquidGlass
            style={styles.glass}
            tint={tint as any}
            blurIntensity={blurIntensity}
        >
            <View style={styles.content}>
                {items.map((menuItem) => (
                    <View key={menuItem.id}>
                        {menuItem.dividerBefore && <View style={styles.divider} />}
                        <Pressable
                            style={[
                                styles.item,
                                menuItem.active && { backgroundColor: pinActiveColor },
                            ]}
                            onPress={() => onSelect(menuItem.id)}
                        >
                            <menuItem.icon
                                size={20}
                                color={menuItem.destructive ? destructiveColor : textColor}
                                strokeWidth={2}
                            />
                            <Text style={[
                                styles.text,
                                { color: menuItem.destructive ? destructiveColor : textColor },
                            ]}>
                                {menuItem.label}
                            </Text>
                        </Pressable>
                    </View>
                ))}
            </View>
        </SafeLiquidGlass>
    );
}

const styles = StyleSheet.create({
    glass: {
        minWidth: 234,
        borderRadius: 28,
        position: 'relative',
        overflow: 'hidden',
        backfaceVisibility: 'hidden',
    },
    content: {
        paddingHorizontal: 14,
        paddingVertical: 10,
    },
    divider: {
        height: StyleSheet.hairlineWidth,
        marginVertical: 8,
    },
    item: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12,
        paddingHorizontal: 8,
        paddingVertical: 10,
        borderRadius: 14,
    },
    text: {
        fontSize: 17,
        fontWeight: '600',
        letterSpacing: 0.2,
    },
});
