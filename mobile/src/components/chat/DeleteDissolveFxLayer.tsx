import React, { useMemo } from 'react';
import { StyleSheet, View } from 'react-native';
import Animated, {
    Extrapolation,
    interpolate,
    type SharedValue,
    useAnimatedStyle,
} from 'react-native-reanimated';
import { BlurMask, Canvas, Circle, LinearGradient as SkiaLinearGradient, Rect, vec } from '@shopify/react-native-skia';

interface DeleteDissolveFxLayerProps {
    progress: SharedValue<number>;
    width: number;
    height: number;
    isMe: boolean;
    borderRadius?: number;
}

interface Piece {
    x: number;
    y: number;
    r: number;
    color: string;
    group: 0 | 1 | 2 | 3;
}

const buildPieces = (width: number, height: number, isMe: boolean): Piece[] => {
    if (width <= 0 || height <= 0) return [];
    const area = width * height;
    const count = Math.max(38, Math.min(110, Math.round(area / 240)));
    let seed = Math.floor((width * 13.1) + (height * 17.3)) + (isMe ? 29 : 61);
    const rand = () => {
        seed = (seed * 1664525 + 1013904223) >>> 0;
        return seed / 4294967296;
    };
    const palette = isMe
        ? ['rgba(255,255,255,0.48)', 'rgba(220,238,255,0.42)', 'rgba(154,216,255,0.36)', 'rgba(202,255,255,0.3)']
        : ['rgba(255,255,255,0.4)', 'rgba(214,255,245,0.33)', 'rgba(170,232,255,0.3)', 'rgba(226,246,255,0.28)'];

    return Array.from({ length: count }, () => {
        const colorIndex = Math.min(palette.length - 1, Math.floor(rand() * palette.length));
        return {
            x: rand() * width,
            y: rand() * height,
            r: 0.4 + (rand() * 1.75),
            color: palette[colorIndex],
            group: Math.floor(rand() * 4) as 0 | 1 | 2 | 3,
        };
    });
};

const ParticleCanvas = React.memo(({
    pieces,
    width,
    height,
}: {
    pieces: Piece[];
    width: number;
    height: number;
}) => (
    <Canvas style={styles.canvas} pointerEvents="none">
        <Rect x={0} y={0} width={Math.max(0, width)} height={Math.max(0, height)}>
            <SkiaLinearGradient
                start={vec(0, 0)}
                end={vec(width || 1, height || 1)}
                colors={[
                    'rgba(255,255,255,0.02)',
                    'rgba(212,245,255,0.1)',
                    'rgba(255,255,255,0.02)',
                ]}
            />
            <BlurMask blur={4} style="normal" />
        </Rect>
        {pieces.map((piece, index) => (
            <Circle key={`${index}-${piece.x.toFixed(1)}-${piece.y.toFixed(1)}`} cx={piece.x} cy={piece.y} r={piece.r} color={piece.color}>
                <BlurMask blur={1.8} style="normal" />
            </Circle>
        ))}
    </Canvas>
));

export default function DeleteDissolveFxLayer({
    progress,
    width,
    height,
    isMe,
    borderRadius = 18,
}: DeleteDissolveFxLayerProps) {
    const pieces = useMemo(() => buildPieces(width, height, isMe), [height, isMe, width]);
    const groupedPieces = useMemo(() => {
        const buckets: [Piece[], Piece[], Piece[], Piece[]] = [[], [], [], []];
        for (const piece of pieces) {
            buckets[piece.group].push(piece);
        }
        return buckets;
    }, [pieces]);
    const direction = isMe ? 1 : -1;

    const layerOneStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.1, 0.76, 1], [0, 0.96, 0.66, 0], Extrapolation.CLAMP),
        transform: [
            { scale: interpolate(progress.value, [0, 1], [0.92, 1.08], Extrapolation.CLAMP) },
            { translateX: interpolate(progress.value, [0, 1], [0, direction * 10], Extrapolation.CLAMP) },
            { translateY: interpolate(progress.value, [0, 1], [0, -14], Extrapolation.CLAMP) },
        ],
    }), [direction, progress]);

    const layerTwoStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.12, 0.8, 1], [0, 0.9, 0.64, 0], Extrapolation.CLAMP),
        transform: [
            { scale: interpolate(progress.value, [0, 1], [0.94, 1.1], Extrapolation.CLAMP) },
            { translateX: interpolate(progress.value, [0, 1], [0, direction * 16], Extrapolation.CLAMP) },
            { translateY: interpolate(progress.value, [0, 1], [0, -8], Extrapolation.CLAMP) },
        ],
    }), [direction, progress]);

    const layerThreeStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.08, 0.72, 1], [0, 0.88, 0.6, 0], Extrapolation.CLAMP),
        transform: [
            { scale: interpolate(progress.value, [0, 1], [0.92, 1.12], Extrapolation.CLAMP) },
            { translateX: interpolate(progress.value, [0, 1], [0, direction * -12], Extrapolation.CLAMP) },
            { translateY: interpolate(progress.value, [0, 1], [0, -18], Extrapolation.CLAMP) },
        ],
    }), [direction, progress]);

    const layerFourStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.14, 0.78, 1], [0, 0.86, 0.58, 0], Extrapolation.CLAMP),
        transform: [
            { scale: interpolate(progress.value, [0, 1], [0.94, 1.16], Extrapolation.CLAMP) },
            { translateX: interpolate(progress.value, [0, 1], [0, direction * -6], Extrapolation.CLAMP) },
            { translateY: interpolate(progress.value, [0, 1], [0, -22], Extrapolation.CLAMP) },
        ],
    }), [direction, progress]);

    const glowStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.12, 0.78, 1], [0, 0.75, 0.34, 0], Extrapolation.CLAMP),
        transform: [
            { scale: interpolate(progress.value, [0, 1], [0.96, 1.09], Extrapolation.CLAMP) },
            { translateY: interpolate(progress.value, [0, 1], [0, -6], Extrapolation.CLAMP) },
        ],
    }), [progress]);

    if (width <= 0 || height <= 0) return null;

    return (
        <View pointerEvents="none" style={[styles.host, { borderRadius }]}>
            <Animated.View pointerEvents="none" style={[styles.layer, glowStyle]}>
                <Canvas style={styles.canvas} pointerEvents="none">
                    <Rect x={0} y={0} width={width} height={height}>
                        <SkiaLinearGradient
                            start={vec(0, 0)}
                            end={vec(width, height)}
                            colors={['rgba(255,255,255,0.04)', 'rgba(168,235,255,0.18)', 'rgba(255,255,255,0.05)']}
                        />
                        <BlurMask blur={8} style="normal" />
                    </Rect>
                </Canvas>
            </Animated.View>

            <Animated.View pointerEvents="none" style={[styles.layer, layerOneStyle]}>
                <ParticleCanvas pieces={groupedPieces[0]} width={width} height={height} />
            </Animated.View>
            <Animated.View pointerEvents="none" style={[styles.layer, layerTwoStyle]}>
                <ParticleCanvas pieces={groupedPieces[1]} width={width} height={height} />
            </Animated.View>
            <Animated.View pointerEvents="none" style={[styles.layer, layerThreeStyle]}>
                <ParticleCanvas pieces={groupedPieces[2]} width={width} height={height} />
            </Animated.View>
            <Animated.View pointerEvents="none" style={[styles.layer, layerFourStyle]}>
                <ParticleCanvas pieces={groupedPieces[3]} width={width} height={height} />
            </Animated.View>
        </View>
    );
}

const styles = StyleSheet.create({
    host: {
        ...StyleSheet.absoluteFillObject,
        overflow: 'hidden',
    },
    layer: {
        ...StyleSheet.absoluteFillObject,
    },
    canvas: {
        ...StyleSheet.absoluteFillObject,
    },
});
