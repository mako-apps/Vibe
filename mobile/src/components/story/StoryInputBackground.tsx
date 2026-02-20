import React, { useMemo } from 'react';
import { StyleSheet, View } from 'react-native';
import { Canvas, Rect, Shader, Skia } from '@shopify/react-native-skia';
import { useSharedValue, useDerivedValue, withRepeat, withTiming, Easing } from 'react-native-reanimated';

// Bubble-like gradient shader with freely moving blobs
const SKSL_SHADER = `
uniform float2 iResolution;
uniform float iTime;
uniform vec3 glowColor;
uniform vec3 cyanColor;

half4 main(float2 fragCoord) {
    vec2 uv = fragCoord.xy / iResolution.xy;
    float aspect = iResolution.x / iResolution.y;
    vec2 p = uv;
    p.x *= aspect;
    
    float t = iTime * 0.4;
    
    // Create multiple moving centers (bubbles)
    // Blob 1: Wanders around center to top
    vec2 c1 = vec2(0.5 * aspect + sin(t) * 0.3 * aspect, 0.5 + cos(t * 0.8) * 0.4);
    
    // Blob 2: Wanders around bottom to right
    vec2 c2 = vec2(0.7 * aspect + cos(t * 1.2) * 0.2 * aspect, 0.8 + sin(t * 0.5) * 0.2);
    
    // Blob 3: Wanders left to middle
    vec2 c3 = vec2(0.2 * aspect + sin(t * 0.7) * 0.1 * aspect, 0.3 + cos(t * 1.5) * 0.3);
    
    // Calculate distances to each blob
    float d1 = length(p - c1);
    float d2 = length(p - c2);
    float d3 = length(p - c3);
    
    // Field influence (metaball style)
    float f = 0.0;
    f += 0.15 / max(d1 * d1, 0.001);
    f += 0.1 / max(d2 * d2, 0.001);
    f += 0.08 / max(d3 * d3, 0.001);
    
    // Smooth threshold for the liquid look
    float liquid = smoothstep(0.4, 2.0, f);
    
    // Distortion for the fluid surface
    float distortion = sin(uv.x * 3.0 + t) * 0.02 + cos(uv.y * 4.0 - t * 0.5) * 0.02;
    float alpha = liquid * (0.6 + distortion);
    
    // Color mixing based on horizontal position and blobs
    vec3 color = mix(cyanColor, glowColor, uv.x + uv.y * 0.5 + distortion);
    
    return half4(color * alpha, alpha * 0.5);
}
`;

const hexToRgb = (hex: string) => {
    'worklet';
    if (!hex) return [0, 0, 0];
    if (hex.startsWith('rgba')) {
        const match = hex.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
        if (match) return [parseInt(match[1]) / 255, parseInt(match[2]) / 255, parseInt(match[3]) / 255];
    }
    const cleanHex = hex.replace('#', '');
    const r = parseInt(cleanHex.substring(0, 2), 16) / 255;
    const g = parseInt(cleanHex.substring(2, 4), 16) / 255;
    const b = parseInt(cleanHex.substring(4, 6), 16) / 255;
    return [r, g, b];
}

interface StoryInputBackgroundProps {
    width: number;
    height: number;
    glowColor?: string;
    cyanColor?: string;
}

export const StoryInputBackground = ({
    width,
    height,
    glowColor = '#5EB1B2',
    cyanColor = '#06b6d4',
}: StoryInputBackgroundProps) => {
    const time = useSharedValue(0);

    const runtimeEffect = useMemo(() => Skia.RuntimeEffect.Make(SKSL_SHADER), []);

    const glow = useDerivedValue(() => hexToRgb(glowColor), [glowColor]);
    const cyan = useDerivedValue(() => hexToRgb(cyanColor), [cyanColor]);

    React.useEffect(() => {
        time.value = withRepeat(
            withTiming(100, { duration: 30000, easing: Easing.linear }),
            -1,
            false
        );
    }, []);

    const uniforms = useDerivedValue(() => ({
        iResolution: [width, height],
        iTime: time.value,
        glowColor: glow.value,
        cyanColor: cyan.value,
    }), [width, height, time, glow, cyan]);

    if (!runtimeEffect || width === 0 || height === 0) {
        return null;
    }

    return (
        <View style={StyleSheet.absoluteFill} pointerEvents="none">
            <Canvas style={{ flex: 1 }}>
                <Rect x={0} y={0} width={width} height={height}>
                    <Shader source={runtimeEffect} uniforms={uniforms} />
                </Rect>
            </Canvas>
        </View>
    );
};
