import React from 'react';
import { View, Text, StyleSheet, Dimensions } from 'react-native';
import { useThemeStore } from '../../lib/stores/theme-store';
import { MessageCircle, Lock, Shield } from 'lucide-react-native';
import Animated, {
    FadeIn,
    useSharedValue,
    useAnimatedStyle,
    withRepeat,
    withTiming,
    withDelay,
    withSequence
} from 'react-native-reanimated';
import { useEffect } from 'react';
import Svg, { Circle, Path, Defs, LinearGradient, Stop } from 'react-native-svg';

const { width } = Dimensions.get('window');

interface EmptyChatStateProps {
    friendName?: string;
}

// Animated Double Bubble Icon
const AnimatedBubbles = ({ color }: { color: string }) => {
    const scale1 = useSharedValue(1);
    const scale2 = useSharedValue(1);
    const opacity1 = useSharedValue(0.8);
    const opacity2 = useSharedValue(0.6);

    useEffect(() => {
        scale1.value = withRepeat(
            withSequence(
                withTiming(1.05, { duration: 1500 }),
                withTiming(1, { duration: 1500 })
            ),
            -1,
            true
        );

        scale2.value = withDelay(
            500,
            withRepeat(
                withSequence(
                    withTiming(1.08, { duration: 1800 }),
                    withTiming(1, { duration: 1800 })
                ),
                -1,
                true
            )
        );

        opacity1.value = withRepeat(
            withSequence(
                withTiming(1, { duration: 1500 }),
                withTiming(0.7, { duration: 1500 })
            ),
            -1,
            true
        );
    }, []);

    const bubble1Style = useAnimatedStyle(() => ({
        transform: [{ scale: scale1.value }],
        opacity: opacity1.value
    }));

    const bubble2Style = useAnimatedStyle(() => ({
        transform: [{ scale: scale2.value }],
        opacity: opacity2.value
    }));

    return (
        <View style={styles.bubblesContainer}>
            <Animated.View style={[styles.bubbleWrapper, bubble1Style, { left: -15, top: -10 }]}>
                <Svg width={80} height={60} viewBox="0 0 80 60">
                    <Defs>
                        <LinearGradient id="bubble1Grad" x1="0%" y1="0%" x2="100%" y2="100%">
                            <Stop offset="0%" stopColor={color} stopOpacity="0.3" />
                            <Stop offset="100%" stopColor={color} stopOpacity="0.15" />
                        </LinearGradient>
                    </Defs>
                    <Path
                        d="M 10 10 Q 10 5 20 5 L 60 5 Q 70 5 70 15 L 70 35 Q 70 45 60 45 L 25 45 L 15 55 L 18 45 L 20 45 Q 10 45 10 35 Z"
                        fill="url(#bubble1Grad)"
                        stroke={color}
                        strokeWidth="1"
                        strokeOpacity="0.3"
                    />
                </Svg>
            </Animated.View>

            <Animated.View style={[styles.bubbleWrapper, bubble2Style, { right: -20, top: 15 }]}>
                <Svg width={70} height={55} viewBox="0 0 70 55">
                    <Defs>
                        <LinearGradient id="bubble2Grad" x1="0%" y1="0%" x2="100%" y2="100%">
                            <Stop offset="0%" stopColor={color} stopOpacity="0.25" />
                            <Stop offset="100%" stopColor={color} stopOpacity="0.1" />
                        </LinearGradient>
                    </Defs>
                    <Path
                        d="M 5 10 Q 5 5 15 5 L 50 5 Q 60 5 60 15 L 60 30 Q 60 40 50 40 L 45 40 L 55 50 L 40 40 L 15 40 Q 5 40 5 30 Z"
                        fill="url(#bubble2Grad)"
                        stroke={color}
                        strokeWidth="1"
                        strokeOpacity="0.2"
                    />
                </Svg>
            </Animated.View>
        </View>
    );
};

export default function EmptyChatState({ friendName }: EmptyChatStateProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const isDark = effectiveTheme === 'dark';

    return (
        <Animated.View
            entering={FadeIn.duration(400)}
            style={styles.container}
        >
            <View style={styles.iconContainer}>
                <AnimatedBubbles color={colors.primary} />
            </View>

            <Text style={[styles.title, { color: colors.text }]}>
                {friendName ? `Start chatting with ${friendName}` : 'No messages yet'}
            </Text>

            <Text style={[styles.subtitle, { color: colors.textSecondary }]}>
                Send a message to start the conversation
            </Text>

            <View style={styles.securityBadge}>
                <View style={[styles.badgePill, { backgroundColor: isDark ? 'rgba(94, 177, 178, 0.1)' : 'rgba(13, 148, 136, 0.08)' }]}>
                    <Lock size={12} color={colors.primary} />
                    <Text style={[styles.badgeText, { color: colors.primary }]}>
                        End-to-end encrypted
                    </Text>
                </View>
            </View>
        </Animated.View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        paddingHorizontal: 40,
        paddingBottom: 100,
    },
    iconContainer: {
        width: 120,
        height: 100,
        marginBottom: 24,
        position: 'relative',
    },
    bubblesContainer: {
        width: '100%',
        height: '100%',
        position: 'relative',
    },
    bubbleWrapper: {
        position: 'absolute',
    },
    title: {
        fontSize: 20,
        fontWeight: '600',
        textAlign: 'center',
        marginBottom: 8,
    },
    subtitle: {
        fontSize: 15,
        textAlign: 'center',
        opacity: 0.7,
        lineHeight: 22,
    },
    securityBadge: {
        marginTop: 24,
    },
    badgePill: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        paddingVertical: 6,
        borderRadius: 20,
        gap: 6,
    },
    badgeText: {
        fontSize: 12,
        fontWeight: '500',
    },
});
