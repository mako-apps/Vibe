import React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { useThemeStore } from '../../lib/stores/theme-store';

interface LogoProps {
    size?: number;
    color?: string;
}

export const Logo = ({ size = 24, color }: LogoProps) => {
    const { colors } = useThemeStore();
    const textColor = color || colors.text;

    return (
        <View style={styles.container}>
            <Text style={[styles.text, { fontSize: 16, color: textColor, lineHeight: 20 }]}>
                Vibegram
            </Text>
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    text: {
        fontWeight: '700',
        letterSpacing: -0.5,
    }
});
