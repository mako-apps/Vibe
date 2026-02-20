import React, { useEffect } from 'react';
import { View, StyleSheet } from 'react-native';
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
    const dotSize = size / 4; // Scale dots based on container size

    return (
        <View style={[styles.dotsContainer, { height: size, gap: dotSize / 2 }]}>
            {dots.map((i) => (
                <Dot key={i} index={i} size={dotSize} color={color} />
            ))}
        </View>
    );
};

const Dot: React.FC<{ index: number; size: number; color: string }> = ({ index, size, color }) => {
    const opacity = useSharedValue(0.3);
    const scale = useSharedValue(1);

    useEffect(() => {
        const delay = index * 150;

        opacity.value = withDelay(
            delay,
            withRepeat(
                withSequence(
                    withTiming(1, { duration: 400, easing: Easing.ease }),
                    withTiming(0.3, { duration: 400, easing: Easing.ease })
                ),
                -1,
                true
            )
        );

        scale.value = withDelay(
            delay,
            withRepeat(
                withSequence(
                    withTiming(1.2, { duration: 400, easing: Easing.ease }),
                    withTiming(1, { duration: 400, easing: Easing.ease })
                ),
                -1,
                true
            )
        );
    }, []);

    const animatedStyle = useAnimatedStyle(() => ({
        opacity: opacity.value,
        transform: [{ scale: scale.value }]
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
