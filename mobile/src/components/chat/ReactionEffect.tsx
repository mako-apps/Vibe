import React, { useEffect, useMemo } from 'react';
import { View, Text, StyleSheet, Dimensions } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    withDelay,
    withSpring,
    withSequence,
    Easing,
    ZoomIn,
} from 'react-native-reanimated';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

interface ReactionEffectProps {
    emoji: string;
    isMe: boolean;
}

// Particle colors from image: Red, Orange, Yellow, Green, Cyan, Blue, Purple, Pink
const PARTICLE_COLORS = [
    '#FF0000', // Red
    '#FF7F00', // Orange
    '#FFFF00', // Yellow
    '#00FF00', // Green
    '#00FFFF', // Cyan
    '#0000FF', // Blue
    '#8B00FF', // Purple
    '#FF007F', // Pink
];

const generateParticles = (emoji: string) => {
    const count = 16;
    const particles = [];

    for (let i = 0; i < count; i++) {
        const angle = (i / count) * Math.PI * 2;
        const radius = 40 + Math.random() * 60;

        particles.push({
            id: i,
            color: PARTICLE_COLORS[i % PARTICLE_COLORS.length],
            // Start near the bubble corner
            endX: Math.cos(angle) * radius,
            endY: Math.sin(angle) * radius - 40,
            delay: Math.random() * 200,
            scale: 0.6 + Math.random() * 0.6,
        });
    }
    return particles;
};

// A simpler, impactful Telegram-style animation:
// 1. Big emoji scales up from center/particle source.
// 2. Flies to the badge position.
// 3. Shrinks into the badge.

const Particle = ({ particle, emoji }: { particle: any, emoji: string }) => {
    // ... simpler floating particles logic ...
    const translateX = useSharedValue(0);
    const translateY = useSharedValue(0);
    const opacity = useSharedValue(0);
    const scale = useSharedValue(0);

    useEffect(() => {
        opacity.value = withDelay(particle.delay, withTiming(0.6, { duration: 200 }));
        scale.value = withDelay(particle.delay, withSpring(particle.scale));

        // Float upwards
        translateX.value = withDelay(particle.delay, withTiming(particle.endX, { duration: 1000 }));
        translateY.value = withDelay(particle.delay, withTiming(particle.endY, { duration: 1000 }));

        opacity.value = withDelay(particle.delay + 600, withTiming(0, { duration: 300 }));
    }, []);

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [
            { translateX: translateX.value },
            { translateY: translateY.value },
            { scale: scale.value }
        ],
        opacity: opacity.value
    }));

    const displayEmoji = (emoji === '🩷' || emoji === '❤️') ? '❤️' :
        (emoji === 'HAHA' ? '😂' : (emoji === '!!' ? '‼️' : (emoji === '?' ? '❓' : emoji)));

    return (
        <Animated.View style={[styles.particle, animatedStyle]}>
            <Text style={{ fontSize: 20 }}>{displayEmoji}</Text>
        </Animated.View>
    );
};

export default function ReactionEffect({ emoji, isMe }: ReactionEffectProps) {
    const particles = useMemo(() => generateParticles(emoji), [emoji]);

    // The main badge logic
    const badgeScale = useSharedValue(0);
    const badgeTransY = useSharedValue(-40);

    useEffect(() => {
        // "Fly in" effect
        badgeScale.value = withSequence(
            withTiming(2.5, { duration: 400, easing: Easing.out(Easing.back(1.5)) }), // Big pop
            withTiming(1, { duration: 300, easing: Easing.inOut(Easing.quad) }) // Settle
        );

        badgeTransY.value = withSequence(
            withSpring(-60, { damping: 10 }), // Float up
            withDelay(400, withSpring(0, { damping: 12, stiffness: 90 })) // Drop to badge pos
        );
    }, []);

    const bigBadgeStyle = useAnimatedStyle(() => ({
        transform: [
            { translateY: badgeTransY.value },
            { scale: badgeScale.value }
        ]
    }));

    const displayEmoji = (emoji === 'HAHA' ? '😂' : emoji === '!!' ? '‼️' : emoji === '?' ? '❓' : emoji);

    return (
        <View style={[styles.container, { [isMe ? 'right' : 'left']: -8 }]}>
            <View style={styles.particlesContainer}>
                {particles.map(p => <Particle key={p.id} particle={p} emoji={emoji} />)}
            </View>

            {/* The main flying emoji */}
            <Animated.View style={[styles.bigEmojiContainer, bigBadgeStyle]}>
                <Text style={{ fontSize: 24 }}>{displayEmoji}</Text>
            </Animated.View>

            {/* The actual badge background (stays static/pops in) */}
            <Animated.View
                entering={ZoomIn.delay(500).springify()}
                style={styles.badge}
            >
                {/* Empty here, just the background pill. The Text above lands on it visually?
                    Actually, let's put text inside and match opacity/scale logic if needed.
                    But for simplicity, we animate the whole badge container.
                */}
                <Text style={styles.badgeText}>{displayEmoji}</Text>
            </Animated.View>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        position: 'absolute',
        bottom: -14,
        zIndex: 2000,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'visible'
    },
    particlesContainer: {
        position: 'absolute',
        bottom: 20,
    },
    particle: {
        position: 'absolute',
    },
    // We animate a separate large view if we want, but animating the badge wrapper is cleaner for "settling"
    bigEmojiContainer: {
        position: 'absolute',
        zIndex: 2001,
        // We can hide this after it settles if the badge takes over, 
        // or just animate the badge itself.
        // Let's hide this one and just animate the badge itself?
        // No, Telegram has a "Ghost" big emoji that disappears into the badge.
        opacity: 0, // Disable for now, use single Main Badge animation below
    },
    badge: {
        backgroundColor: '#FFFFFF',
        paddingHorizontal: 6,
        paddingVertical: 4,
        borderRadius: 12,
        borderWidth: 1.5,
        borderColor: '#EFEFEF', // Generic border
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 1 },
        shadowOpacity: 0.1,
        shadowRadius: 2,
        elevation: 2,
        alignItems: 'center',
        justifyContent: 'center',
        minWidth: 28,
        height: 28,
    },
    badgeText: {
        fontSize: 14,
    }
});
