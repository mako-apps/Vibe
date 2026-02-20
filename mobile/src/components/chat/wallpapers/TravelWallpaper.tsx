import React, { useMemo } from 'react';
import { useWindowDimensions, StyleSheet, View } from 'react-native';
import { Canvas, Path, Skia, Group, Rect, LinearGradient, vec } from '@shopify/react-native-skia';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import { isDarkColor } from '../../../lib/utils/color';

const CELL_SIZE = 40;

const TRAVEL_PATHS = [
    // Plane
    "M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z",
    // Car
    "M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.66 0-1.21.42-1.42 1.01L3 12v8c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-1h12v1c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-8l-2.08-5.99zM6.5 16c-.83 0-1.5-.67-1.5-1.5S5.67 13 6.5 13s1.5.67 1.5 1.5S7.33 16 6.5 16zm11 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zM5 11l1.5-4.5h11L19 11H5z",
    // Briefcase
    "M20 6h-4V4c0-1.11-.89-2-2-2h-4c-1.11 0-2 .89-2 2v2H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-6 0h-4V4h4v2z",
    // Globe
    "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z",
    // Train (Simplified)
    "M12 2c-4 0-8 .5-8 4v9.5C4 17.43 5.57 19 7.5 19L6 20.5v.5h2.23l2-2H14l2 2h2v-.5L16.5 19c1.93 0 3.5-1.57 3.5-3.5V6c0-3.5-3.58-4-8-4zM7.5 17c-.83 0-1.5-.67-1.5-1.5S6.67 14 7.5 14s1.5.67 1.5 1.5S8.33 17 7.5 17zm3.5-7H6V6h5v4zm2 0V6h5v4h-5zm3.5 7c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5z",
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

export default function TravelWallpaper({
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

    const skiaPaths = useMemo(() => {
        return TRAVEL_PATHS.map(d => Skia.Path.MakeFromSVGString(d)).filter(p => !!p);
    }, []);

    const items = useMemo(() => {
        if (skiaPaths.length === 0) return [];

        const seed = 6612;
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

                if (rRand > 0.90 && c < cols - 1 && r < rows - 1) {
                    if (!grid[r * cols + (c + 1)] &&
                        !grid[(r + 1) * cols + c] &&
                        !grid[(r + 1) * cols + (c + 1)]) {
                        isBig = true;
                    }
                }

                const pathIdx = Math.floor(rng(seed + r * cols + c) * skiaPaths.length);
                const rotation = (rng(seed + r * 17 + c) - 0.5) * 45;

                const cellX = c * CELL_SIZE + xOffset;
                const cellY = r * CELL_SIZE;

                const baseScale = isBig ? 1.4 : 0.7;
                const scaleVar = (rng(seed + r * 33 + c) - 0.5) * 0.2;
                const finalScale = baseScale + scaleVar;

                const jitterX = (rng(seed + r * 101 + c) - 0.5) * (CELL_SIZE * 0.4);
                const jitterY = (rng(seed + r * 102 + c + 1) - 0.5) * (CELL_SIZE * 0.4);

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

    let doodleColor = theme.patternColor;
    if (!doodleColor) {
        doodleColor = isDark ? 'rgba(255,255,255,0.35)' : 'rgba(0,0,0,0.15)';
    }

    const vecStart = vec(0, 0);
    const vecEnd = vec(width, height);

    return (
        <View style={StyleSheet.absoluteFill}>
            <Canvas style={{ flex: 1 }}>
                <Rect x={0} y={0} width={width} height={height}>
                    <LinearGradient
                        start={vecStart}
                        end={vecEnd}
                        colors={bgColors}
                    />
                </Rect>
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
