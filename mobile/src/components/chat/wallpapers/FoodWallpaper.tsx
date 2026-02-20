import React, { useMemo } from 'react';
import { useWindowDimensions, StyleSheet, View } from 'react-native';
import { Canvas, Path, Skia, Group, Rect, LinearGradient, vec } from '@shopify/react-native-skia';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import { isDarkColor } from '../../../lib/utils/color';

const CELL_SIZE = 90;

const FOOD_PATHS = [
    // Pizza
    "M12 2L4 20h16L12 2zm0 6a2 2 0 110 4 2 2 0 010-4zm-3 8a1 1 0 110 2 1 1 0 010-2zm6 0a1 1 0 110 2 1 1 0 010-2",
    // Ice cream
    "M8 10a4 4 0 118 0c0 4-4 12-4 12s-4-8-4-12zM8 10l8-3",
    // Burger (Simplified)
    "M20 12c0-1.1-.9-2-2-2V6c0-2.21-1.79-4-4-4H9C6.79 2 5 3.79 5 6v4c-1.1 0-2 .9-2 2v2h18v-2zM5 16h14v2H5z",
    // Apple
    "M12 2c-2.5 0-4.5 2-4.5 4.5 0 1.28.53 2.47 1.43 3.32C8.36 10.42 8 11.16 8 12c0 2.21 1.79 4 4 4s4-1.79 4-4c0-.84-.36-1.58-.93-2.18.9-.85 1.43-2.04 1.43-3.32C16.5 4 14.5 2 12 2zm-1 8h2v3h-2v-3z",
    // Coffee cup
    "M18.5 4h-1c-2.1 0-3.9 1.5-4.3 3.5-.1 2-1.7 3.5-3.7 3.5-2 0-3.6-1.5-3.8-3.5C5.4 5.5 3.6 4 1.5 4h-.2C.6 4 0 4.6 0 5.3V9c0 4.4 3.6 8 8 8h1c4.4 0 8-3.6 8-8V5.3c0-.7-.6-1.3-1.3-1.3zM17 10h-2c-1.1 0-2-.9-2-2V6h4v4z",
    // Carrot
    "M19.8 4.2L16 8l-2.8-2.8c-.8-.8-2-.8-2.8 0L9 6.6 6.8 4.4c-.4-.4-1-.4-1.4 0L4.2 5.6c-.4.4-.4 1 0 1.4l2.2 2.2-1.4 1.4c-2.4 2.4-2.4 6.2 0 8.5.6.6 2.5 1.5 3.5 1.5s2.9-.9 3.5-1.5c2.4-2.4 2.4-6.2 0-8.5L13.4 9l3.8-3.8z",
    // Cherry
    "M19 4L13 14c0 2.2-1.8 4-4 4s-4-1.8-4-4 1.8-4 4-4c.6 0 1.1.1 1.6.4L15.2 2H19v2z"
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

export default function FoodWallpaper({
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
        return FOOD_PATHS.map(d => Skia.Path.MakeFromSVGString(d)).filter(p => !!p);
    }, []);

    const items = useMemo(() => {
        if (skiaPaths.length === 0) return [];

        const seed = 5532;
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

                if (rRand > 0.88 && c < cols - 1 && r < rows - 1) {
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

                const baseScale = isBig ? 2.4 : 1.6;
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
                                strokeWidth={2.5 / item.scale}
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
