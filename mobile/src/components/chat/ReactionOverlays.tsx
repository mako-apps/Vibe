import React, { useEffect } from 'react';
import { StyleSheet, Text } from 'react-native';
import Animated, {
    Easing,
    Extrapolation,
    interpolate,
    runOnJS,
    useAnimatedStyle,
    useSharedValue,
    withSequence,
    withSpring,
    withTiming,
} from 'react-native-reanimated';

import EmojiReactionFxLayer, { type EmojiReactionFx } from './EmojiReactionFxLayer';

export interface ReactionFlyFx {
    token: number;
    emoji: string;
    startX: number;
    startY: number;
    targetX: number;
    targetY: number;
    durationMs: number;
}

const ReactionFlyOverlay = React.memo(({
    fx,
    onDone,
}: {
    fx: ReactionFlyFx;
    onDone: (token: number) => void;
}) => {
    const progress = useSharedValue(0);
    const flyScale = useSharedValue(0);
    const landBounce = useSharedValue(0);
    const wobble = useSharedValue(0);

    useEffect(() => {
        flyScale.value = withSequence(
            withTiming(1.65, {
                duration: Math.round(fx.durationMs * 0.12),
                easing: Easing.out(Easing.back(2)),
            }),
            withTiming(0.5, {
                duration: Math.round(fx.durationMs * 0.88),
                easing: Easing.bezier(0.25, 0.1, 0.25, 1),
            })
        );

        wobble.value = withSequence(
            withTiming(-12, { duration: Math.round(fx.durationMs * 0.15), easing: Easing.out(Easing.quad) }),
            withTiming(8, { duration: Math.round(fx.durationMs * 0.2), easing: Easing.inOut(Easing.quad) }),
            withTiming(-4, { duration: Math.round(fx.durationMs * 0.2), easing: Easing.inOut(Easing.quad) }),
            withTiming(0, { duration: Math.round(fx.durationMs * 0.45), easing: Easing.out(Easing.cubic) })
        );

        progress.value = withTiming(1, {
            duration: fx.durationMs,
            easing: Easing.bezier(0.22, 0.68, 0.35, 1),
        }, (finished) => {
            if (!finished) return;
            landBounce.value = withSequence(
                withTiming(1, { duration: 60, easing: Easing.out(Easing.quad) }),
                withSpring(0, { damping: 14, stiffness: 400, mass: 0.4 })
            );
            runOnJS(onDone)(fx.token);
        });
    }, [fx.token, fx.durationMs, onDone, progress, flyScale, landBounce, wobble]);

    const flyStyle = useAnimatedStyle(() => {
        const t = progress.value;
        const inv = 1 - t;
        const distY = Math.abs(fx.targetY - fx.startY);
        const distX = Math.abs(fx.targetX - fx.startX);
        const rawArc = 60 + (distY * 0.45) + (distX * 0.12);
        const arc = Math.max(50, Math.min(rawArc, 140));

        const controlX = ((fx.startX + fx.targetX) / 2) + ((fx.targetX - fx.startX) * 0.1);
        const controlY = Math.min(fx.startY, fx.targetY) - arc;
        const x = (inv * inv * fx.startX) + (2 * inv * t * controlX) + (t * t * fx.targetX);
        const y = (inv * inv * fx.startY) + (2 * inv * t * controlY) + (t * t * fx.targetY);

        const bounceY = landBounce.value * -6;
        const bounceScaleX = 1 + (landBounce.value * 0.15);
        const bounceScaleY = 1 - (landBounce.value * 0.1);

        return {
            position: 'absolute' as const,
            left: x - 14,
            top: y + bounceY - 14,
            width: 28,
            height: 28,
            zIndex: 99999,
            transform: [
                { scale: flyScale.value * bounceScaleX },
                { scaleY: bounceScaleY },
                { rotate: `${wobble.value}deg` },
            ],
            opacity: interpolate(t, [0, 0.06], [0, 1], Extrapolation.CLAMP),
        };
    });

    return (
        <Animated.View pointerEvents="none" style={flyStyle}>
            <Text style={styles.reactionFlyEmoji}>{fx.emoji}</Text>
        </Animated.View>
    );
});

interface ReactionOverlaysProps {
    reactionFxList: EmojiReactionFx[];
    reactionFlyFx: ReactionFlyFx | null;
    onReactionFxDone: (token: number) => void;
    onReactionFlyDone: (token: number) => void;
}

const ReactionOverlays = React.memo(({
    reactionFxList,
    reactionFlyFx,
    onReactionFxDone,
    onReactionFlyDone,
}: ReactionOverlaysProps) => {
    if (reactionFxList.length === 0 && !reactionFlyFx) return null;
    return (
        <>
            {reactionFlyFx && (
                <ReactionFlyOverlay
                    fx={reactionFlyFx}
                    onDone={onReactionFlyDone}
                />
            )}
            <EmojiReactionFxLayer
                effects={reactionFxList}
                onDone={onReactionFxDone}
            />
        </>
    );
});

export default ReactionOverlays;

const styles = StyleSheet.create({
    reactionFlyEmoji: {
        fontSize: 28,
        lineHeight: 30,
        textAlign: 'center',
    },
});

