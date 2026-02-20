import React, { useState } from 'react';
import { View, Text, StyleSheet, Pressable, Platform, ScrollView } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    interpolate,
    Extrapolation,
    interpolateColor
} from 'react-native-reanimated';
import { ChevronRight, Check } from 'lucide-react-native';
import * as Haptics from 'expo-haptics';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { borderRadius } from '../../lib/theme';

const AnimatedView = Animated.View as any;

const SPRING_CONFIG = { mass: 0.8, damping: 15, stiffness: 200, overshootClamping: false };

interface FontOption {
    name: string;
    family: string | undefined;
}

interface GlassFontMenuProps {
    fonts: FontOption[];
    selectedFont: string | undefined;
    onSelect: (family: string | undefined) => void;
    menuWidth?: number;
    menuHeight?: number;
}

const GlassFontMenu = ({
    fonts,
    selectedFont,
    onSelect,
    menuWidth = 160,
    menuHeight = 300,

}: GlassFontMenuProps) => {
    const progress = useSharedValue(0);
    const [isOpen, setIsOpen] = useState(false);

    const toggle = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
        const nextState = !isOpen;
        setIsOpen(nextState);
        progress.value = withSpring(nextState ? 1 : 0, SPRING_CONFIG);
    };

    const containerStyle = useAnimatedStyle(() => ({
        width: interpolate(progress.value, [0, 1], [100, menuWidth]),
        height: interpolate(progress.value, [0, 1], [40, menuHeight]),
        borderRadius: interpolate(progress.value, [0, 1], [20, 24]),
        overflow: 'hidden',

    }));

    const buttonStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.2], [1, 0], Extrapolation.CLAMP),
    }));

    const contentStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0.4, 0.8], [0, 1], Extrapolation.CLAMP),
        transform: [
            { scale: interpolate(progress.value, [0.4, 1], [0.8, 1], Extrapolation.CLAMP) }
        ]
    }));

    const selectedFontName = fonts.find(f => f.family === selectedFont)?.name || 'Default';

    return (
        <View style={{ width: 100, height: 40, alignItems: 'flex-end', justifyContent: 'flex-end' }}>
            {isOpen && (
                <Pressable
                    onPress={toggle}
                    style={[StyleSheet.absoluteFill, {
                        width: 5000, height: 5000,
                        left: -2500, top: -2500,
                        zIndex: 1
                    }]}
                />
            )}

            <AnimatedView style={[containerStyle, { position: 'absolute', bottom: 0, right: 0, zIndex: 10, flex: 1, borderRadius: 22 }]}>
                <SafeLiquidGlass
                    style={StyleSheet.absoluteFill}
                    blurIntensity={30}
                    colorScheme="dark"
                    tint="dark"
                >
                    {/* Trigger Button (Shows Active Font) */}
                    <AnimatedView style={[buttonStyle, StyleSheet.absoluteFill]}>
                        <Pressable onPress={toggle} style={s.trigger}>
                            <Text numberOfLines={1} style={[s.fontPreview, { fontFamily: selectedFont }]}>
                                {selectedFontName}
                            </Text>
                        </Pressable>
                    </AnimatedView>

                    {/* Expanded Menu */}
                    <AnimatedView style={[contentStyle, { flex: 1 }]}>
                        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={s.list}>
                            {fonts.map((font) => (
                                <Pressable
                                    key={font.name}
                                    style={[s.item, selectedFont === font.family && s.itemActive]}
                                    onPress={() => {
                                        onSelect(font.family);
                                        toggle();
                                    }}
                                >
                                    <Text style={[s.itemText, { fontFamily: font.family }]}>{font.name}</Text>
                                    {selectedFont === font.family && <Check size={14} color="#fff" />}
                                </Pressable>
                            ))}
                        </ScrollView>
                    </AnimatedView>
                </SafeLiquidGlass>
            </AnimatedView>
        </View>
    );
};

const s = StyleSheet.create({
    trigger: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'transparent',
        paddingHorizontal: 12,
        borderRadius: 22
    },
    fontPreview: {
        color: '#fff',
        fontSize: 14,
        fontWeight: '700',
    },
    list: {
        padding: 12,
    },
    item: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingVertical: 12,
        paddingHorizontal: 12,
        borderRadius: 12,
        marginBottom: 4,
    },
    itemActive: {
        backgroundColor: 'rgba(255,255,255,0.15)',
    },
    itemText: {
        color: '#fff',
        fontSize: 14,
        fontWeight: '600',
    }
});

export default GlassFontMenu;
