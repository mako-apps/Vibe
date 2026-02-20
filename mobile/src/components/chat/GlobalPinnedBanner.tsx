import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Pin } from 'lucide-react-native';

import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { useThemeStore } from '../../lib/stores/theme-store';

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

interface GlobalPinnedBannerProps {
    title?: string;
    body: string;
    dotIds?: string[];
    activeDotIndex?: number;
    onPress?: () => void;
}

export default function GlobalPinnedBanner({
    title = 'Pinned Message',
    body,
    dotIds = [],
    activeDotIndex = 0,
    onPress,
}: GlobalPinnedBannerProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const insets = useSafeAreaInsets();
    const isLight = effectiveTheme === 'light';

    return (
        <Pressable
            style={[styles.host, { top: insets.top + 70 }]}
            onPress={onPress}
        >
            <SafeLiquidGlass style={styles.glassPill} blurIntensity={25} tint={isLight ? 'light' : 'dark'}>
                <View style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.1) }]} />

                <View style={styles.content}>
                    <View style={[styles.iconWrap, { backgroundColor: withAlpha(colors.background, 0.2) }]}>
                        <Pin size={14} color={withAlpha(colors.text, 0.95)} strokeWidth={2.4} />
                    </View>

                    <View style={styles.textWrap}>
                        <Text style={styles.title}>{title}</Text>
                        <Text style={styles.body} numberOfLines={1}>
                            {body}
                        </Text>
                    </View>

                    {dotIds.length > 1 && (
                        <View style={styles.dotsRow}>
                            {dotIds.slice(0, 6).map((id, index) => (
                                <View
                                    key={`pin-dot-${id}`}
                                    style={[
                                        styles.dot,
                                        index === activeDotIndex && styles.dotActive,
                                    ]}
                                />
                            ))}
                        </View>
                    )}
                </View>
            </SafeLiquidGlass>
        </Pressable>
    );
}

const styles = StyleSheet.create({
    host: {
        position: 'absolute',
        left: 20,
        right: 20,
        zIndex: 1200,
    },
    glassPill: {
        height: 40,
        borderRadius: 26,
        overflow: 'hidden',
    },
    content: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        gap: 10,
    },
    iconWrap: {
        width: 28,
        height: 28,
        borderRadius: 14,
        alignItems: 'center',
        justifyContent: 'center',
    },
    textWrap: {
        flex: 1,
        justifyContent: 'center',
    },
    title: {
        color: withAlpha('#f7f8ff', 0.95),
        fontSize: 12,
        fontWeight: '700',
        letterSpacing: 0.2,
    },
    body: {
        color: withAlpha('#f7f8ff', 0.82),
        fontSize: 12,
        marginTop: 1,
    },
    dotsRow: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
    },
    dot: {
        width: 6,
        height: 6,
        borderRadius: 3,
        backgroundColor: withAlpha('#ffffff', 0.36),
    },
    dotActive: {
        backgroundColor: withAlpha('#f4b83a', 0.92),
    },
});
