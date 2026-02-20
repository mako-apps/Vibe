import React, { useMemo } from 'react';
import { useWindowDimensions, StyleSheet, View } from 'react-native';
import { Canvas, Path, Skia, Group, Rect, LinearGradient, vec } from '@shopify/react-native-skia';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import { isDarkColor } from '../../../lib/utils/color';
import { PATTERNS, PatternType, PATTERN_SIZES } from '../../../lib/wallpapers/patterns';

// Reduced cell size for much denser pattern (was 38)
const CELL_SIZE = 22;

interface Props {
    theme: ChatTheme;
    width?: number;
    height?: number;
    patternType?: PatternType; // Optional override
}

const rng = (seed: number) => {
    const x = Math.sin(seed) * 10000;
    return x - Math.floor(x);
};

// Parse any color string to RGB values
const parseColorToRgb = (color: string): { r: number; g: number; b: number } => {
    // Handle hex colors
    const hexMatch = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(color);
    if (hexMatch) {
        return {
            r: parseInt(hexMatch[1], 16),
            g: parseInt(hexMatch[2], 16),
            b: parseInt(hexMatch[3], 16)
        };
    }

    // Handle rgb/rgba colors
    const rgbMatch = /rgba?\((\d+),\s*(\d+),\s*(\d+)/i.exec(color);
    if (rgbMatch) {
        return {
            r: parseInt(rgbMatch[1], 10),
            g: parseInt(rgbMatch[2], 10),
            b: parseInt(rgbMatch[3], 10)
        };
    }

    // Default fallback for dark theme patterns
    return { r: 139, g: 92, b: 246 }; // Purple (#8B5CF6)
};

// Convert RGB to hex
const rgbToHex = (r: number, g: number, b: number): string => {
    return '#' + [r, g, b].map(x => {
        const hex = Math.max(0, Math.min(255, x)).toString(16);
        return hex.length === 1 ? '0' + hex : hex;
    }).join('');
};

// Interpolate between colors based on position (0-1)
const interpolateColor = (colors: string[], t: number): string => {
    if (colors.length === 0) return '#8B5CF6'; // Default purple
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

export default function PatternWallpaper({
    theme,
    width: propWidth,
    height: propHeight,
    patternType = 'doodles'
}: Props) {
    const dims = useWindowDimensions();

    const width = propWidth || dims.width;
    const height = propHeight || dims.height;

    // Determine if background is dark based on the gradient start color
    const bgStart = theme.backgroundGradient?.[0];
    const isDark = bgStart ? isDarkColor(bgStart) : false;

    // Get paths based on selected pattern type
    const rawPaths = useMemo(() => {
        if (patternType === 'doodles') {
            // Combine all size categories for dense doodles
            return [...PATTERN_SIZES.large, ...PATTERN_SIZES.medium, ...PATTERN_SIZES.small, ...PATTERN_SIZES.tiny, ...PATTERN_SIZES.extraTiny];
        }
        return PATTERNS[patternType] || PATTERNS.doodles;
    }, [patternType]);

    // Convert to Skia paths once
    const skiaPaths = useMemo(() => {
        return rawPaths.map(d => Skia.Path.MakeFromSVGString(d)).filter(p => !!p);
    }, [rawPaths]);

    // Get gradient colors for pattern - use patternGradient if available, fallback to soft gradient
    const patternGradientColors = useMemo(() => {
        // If theme has explicit pattern gradient colors, use them
        if ((theme as any).patternGradientColors && (theme as any).patternGradientColors.length > 0) {
            return (theme as any).patternGradientColors;
        }

        // Default soft gradient: VERY subtle muted colors that blend gently
        // Updated to be deeper and less bright based on feedback
        return isDark
            ? ['#4338CA', '#3730A3', '#5B21B6', '#6D28D9', '#7C3AED', '#0E7490', '#0F766E', '#059669', '#047857']  // Deep Indigo → Violet → Teal
            : ['#4338CA', '#4F46E5', '#6D28D9', '#7C3AED', '#8B5CF6', '#06B6D4', '#14B8A6', '#10B981', '#059669'];
    }, [(theme as any).patternGradientColors, isDark]);

    // MEMOIZE PATTERN ITEMS with position-based gradient color
    const items = useMemo(() => {
        if (skiaPaths.length === 0) return [];

        const seed = 9932;
        const cols = Math.floor(width / CELL_SIZE);
        const rows = Math.floor(height / CELL_SIZE) + 4;

        const grid = new Uint8Array(cols * rows);
        const result: {
            pathIdx: number;
            x: number;
            y: number;
            scale: number;
            rotation: number;
            opacity: number;
            gradientT: number;
        }[] = [];

        const xOffset = (width - cols * CELL_SIZE) / 2;
        const diagonalLength = Math.sqrt(width * width + height * height);

        for (let r = 0; r < rows; r++) {
            for (let c = 0; c < cols; c++) {
                if (grid[r * cols + c]) continue;

                // Lower skip probability for denser pattern
                const skipRand = rng(seed + r * 37 + c * 23);
                if (skipRand > 0.92) {
                    grid[r * cols + c] = 1;
                    continue;
                }

                // Probability of being a "Big" item
                let isBig = false;
                const rRand = rng(seed + r * 19 + c * 73);

                if (rRand > 0.92 && c < cols - 1 && r < rows - 1) {
                    if (!grid[r * cols + (c + 1)] &&
                        !grid[(r + 1) * cols + c] &&
                        !grid[(r + 1) * cols + (c + 1)]) {
                        isBig = true;
                    }
                }

                const pathIdx = Math.floor(rng(seed + r * cols + c) * skiaPaths.length);
                const rotation = (rng(seed + r * 17 + c) - 0.5) * 40;

                const cellX = c * CELL_SIZE + xOffset;
                const cellY = r * CELL_SIZE;

                // Calculate gradient position based on diagonal position
                const diagonalPos = (cellX + cellY) / diagonalLength;
                const gradientT = Math.max(0, Math.min(1, diagonalPos));

                // Dynamic Scaling
                const baseScale = isBig ? 1.4 : 0.7;
                const scaleVar = (rng(seed + r * 33 + c) - 0.5) * (isBig ? 0.15 : 0.2);
                const finalScale = baseScale + scaleVar;

                const jitterX = (rng(seed + r * 101 + c) - 0.5) * (CELL_SIZE * 0.3);
                const jitterY = (rng(seed + r * 102 + c + 1) - 0.5) * (CELL_SIZE * 0.3);

                const gridSpan = isBig ? CELL_SIZE * 2 : CELL_SIZE;
                const contentSize = 24 * finalScale;
                const centerOffset = (gridSpan - contentSize) / 2;

                const finalX = cellX + centerOffset + jitterX;
                const finalY = cellY + centerOffset + jitterY;

                const opacityMultiplier = 0.7 + rng(seed * 3 + r) * 0.5;

                result.push({
                    pathIdx,
                    x: finalX,
                    y: finalY,
                    scale: finalScale,
                    rotation,
                    opacity: opacityMultiplier,
                    gradientT
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

    const bgColors = theme.backgroundGradient;

    const vecStart = vec(0, 0);
    const vecEnd = vec(width, height);

    const basePatternOpacity = theme.patternOpacity || 0.07;

    return (
        <View style={StyleSheet.absoluteFill}>
            <Canvas style={{ flex: 1 }}>
                {/* Background Gradient */}
                <Rect x={0} y={0} width={width} height={height}>
                    <LinearGradient
                        start={vecStart}
                        end={vecEnd}
                        colors={bgColors}
                    />
                </Rect>

                {/* Pattern with gradient colors */}
                {items.map((item, i) => {
                    const skPath = skiaPaths[item.pathIdx];
                    if (!skPath) return null;

                    const itemColor = interpolateColor(patternGradientColors, item.gradientT);
                    const finalOpacity = basePatternOpacity * item.opacity;

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
                        >
                            <Path
                                path={skPath}
                                style="stroke"
                                strokeWidth={1.0 / item.scale}
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
