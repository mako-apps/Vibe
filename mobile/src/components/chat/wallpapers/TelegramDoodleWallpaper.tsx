import React, { useMemo } from 'react';
import { useWindowDimensions, StyleSheet, View } from 'react-native';
import { Canvas, Path, Skia, Group, Rect, LinearGradient, vec } from '@shopify/react-native-skia';
import { ChatTheme, useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { isDarkColor } from '../../../lib/utils/color';
import { PATTERNS, PatternType, PATTERN_SIZES } from '../../../lib/wallpapers/patterns';

// Increased cell size for a more premium, less "busy" look (was 22)
const CELL_SIZE = 34;

interface Props {
    theme: ChatTheme;
    width?: number;
    height?: number;
}

const rng = (seed: number) => {
    const x = Math.sin(seed) * 10000;
    return x - Math.floor(x);
};

// Simplified Skia vec helper since we already import it
// vec is already imported from @shopify/react-native-skia

// Parse color to RGB for interpolation
const parseColorToRgb = (color: string): { r: number; g: number; b: number } => {
    const hexMatch = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(color);
    if (hexMatch) {
        return {
            r: parseInt(hexMatch[1], 16),
            g: parseInt(hexMatch[2], 16),
            b: parseInt(hexMatch[3], 16)
        };
    }
    return { r: 139, g: 92, b: 246 }; // Fallback
};

const rgbToHex = (r: number, g: number, b: number): string => {
    return '#' + [r, g, b].map(x => {
        const hex = Math.max(0, Math.min(255, x)).toString(16);
        return hex.length === 1 ? '0' + hex : hex;
    }).join('');
};

const interpolateColor = (colors: string[], t: number): string => {
    if (colors.length === 0) return '#8B5CF6';
    if (colors.length === 1) return colors[0];
    const segmentCount = colors.length - 1;
    const segment = Math.min(Math.floor(t * segmentCount), segmentCount - 1);
    const segmentT = (t * segmentCount) - segment;
    const c1 = parseColorToRgb(colors[segment]);
    const c2 = parseColorToRgb(colors[Math.min(segment + 1, colors.length - 1)]);
    const r = Math.round(c1.r + (c2.r - c1.r) * segmentT);
    const g = Math.round(c1.g + (c2.g - c1.g) * segmentT);
    const b = Math.round(c1.b + (c2.b - c1.b) * segmentT);
    return rgbToHex(r, g, b);
};

export default function TelegramDoodleWallpaper({
    theme,
    width: propWidth,
    height: propHeight,
}: Props) {
    const dims = useWindowDimensions();
    const patternType = theme.patternType || 'doodles';
    const width = propWidth || dims.width;
    const height = propHeight || dims.height;

    const bgStart = theme.backgroundGradient?.[0];
    const isDark = bgStart ? isDarkColor(bgStart) : false;

    // Get paths based on selected pattern type
    const rawPaths = useMemo(() => {
        if (patternType === 'doodles') {
            return [...PATTERN_SIZES.large, ...PATTERN_SIZES.medium, ...PATTERN_SIZES.small];
        }
        return PATTERNS[patternType as PatternType] || PATTERNS.doodles;
    }, [patternType]);

    // Convert to Skia paths
    const skiaPaths = useMemo(() => {
        return rawPaths.map(d => Skia.Path.MakeFromSVGString(d)).filter(p => !!p);
    }, [rawPaths]);

    // Pattern gradient colors
    const patternGradientColors = useMemo(() => {
        if ((theme as any).patternGradientColors && (theme as any).patternGradientColors.length > 0) {
            return (theme as any).patternGradientColors;
        }
        return isDark
            ? ['#6366F1', '#8B5CF6', '#22D3EE', '#2DD4BF']
            : ['#4338CA', '#7C3AED', '#06B6D4', '#059669'];
    }, [(theme as any).patternGradientColors, isDark]);

    // MEMOIZE PATTERN ITEMS
    const items = useMemo(() => {
        if (skiaPaths.length === 0) return [];

        const seed = 9932;
        const cols = Math.floor(width / CELL_SIZE);
        const rows = Math.floor(height / CELL_SIZE) + 2;

        const grid = new Uint8Array(cols * rows);
        const result: {
            pathIdx: number;
            x: number;
            y: number;
            scale: number;
            rotation: number;
            opacity: number;
            gradientT: number;
            vignette: number; // Opacity factor for smooth fading
        }[] = [];

        const xOffset = (width - cols * CELL_SIZE) / 2;
        const diagonalLength = Math.sqrt(width * width + height * height);

        for (let r = 0; r < rows; r++) {
            for (let c = 0; c < cols; c++) {
                if (grid[r * cols + c]) continue;

                // Skip random cells for a more organic feel
                const skipRand = rng(seed + r * 37 + c * 23);
                if (skipRand > 0.85) {
                    grid[r * cols + c] = 1;
                    continue;
                }

                let isBig = false;
                const rRand = rng(seed + r * 19 + c * 73);
                if (rRand > 0.88 && c < cols - 1 && r < rows - 1) {
                    if (!grid[r * cols + (c + 1)] && !grid[(r + 1) * cols + c] && !grid[(r + 1) * cols + (c + 1)]) {
                        isBig = true;
                    }
                }

                const pathIdx = Math.floor(rng(seed + r * cols + c) * skiaPaths.length);
                const rotation = (rng(seed + r * 17 + c) - 0.5) * 60;

                const cellX = c * CELL_SIZE + xOffset;
                const cellY = r * CELL_SIZE;

                // Position on the main diagonal (0 at top-left, 1 at bottom-right)
                const diagonalPos = (cellX + cellY) / diagonalLength;
                const gradientT = Math.max(0, Math.min(1, diagonalPos));

                // USER: "bottom right and left top are blended and less opacity"
                // Implement a fade where opacity is highest in the center of the diagonal
                // and lowest at the ends (top-left and bottom-right)
                const distFromMid = Math.abs(gradientT - 0.5) * 2; // 0 at middle, 1 at ends
                const vignette = Math.max(0.1, 1 - Math.pow(distFromMid, 1.5)); // Soft curve

                const baseScale = isBig ? 1.0 : 0.6;
                const scaleVar = (rng(seed + r * 33 + c) - 0.5) * 0.2;
                const finalScale = baseScale + scaleVar;

                const jitterX = (rng(seed + r * 101 + c) - 0.5) * (CELL_SIZE * 0.4);
                const jitterY = (rng(seed + r * 102 + c + 1) - 0.5) * (CELL_SIZE * 0.4);

                const gridSpan = isBig ? CELL_SIZE * 2 : CELL_SIZE;
                const contentSize = 24 * finalScale;
                const centerOffset = (gridSpan - contentSize) / 2;

                const finalX = cellX + centerOffset + jitterX;
                const finalY = cellY + centerOffset + jitterY;

                const opacityMultiplier = 0.8 + rng(seed * 3 + r) * 0.4;

                result.push({
                    pathIdx,
                    x: finalX,
                    y: finalY,
                    scale: finalScale,
                    rotation,
                    opacity: opacityMultiplier,
                    gradientT,
                    vignette
                });

                grid[r * cols + c] = 1;
                if (isBig) {
                    grid[r * cols + (c + 1)] = 1;
                    grid[(r + 1) * cols + c] = 1;
                    grid[(r + 1) * cols + (c + 1)] = 1;
                }
            }
        }
        return result;
    }, [width, height, skiaPaths]);

    // Background colors for the integrated Canvas gradient
    const bgColors = theme.backgroundGradient || ['#000000', '#050507'];
    const basePatternOpacity = theme.patternOpacity ?? 0.05;

    return (
        <View style={StyleSheet.absoluteFill}>
            <Canvas style={{ flex: 1 }}>
                {/* 1. Integrated Background Gradient - Required for proper blend modes */}
                <Rect x={0} y={0} width={width} height={height}>
                    <LinearGradient
                        start={vec(0, 0)}
                        end={vec(width, height)}
                        colors={bgColors}
                    />
                </Rect>

                {/* 2. Patterns with Mixed Blending and Vignette */}
                {items.map((item, i) => {
                    const skPath = skiaPaths[item.pathIdx];
                    if (!skPath) return null;

                    const itemColor = interpolateColor(patternGradientColors, item.gradientT);
                    // Combine base opacity, random variation, and the corner vignette
                    const finalOpacity = basePatternOpacity * item.opacity * item.vignette;

                    return (
                        <Group
                            key={i}
                            transform={[
                                { translateX: item.x },
                                { translateY: item.y },
                                { translateX: 12 * item.scale },
                                { translateY: 12 * item.scale },
                                { rotate: (item.rotation * Math.PI) / 180 },
                                { translateX: -12 * item.scale },
                                { translateY: -12 * item.scale },
                                { scale: item.scale }
                            ]}
                            opacity={finalOpacity}
                            // 'Screen' blend mode makes it look glowing/blended on dark, 
                            // 'Multiply' or 'Overlay' could be used for light but Screen is versatile here
                            blendMode={isDark ? "screen" : "multiply"}
                        >
                            <Path
                                path={skPath}
                                style="stroke"
                                strokeWidth={1.2 / item.scale}
                                strokeCap="round"
                                strokeJoin="round"
                                color={itemColor}
                            />
                        </Group>
                    );
                })}
            </Canvas>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1
    }
});
