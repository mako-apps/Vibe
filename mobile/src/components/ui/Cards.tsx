import React, { useEffect, useState } from 'react';
import { View, StyleSheet, Pressable } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    withTiming,
    interpolate,
    Extrapolate
} from 'react-native-reanimated';

interface ExpandableCardProps {
    renderCollapsed: (expand: () => void) => React.ReactNode;
    renderExpanded: (collapse: () => void) => React.ReactNode;
    backgroundColor: string;
    onExpand?: () => void;
    onCollapse?: () => void;
    style?: any;
    mode?: 'sheet' | 'full';
}

export const ExpandableIntegrationCard = ({
    renderCollapsed,
    renderExpanded,
    backgroundColor,
    onExpand,
    onCollapse,
    style,
    mode = 'sheet'
}: ExpandableCardProps) => {
    const expanded = useSharedValue(0);
    const [isExpandedState, setIsExpandedState] = useState(false);

    const handleExpand = () => {
        setIsExpandedState(true);
        expanded.value = withSpring(1, { damping: 15 });
        if (onExpand) onExpand();
    };

    const handleCollapse = () => {
        expanded.value = withSpring(0, { damping: 15 }, () => {
            // runOnJS(setIsExpandedState)(false); // If needed
        });
        setTimeout(() => setIsExpandedState(false), 300); // Simple delay matching animation
        if (onCollapse) onCollapse();
    };

    const rStyle = useAnimatedStyle(() => {
        return {
            height: interpolate(expanded.value, [0, 1], [60, 400]), // Approximate heights
            borderRadius: interpolate(expanded.value, [0, 1], [20, 24]),
        };
    });

    return (
        <Animated.View style={[styles.container, { backgroundColor }, style, rStyle]}>
            {/* Crossfade content */}
            <Animated.View style={[
                StyleSheet.absoluteFill,
                useAnimatedStyle(() => ({ opacity: 1 - expanded.value, zIndex: expanded.value < 0.5 ? 1 : 0 }))
            ]}>
                {renderCollapsed(handleExpand)}
            </Animated.View>

            <Animated.View style={[
                StyleSheet.absoluteFill,
                useAnimatedStyle(() => ({ opacity: expanded.value, zIndex: expanded.value > 0.5 ? 1 : 0 }))
            ]}>
                {/* Only render expanded content if we are expanding to save perf? 
                   For now, render always but hide with opacity/pointerEvents */}
                <View style={{ flex: 1, pointerEvents: isExpandedState ? 'auto' : 'none' }}>
                    {renderExpanded(handleCollapse)}
                </View>
            </Animated.View>
        </Animated.View>
    );
};

const styles = StyleSheet.create({
    container: {
        borderRadius: 20,
        overflow: 'hidden',
        minHeight: 60
    }
});
