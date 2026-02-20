import React, { useMemo } from 'react';
import { useWindowDimensions, StyleSheet, View } from 'react-native';
import { Canvas, Path, Skia, Group, Rect, LinearGradient, vec } from '@shopify/react-native-skia';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import { isDarkColor } from '../../../lib/utils/color';

const CELL_SIZE = 40; // Slightly larger for music icons

// Modern Music Shapes
const MUSIC_PATHS = [
    // Eighth note
    "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z",
    // Beamed notes
    "M9 18V5l12-2v13",
    // Vinyl Record
    "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 14.5c-2.49 0-4.5-2.01-4.5-4.5S9.51 7.5 12 7.5s4.5 2.01 4.5 4.5-2.01 4.5-4.5 4.5zm0-5.5c-.55 0-1 .45-1 1s.45 1 1 1 1-.45 1-1-.45-1-1-1z",
    // Headphones (Simplified)
    "M12 3a9 9 0 0 0-9 9v7c0 1.66 1.34 3 3 3h3v-8H5v-2c0-3.87 3.13-7 7-7s7 3.13 7 7v2h-4v8h3c1.66 0 3-1.34 3-3v-7a9 9 0 0 0-9-9z",
    // Waveform / Equalizer
    "M4 17h2v-6H4v6zm4 2h2V9H8v10zm4-6h2v-4h-2v4zm4 4h2v-8h-2v8zm4-2h2v-4h-2v4z",
    // Play Button Circle
    "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 14.5v-9l6 4.5-6 4.5z",
];

interface Props {
    theme: ChatTheme;
    width?: number;
    height?: number;
}

const rng = (seed: number) => {
    const x = Math.sin(seed) * 10000;
    return x - Math.floor(x);
};

export default function MusicWallpaper({
    theme,
    width: propWidth,
    height: propHeight,
}: Props) {
    const dims = useWindowDimensions();
    const width = propWidth || dims.width;
    const height = propHeight || dims.height;

    // Determine if background is dark based on the gradient start color
    const bgStart = theme.backgroundGradient?.[0];
    const isDark = bgStart ? isDarkColor(bgStart) : false;

    // Convert to Skia paths once
    const skiaPaths = useMemo(() => {
        return MUSIC_PATHS.map(d => Skia.Path.MakeFromSVGString(d)).filter(p => !!p);
    }, []);

    // MEMOIZE PATTERN ITEMS
    const items = useMemo(() => {
        if (skiaPaths.length === 0) return [];

        const seed = 4421; // Different seed
        const cols = Math.floor(width / CELL_SIZE);
        const rows = Math.floor(height / CELL_SIZE) + 2;

        const grid = new Uint8Array(cols * rows);
        const result: { pathIdx: number; x: number; y: number; scale: number; rotation: number; opacity: number }[] = [];

        const xOffset = (width - cols * CELL_SIZE) / 2;

        for (let r = 0; r < rows; r++) {
            for (let c = 0; c < cols; c++) {
                if (grid[r * cols + c]) continue;

                let isBig = false;
                const rRand = rng(seed + r * 19 + c * 73);

                // Fewer big items for music to keep it clean
                if (rRand > 0.92 && c < cols - 1 && r < rows - 1) {
                    if (!grid[r * cols + (c + 1)] &&
                        !grid[(r + 1) * cols + c] &&
                        !grid[(r + 1) * cols + (c + 1)]) {
                        isBig = true;
                    }
                }

                const pathIdx = Math.floor(rng(seed + r * cols + c) * skiaPaths.length);
                const rotation = (rng(seed + r * 17 + c) - 0.5) * 60; // More rotation for music notes

                const cellX = c * CELL_SIZE + xOffset;
                const cellY = r * CELL_SIZE;

                const baseScale = isBig ? 1.4 : 0.7;
                const scaleVar = (rng(seed + r * 33 + c) - 0.5) * 0.2;
                const finalScale = baseScale + scaleVar;

                const jitterX = (rng(seed + r * 101 + c) - 0.5) * (CELL_SIZE * 0.5);
                const jitterY = (rng(seed + r * 102 + c + 1) - 0.5) * (CELL_SIZE * 0.5);

                const gridSpan = isBig ? CELL_SIZE * 2 : CELL_SIZE;
                const contentSize = 24 * finalScale;
                const centerOffset = (gridSpan - contentSize) / 2;

                const finalX = cellX + centerOffset + jitterX;
                const finalY = cellY + centerOffset + jitterY;

                const opacityMultiplier = 0.7 + rng(seed * 3 + r) * 0.3;

                result.push({
                    pathIdx,
                    x: finalX,
                    y: finalY,
                    scale: finalScale,
                    rotation,
                    opacity: opacityMultiplier
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

    // Auto-detect best doodle color based on dark/light mode
    // Using higher contrast values for better visibility
    let doodleColor = theme.patternColor;
    if (!doodleColor) {
        doodleColor = isDark ? 'rgba(255,255,255,0.35)' : 'rgba(0,0,0,0.15)';
    }

    const vecStart = vec(0, 0);
    const vecEnd = vec(width, height);

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

                {/* Pattern */}
                {items.map((item, i) => {
                    const skPath = skiaPaths[item.pathIdx];
                    if (!skPath) return null;

                    const finalOpacity = (theme.patternOpacity || 0.5) * item.opacity;

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
                                strokeWidth={1.5 / item.scale}
                                strokeCap="round"
                                strokeJoin="round"
                                color={doodleColor}
                            />
                        </Group>
                    );
                })}
            </Canvas>
        </View>
    );
}
