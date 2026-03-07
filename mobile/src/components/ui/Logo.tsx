import React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { useThemeStore } from '../../lib/stores/theme-store';
import Svg, { Path } from 'react-native-svg';

interface LogoProps {
    size?: number;
    color?: string;
    showText?: boolean;
}

export const Logo = ({ size = 24, color, showText = true }: LogoProps) => {
    const { colors } = useThemeStore();
    const tintColor = color || colors.text;

    return (
        <View style={styles.container}>
            <Svg width={size} height={size} viewBox="0 0 699 699">
                <Path fill={tintColor} d="M79 136L230 156L291 286L176 199Z" />
                <Path fill={tintColor} d="M327 174L540 199L503 321Z" />
                <Path fill={tintColor} d="M215 103L284 239L328 352L368 492L398 644L498 338Z" />
            </Svg>
            {showText && (
                <Text style={[styles.text, { fontSize: size * 0.66, color: tintColor, lineHeight: size }]}>
                    Vibegram
                </Text>
            )}
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
    },
    text: {
        fontWeight: '700',
        letterSpacing: -0.5,
    }
});
