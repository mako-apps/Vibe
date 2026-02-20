import React, { useMemo } from 'react';
import { useWindowDimensions, StyleSheet, View } from 'react-native';
import { Canvas, Path, Skia, Group, Rect, LinearGradient, vec } from '@shopify/react-native-skia';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import { isDarkColor } from '../../../lib/utils/color';

const CELL_SIZE = 40;

const WEATHER_PATHS = [
    // Sun
    "M6.99 11L3 15l3.99 4L12 14l3.01 5L19 15l-3.99-4L19 7l-3.99-4L12 8 8.99 3 5 7l3.99 4z", // Star/Sun shape abstract
    "M12 7c-2.76 0-5 2.24-5 5s2.24 5 5 5 5-2.24 5-5-2.24-5-5-5zm0 2c1.65 0 3 1.35 3 3s-1.35 3-3 3-3-1.35-3-3 1.35-3 3-3zM2 13h2c.55 0 1-.45 1-1s-.45-1-1-1H2c-.55 0-1 .45-1 1s.45 1 1 1zm18 0h2c.55 0 1-.45 1-1s-.45-1-1-1h-2c-.55 0-1 .45-1 1s.45 1 1 1zM11 2v2c0 .55.45 1 1 1s1-.45 1-1V2c0-.55-.45-1-1-1s-1 .45-1 1zm0 18v2c0 .55.45 1 1 1s1-.45 1-1v-2c0-.55-.45-1-1-1s-1 .45-1 1zM5.99 4.93l1.41 1.41c.39.39 1.02.39 1.41 0 .39-.39.39-1.02 0-1.41L7.4 3.52c-.39-.39-1.02-.39-1.41 0-.39.39-.39 1.02 0 1.41zm11.31 11.31l1.41 1.41c.39.39 1.02.39 1.41 0 .39-.39.39-1.02 0-1.41l-1.41-1.41c-.39-.39-1.02-.39-1.41 0-.39.39-.39 1.02 0 1.41zM5.99 19.07c-.39.39-.39 1.02 0 1.41.39.39 1.02.39 1.41 0l1.41-1.41c.39-.39.39-1.02 0-1.41-.39-.39-1.02-.39-1.41 0L5.99 19.07zm12.31-14.14c-.39.39-.39 1.02 0 1.41.39.39 1.02.39 1.41 0l1.41-1.41c.39-.39.39-1.02 0-1.41-.39-.39-1.02-.39-1.41 0l-1.41 1.41z",
    // Cloud
    "M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z",
    // Rain
    "M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM13 14h-2l-3 5h2l3-5zm4 0h-2l-3 5h2l3-5z",
    // Snowflake (Simplified)
    "M19.8 14.8l-1.8-1.8c.1-.3.2-.7.2-1 0-.3-.1-.7-.2-1l1.8-1.8c.4-.4.4-1 0-1.4l-1.4-1.4c-.4-.4-1-.4-1.4 0l-1.8 1.8c-.3-.1-.7-.2-1-.2-.3 0-.7.1-1 .2l-1.8-1.8c-.4-.4-1-.4-1.4 0L8.6 8.6c-.4.4-.4 1 0 1.4l1.8 1.8c-.1.3-.2.7-.2 1 0 .3.1.7.2 1L8.6 15.6c-.4.4-.4 1 0 1.4l1.4 1.4c.4.4 1 .4 1.4 0l1.8-1.8c.3.1.7.2 1 .2.3 0 .7-.1 1-.2l1.8 1.8c.4.4 1 .4 1.4 0l1.4-1.4c.4-.4.4-1 0-1.4zM12 14c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z",
    // Lightning
    "M7 2v11h3v9l7-12h-4l4-8z",
    // Umbrella
    "M12 6c1.1 0 2 .9 2 2s-.9 2-2 2-2-.9-2-2 .9-2 2-2m0-2C9.79 4 8 5.79 8 8s1.79 4 4 4 4-1.79 4-4-1.79-4-4-4zm0 10c-3.31 0-6 2.69-6 6h2c0-2.21 1.79-4 4-4s4 1.79 4 4h2c0-3.31-2.69-6-6-6z"
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

export default function WeatherWallpaper({
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
        return WEATHER_PATHS.map(d => Skia.Path.MakeFromSVGString(d)).filter(p => !!p);
    }, []);

    const items = useMemo(() => {
        if (skiaPaths.length === 0) return [];

        const seed = 7789;
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
                const rotation = (rng(seed + r * 17 + c) - 0.5) * 30;

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
