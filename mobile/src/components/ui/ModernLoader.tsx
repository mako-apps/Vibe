import React, { useEffect } from 'react';
import { Platform, StyleSheet, useColorScheme, View } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withRepeat,
    withTiming,
    Easing,
    cancelAnimation,
    withSequence,
    withDelay
} from 'react-native-reanimated';

interface LoaderProps {
    size?: number;
    color?: string;
    type?: 'spinner' | 'dots';
}

export const ModernLoader: React.FC<LoaderProps> = ({
    size = 24,
    color = '#fff',
    type = 'spinner'
}) => {
    if (type === 'dots') {
        return <DotsLoader size={size} color={color} />;
    }
    return <SpinnerLoader size={size} color={color} />;
};

const SpinnerLoader: React.FC<{ size: number; color: string }> = ({ size, color }) => {
    const rotation = useSharedValue(0);

    useEffect(() => {
        rotation.value = withRepeat(
            withTiming(360, {
                duration: 1000,
                easing: Easing.linear,
            }),
            -1,
            false
        );
        return () => cancelAnimation(rotation);
    }, []);

    const animatedStyle = useAnimatedStyle(() => {
        return {
            transform: [{ rotate: `${rotation.value}deg` }],
        };
    });

    return (
        <View style={{ width: size, height: size, justifyContent: 'center', alignItems: 'center' }}>
            <Animated.View
                style={[
                    styles.spinner,
                    animatedStyle,
                    {
                        width: size,
                        height: size,
                        borderRadius: size / 2,
                        borderWidth: size / 8, // Thinner border
                        borderColor: color,
                        borderTopColor: 'transparent',
                        borderRightColor: 'transparent', // Make it 50% arc
                    },
                ]}
            />
        </View>
    );
};

const DotsLoader: React.FC<{ size: number; color: string }> = ({ size, color }) => {
    // 3 dots
    const dots = [0, 1, 2];
    // Luxurious feel often comes from smaller, more delicate elements
    const dotSize = Math.max(3.5, size / 9);

    return (
        <View style={[styles.dotsContainer, { height: size, gap: dotSize * 1.5 }]}>
            {dots.map((i) => (
                <Dot key={i} index={i} size={dotSize} color={color} />
            ))}
        </View>
    );
};

const Dot: React.FC<{ index: number; size: number; color: string }> = ({ index, size, color }) => {
    const opacity = useSharedValue(0.2);
    const translateY = useSharedValue(0);

    useEffect(() => {
        const delay = index * 120;
        const duration = 500;
        const ease = Easing.bezier(0.25, 0.1, 0.25, 1);

        opacity.value = withDelay(
            delay,
            withRepeat(
                withSequence(
                    withTiming(1, { duration: duration * 0.6, easing: ease }),
                    withTiming(0.2, { duration: duration * 0.8, easing: ease }),
                    withTiming(0.2, { duration: duration * 0.4, easing: Easing.linear })
                ),
                -1,
                false
            )
        );

        translateY.value = withDelay(
            delay,
            withRepeat(
                withSequence(
                    withTiming(-size * 0.6, { duration: duration * 0.6, easing: ease }),
                    withTiming(0, { duration: duration * 0.8, easing: ease }),
                    withTiming(0, { duration: duration * 0.4, easing: Easing.linear })
                ),
                -1,
                false
            )
        );
    }, []);

    const animatedStyle = useAnimatedStyle(() => ({
        opacity: opacity.value,
        transform: [{ translateY: translateY.value }]
    }));

    return (
        <Animated.View
            style={[
                {
                    width: size,
                    height: size,
                    borderRadius: size / 2,
                    backgroundColor: color,
                },
                animatedStyle
            ]}
        />
    );
};

const styles = StyleSheet.create({
    spinner: {
        opacity: 0.9,
    },
    dotsContainer: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
    },
});
