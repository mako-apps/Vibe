import React, { useMemo } from 'react';
import { useWindowDimensions, StyleSheet, View } from 'react-native';
import { Canvas, Path, Skia, Group, Rect, LinearGradient, vec } from '@shopify/react-native-skia';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import { isDarkColor } from '../../../lib/utils/color';

const CELL_SIZE = 40;

const TECH_PATHS = [
    // Smartphone
    "M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99zM17 19H7V5h10v14z",
    // Laptop
    "M20 18c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2H4c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2H0v2h24v-2h-4zM4 6h16v10H4V6z",
    // Mouse
    "M13 1.07V9h7c0-4.08-3.05-7.44-6.98-7.93zM4 15c0 4.42 3.58 8 8 8s8-3.58 8-8v-4H4v4zm7-13.93C7.05 1.56 4 4.92 4 9h7V1.07z",
    // Code / Brackets
    "M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z",
    // Wifi
    "M12.01 21.49L23.64 7c-.45-.34-4.93-4-11.64-4C5.28 3 .81 6.66.36 7l11.63 14.49.01.01.01-.01z",
    // Battery
    "M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4z",
    // Gamepad
    "M21 6H3c-1.1 0-2 .9-2 2v8c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-10 7H8v3H6v-3H3v-2h3V8h2v3h3v2zm4.5 2c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm4-3c-.83 0-1.5-.67-1.5-1.5S19.67 9 20.5 9s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"
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

export default function TechWallpaper({
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
        return TECH_PATHS.map(d => Skia.Path.MakeFromSVGString(d)).filter(p => !!p);
    }, []);

    const items = useMemo(() => {
        if (skiaPaths.length === 0) return [];

        const seed = 8845;
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

                if (rRand > 0.92 && c < cols - 1 && r < rows - 1) {
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
