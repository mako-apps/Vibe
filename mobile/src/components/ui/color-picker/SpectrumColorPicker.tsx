import React from 'react';
import { View, StyleSheet, Dimensions } from 'react-native';
import ColorPicker, { Panel1, HueSlider, OpacitySlider, Preview } from 'reanimated-color-picker';
import { runOnJS } from 'react-native-reanimated';
import { useThemeStore } from '../../../lib/stores/theme-store';

const { width } = Dimensions.get('window');

interface Props {
    selectedColor: string;
    onColorSelect: (color: string) => void;
}

export default function SpectrumColorPicker({ selectedColor, onColorSelect }: Props) {
    const { colors } = useThemeStore();

    return (
        <View style={styles.container}>
            <ColorPicker
                style={styles.picker}
                value={selectedColor}
                onComplete={({ hex }) => onColorSelect(hex)}
                onChange={({ hex }: { hex: string }) => {
                    // Update state. If this runs on UI thread, we must use runOnJS.
                    // reanimated-color-picker documentation says callbacks can be worklets.
                    runOnJS(onColorSelect)(hex);
                }}
            >
                <View style={styles.panels}>
                    <Panel1 style={styles.panel} />

                    <View style={styles.sliders}>
                        <HueSlider style={styles.slider} thumbShape='circle' />
                        {/* Opacity slider is handled by parent currently, but library has one too. 
                            If parent handles pattern opacity separately, maybe skip it here.
                            User asked for "Color Picker", usually implying Hue/Sat/Val.
                            I'll stick to Hue + Sat/Val (Panel1).
                        */}
                    </View>
                </View>
            </ColorPicker>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        paddingTop: 10,
        paddingBottom: 20,
        height: 250, // Ensure enough height for the picker
    },
    picker: {
        width: '100%',
        height: '100%',
        gap: 20,
    },
    panels: {
        gap: 16,
        paddingHorizontal: 16
    },
    panel: {
        height: 150,
        borderRadius: 12,

        width: '100%',
    },
    sliders: {
        gap: 12,
    },
    slider: {
        height: 30,
        borderRadius: 15,
        width: '100%',
    }
});
