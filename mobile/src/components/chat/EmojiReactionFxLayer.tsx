import React, { useEffect, useMemo } from 'react';
import { StyleSheet, View } from 'react-native';
import Animated, {
    Easing,
    Extrapolation,
    interpolate,
    runOnJS,
    type SharedValue,
    useAnimatedStyle,
    useSharedValue,
    withTiming,
} from 'react-native-reanimated';

export interface EmojiReactionFx {
    token: number;
    x: number;
    y: number;
    color: string;
    emoji: string;
}

interface EmojiProfile {
    lifeMs: number;
    count: number;
    gravity: number;
    speed: number;
    emojiCount: number;
    emojiScale: number;
    upwardBias: number;
}

interface ParticleSpec {
    vx: number;
    vy: number;
    r: number;
}

interface EmojiSplashSpec {
    vx: number;
    vy: number;
    scale: number;
}

const resolveProfile = (emoji: string): EmojiProfile => {
    if (emoji === '❤️') {
        return { lifeMs: 520, count: 20, gravity: 30, speed: 34, emojiCount: 8, emojiScale: 1.1, upwardBias: 16 };
    }
    if (emoji === '🔥') {
        return { lifeMs: 440, count: 18, gravity: 22, speed: 32, emojiCount: 6, emojiScale: 0.94, upwardBias: 18 };
    }
    if (emoji === '⚡') {
        return { lifeMs: 360, count: 14, gravity: 44, speed: 44, emojiCount: 5, emojiScale: 0.9, upwardBias: 8 };
    }
    if (emoji === '⭐') {
        return { lifeMs: 500, count: 16, gravity: 26, speed: 30, emojiCount: 7, emojiScale: 1.02, upwardBias: 12 };
    }
    return { lifeMs: 430, count: 16, gravity: 34, speed: 30, emojiCount: 7, emojiScale: 0.96, upwardBias: 10 };
};

const ParticleDot = React.memo(({
    fx,
    color,
    gravity,
    particle,
    progress,
}: {
    fx: EmojiReactionFx;
    color: string;
    gravity: number;
    particle: ParticleSpec;
    progress: SharedValue<number>;
}) => {
    const style = useAnimatedStyle(() => {
        const t = progress.value;
        const driftX = particle.vx * t;
        const driftY = particle.vy * t + (gravity * t * t);
        const radius = Math.max(0.75, particle.r * (1 - (t * 0.74)));

        return {
            left: fx.x + driftX - radius,
            top: fx.y + driftY - radius,
            width: radius * 2,
            height: radius * 2,
            borderRadius: radius,
            opacity: interpolate(t, [0, 1], [1, 0.08], Extrapolation.CLAMP),
        };
    });

    return (
        <Animated.View
            pointerEvents="none"
            style={[styles.particle, { backgroundColor: color }, style]}
        />
    );
});

const EmojiSplash = React.memo(({
    fx,
    emoji,
    gravity,
    splash,
    progress,
}: {
    fx: EmojiReactionFx;
    emoji: string;
    gravity: number;
    splash: EmojiSplashSpec;
    progress: SharedValue<number>;
}) => {
    const style = useAnimatedStyle(() => {
        const t = progress.value;
        const driftX = splash.vx * t;
        const driftY = splash.vy * t + (gravity * t * t);
        const opacity = Math.max(0, 1 - (t * 1.2));
        const scale = splash.scale * (1 - (t * 0.26));
        return {
            left: fx.x + driftX - 9,
            top: fx.y + driftY - 10,
            opacity,
            transform: [{ scale }],
        };
    });

    return (
        <Animated.Text pointerEvents="none" style={[styles.emoji, style]}>
            {emoji}
        </Animated.Text>
    );
});

const EmojiReactionFxBurst = ({
    fx,
    onDone,
}: {
    fx: EmojiReactionFx;
    onDone: (token: number) => void;
}) => {
    const progress = useSharedValue(0);
    const profile = useMemo(() => resolveProfile(fx.emoji), [fx.emoji]);

    const particles = useMemo(() => (
        Array.from({ length: profile.count }, (_, i) => {
            const angle = ((Math.PI * 2) * i) / profile.count + ((fx.token % 9) * 0.045);
            const speed = profile.speed + ((i % 5) * 4.8);
            return {
                vx: Math.cos(angle) * speed,
                vy: Math.sin(angle) * speed * 0.72 - profile.upwardBias,
                r: 2.1 + ((i % 4) * 0.72),
            };
        })
    ), [fx.token, profile]);

    const emojiSplashes = useMemo(() => (
        Array.from({ length: profile.emojiCount }, (_, i) => {
            const angle = ((Math.PI * 2) * i) / profile.emojiCount + ((fx.token % 7) * 0.06);
            const speed = (profile.speed * 0.55) + (i * 2.8);
            return {
                vx: Math.cos(angle) * speed,
                vy: Math.sin(angle) * speed * 0.68 - (profile.upwardBias * 0.9),
                scale: profile.emojiScale + ((i % 3) * 0.12),
            };
        })
    ), [fx.token, profile]);

    useEffect(() => {
        progress.value = 0;
        progress.value = withTiming(1, {
            duration: profile.lifeMs,
            easing: Easing.out(Easing.quad),
        }, (finished) => {
            if (finished) runOnJS(onDone)(fx.token);
        });
    }, [fx.token, onDone, profile.lifeMs, progress]);

    return (
        <View style={StyleSheet.absoluteFill} pointerEvents="none">
            {particles.map((particle, i) => (
                <ParticleDot
                    key={`${fx.token}-p-${i}`}
                    fx={fx}
                    color={fx.color}
                    gravity={profile.gravity}
                    particle={particle}
                    progress={progress}
                />
            ))}

            {emojiSplashes.map((splash, i) => (
                <EmojiSplash
                    key={`${fx.token}-e-${i}`}
                    fx={fx}
                    emoji={fx.emoji}
                    gravity={profile.gravity + 10}
                    splash={splash}
                    progress={progress}
                />
            ))}
        </View>
    );
};

export default function EmojiReactionFxLayer({
    effects,
    onDone,
}: {
    effects: EmojiReactionFx[];
    onDone: (token: number) => void;
}) {
    if (effects.length === 0) return null;
    return (
        <View pointerEvents="none" style={StyleSheet.absoluteFill}>
            {effects.map((fx) => (
                <EmojiReactionFxBurst
                    key={fx.token}
                    fx={fx}
                    onDone={onDone}
                />
            ))}
        </View>
    );
}

const styles = StyleSheet.create({
    particle: {
        position: 'absolute',
    },
    emoji: {
        position: 'absolute',
        fontSize: 16,
        textShadowColor: 'rgba(0,0,0,0.2)',
        textShadowRadius: 2,
    },
});
