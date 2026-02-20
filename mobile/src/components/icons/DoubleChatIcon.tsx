import React, { useEffect } from 'react';
import Svg, { Path, G, Circle } from 'react-native-svg';
import Animated, {
    useAnimatedStyle,
    useAnimatedProps,
    useSharedValue,
    withSpring,
    withSequence,
    withTiming,
    withDelay,
    Easing,
    SharedValue
} from 'react-native-reanimated';
import { useThemeStore } from '../../lib/stores/theme-store';

interface Props {
    size?: number;
    color?: string;
    strokeWidth?: number;
    focused?: boolean;
}

const AnimatedCircle = Animated.createAnimatedComponent(Circle);

/**
 * Modern Double Chat Icon (Custom SVG with 3-Dot Minimal Animation)
 * - Exact shape matching from user-provided SVG.
 * - 3 dots centered perfectly inside the primary bubble area.
 * - Animation is a slight vertical "hop" sequence on click.
 * - Minimal scale/movement to keep dots strictly inside the bubble.
 */
export default function DoubleChatIcon({ size = 24, color = 'white', focused }: Props) {
    const scale = useSharedValue(1);
    const rotation = useSharedValue(0);
    const { colors: themeColors } = useThemeStore();

    // Y-offsets for the 3 dots (vertical hop)
    const dot1Y = useSharedValue(0);
    const dot2Y = useSharedValue(0);
    const dot3Y = useSharedValue(0);
    const dotsOpacity = useSharedValue(focused ? 1 : 0.4);

    useEffect(() => {
        if (focused) {
            // Icon transformation (Slight spring pop)
            scale.value = withSpring(1.08, { damping: 15, stiffness: 150 });
            rotation.value = withSequence(
                withTiming(-6, { duration: 60 }),
                withTiming(6, { duration: 100 }),
                withTiming(0, { duration: 100 })
            );

            dotsOpacity.value = withTiming(1, { duration: 200 });

            // Minimal vertical hop animation (just once on click)
            const hopAnim = (sv: SharedValue<number>, delay: number) => {
                sv.value = withDelay(delay, withSequence(
                    withTiming(-4, { duration: 100, easing: Easing.out(Easing.quad) }),
                    withSpring(0, { damping: 12, stiffness: 200 })
                ));
            };

            hopAnim(dot1Y, 0);
            hopAnim(dot2Y, 70);
            hopAnim(dot3Y, 140);
        } else {
            scale.value = withSpring(1, { damping: 15, stiffness: 100 });
            rotation.value = withTiming(0, { duration: 200 });
            dotsOpacity.value = withTiming(0.4, { duration: 200 });
            dot1Y.value = 0;
            dot2Y.value = 0;
            dot3Y.value = 0;
        }
    }, [focused]);

    const animatedStyle = useAnimatedStyle(() => {
        return {
            width: size,
            height: size,
            alignItems: 'center',
            justifyContent: 'center',
            transform: [
                { scale: scale.value },
                { rotate: `${rotation.value}deg` }
            ],
        };
    });

    // Use animated props to move the dots vertically inside the SVG
    const getDotProps = (sv: SharedValue<number>) => useAnimatedProps(() => ({
        transform: [{ translateY: sv.value }],
        opacity: dotsOpacity.value,
    }));

    const dot1Props = getDotProps(dot1Y);
    const dot2Props = getDotProps(dot2Y);
    const dot3Props = getDotProps(dot3Y);

    const fillColor = focused ? themeColors.bubbleMe : color;

    // Viewbox is 256x256. Primary bubble is centered roughly around X=90, Y=115
    return (
        <Animated.View style={animatedStyle}>
            <Svg width={size} height={size} viewBox="0 0 256 256">
                <G fill={fillColor}>
                    {/* Main Structure - Crisp geometry - SOLID FILL (Holes removed) */}
                    <Path
                        d="M230.53955,189.7666A80.0145,80.0145,0,0,0,169.56641,72.58691a80.00176,80.00176,0,1,0-144.106,69.17969l-6.18457,21.6499a13.99955,13.99955,0,0,0,17.30566,17.30909l21.65235-6.186a79.83787,79.83787,0,0,0,28.18994,8.88355,80.03715,80.03715,0,0,0,111.34326,39.116l21.65137,6.18653A14.00007,14.00007,0,0,0,236.7251,211.418Z"
                    />

                    {/* Inline Dots - Bunched tightly and centered in primary bubble area (Y=106) */}
                    <AnimatedCircle cx="76" cy="106" r="8" fill={fillColor} animatedProps={dot1Props} />
                    <AnimatedCircle cx="98" cy="106" r="8" fill={fillColor} animatedProps={dot2Props} />
                    <AnimatedCircle cx="120" cy="106" r="8" fill={fillColor} animatedProps={dot3Props} />
                </G>
            </Svg>
        </Animated.View>
    );
}
