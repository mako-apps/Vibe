import React, { useMemo } from 'react';
import { useWindowDimensions, StyleSheet, View } from 'react-native';
import { Canvas, Rect, LinearGradient, vec, useImage, Image, Mask, Group, Skia, DataSource } from '@shopify/react-native-skia';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import { isDarkColor } from '../../../lib/utils/color';

interface Props {
    theme: ChatTheme;
    imageSource: DataSource; // require(...) path
    width?: number;
    height?: number;
    opacityMultiplier?: number;
    fit?: 'cover' | 'contain' | 'fill' | 'fitWidth' | 'fitHeight' | 'none' | 'scaleDown';
}

// Convert RGB to hex helper
const rgbToHex = (r: number, g: number, b: number): string => {
    return '#' + [r, g, b].map(x => {
        const hex = Math.max(0, Math.min(255, x)).toString(16);
        return hex.length === 1 ? '0' + hex : hex;
    }).join('');
};

export default function MaskedImageWallpaper({
    theme,
    imageSource,
    width: propWidth,
    height: propHeight,
    opacityMultiplier = 3.5,
    fit = 'cover'
}: Props) {
    const dims = useWindowDimensions();
    const width = propWidth || dims.width;
    const height = propHeight || dims.height;

    // Load the asset
    const image = useImage(imageSource);

    // Determine if background is dark
    const bgStart = theme.backgroundGradient?.[0];
    const isDark = bgStart ? isDarkColor(bgStart) : false;

    // Background Gradient (Base Layer)
    const bgColors = theme.backgroundGradient || (isDark ? ['#000000', '#111111'] : ['#ffffff', '#f0f0f0']);

    // Pattern Gradient (Mask Fill Color)
    const patternGradientColors = useMemo(() => {
        if ((theme as any).patternGradientColors?.length > 0) {
            return (theme as any).patternGradientColors;
        }
        return isDark
            ? ['#6366F1', '#8B5CF6', '#22D3EE']
            : ['#4338CA', '#6D28D9', '#06B6D4'];
    }, [(theme as any).patternGradientColors, isDark]);

    // Opacity
    const patternOpacity = Math.min(1, (theme.patternOpacity ?? 0.15) * opacityMultiplier);

    if (!image) {
        return <View style={StyleSheet.absoluteFill} />;
    }

    return (
        <View style={StyleSheet.absoluteFill}>
            <Canvas style={{ flex: 1 }}>
                {/* 1. Background Layer */}
                <Rect x={0} y={0} width={width} height={height}>
                    <LinearGradient
                        start={vec(0, 0)}
                        end={vec(width, height)}
                        colors={bgColors}
                    />
                </Rect>

                {/* 2. Masked Pattern Layer */}
                <Group opacity={patternOpacity}>
                    <Mask
                        mode="alpha"
                        mask={
                            <Image
                                image={image}
                                x={0}
                                y={0}
                                width={width}
                                height={height}
                                fit={fit}
                            />
                        }
                    >
                        {/* The Gradient that paints the opaque parts of the mask */}
                        <Rect x={0} y={0} width={width} height={height}>
                            <LinearGradient
                                start={vec(0, 0)}
                                end={vec(width, height)}
                                colors={patternGradientColors}
                            />
                        </Rect>
                    </Mask>
                </Group>
            </Canvas>
        </View>
    );
}
