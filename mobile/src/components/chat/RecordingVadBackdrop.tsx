import React, { useEffect, useMemo, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { Canvas, Rect, Shader, Skia } from '@shopify/react-native-skia';
import { Easing, useDerivedValue, useSharedValue, withTiming } from 'react-native-reanimated';

const RECORDING_SHADER = `
uniform float2 iResolution;
uniform float iVad;
uniform float iActive;
uniform float iMask;
uniform vec3 baseA;
uniform vec3 baseB;
uniform vec3 glowA;
uniform vec3 glowB;
uniform vec3 accent;

float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);

    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

half4 main(float2 fragCoord) {
    vec2 uv = fragCoord.xy / iResolution.xy;
    float vad = clamp(iVad, 0.0, 1.0);
    float active = clamp(iActive, 0.0, 1.0);
    float drift = clamp(iMask, -1.0, 1.0) * 0.16;

    vec3 baseMix = mix(baseA, baseB, clamp((uv.x * 0.42) + (uv.y * 0.58), 0.0, 1.0));

    float fluid = noise((uv * 4.4) + float2(vad * 2.0, -vad * 1.6));
    float wave = (noise((uv * 7.0) + float2(1.3, 2.7)) - 0.5) * 0.05;

    vec2 p1 = vec2(0.68 + drift + ((vad - 0.5) * 0.08), 0.56 + ((vad - 0.5) * 0.05));
    vec2 p2 = vec2(0.36 + (drift * 0.35), 0.46 + (vad * 0.04));

    float r1 = 0.56 - (vad * 0.14) + wave;
    float r2 = 0.59 - (vad * 0.10);

    float b1 = smoothstep(r1, r1 - (0.22 + (vad * 0.16)), length(uv - p1) - (fluid * 0.11));
    float b2 = smoothstep(r2, r2 - (0.20 + (vad * 0.11)), length(uv - p2) + (wave * 0.3));
    float field = clamp((b1 * 0.84) + (b2 * 0.58), 0.0, 1.0);

    vec3 glowMix = mix(glowA, glowB, clamp((uv.y * 0.8) + 0.1, 0.0, 1.0));
    vec3 lifted = mix(baseMix, glowMix, field * (0.14 + (vad * 0.24)));
    lifted = mix(lifted, accent, b1 * (0.04 + (vad * 0.09)));

    float grain = noise((uv * float2(iResolution.x / 68.0, iResolution.y / 54.0)));
    lifted += (grain - 0.5) * 0.028 * field * (0.16 + (vad * 0.52));

    float edgeX = smoothstep(0.0, 0.24, uv.x) * (1.0 - smoothstep(0.76, 1.0, uv.x));
    float edgeY = smoothstep(0.0, 0.42, uv.y) * (1.0 - smoothstep(0.66, 1.0, uv.y));
    float edgeMask = clamp(edgeX * edgeY, 0.0, 1.0);

    float fade = smoothstep(0.0, 0.22, active);
    float mixStrength = (0.16 + (vad * 0.38)) * fade * edgeMask;
    vec3 color = mix(baseMix, lifted, mixStrength);
    float alpha = (0.08 + (vad * 0.24)) * fade * edgeMask;
    return half4(color, alpha);
}
`;

const clamp01 = (value: number) => Math.max(0, Math.min(1, value));
const clampMask = (value: number) => Math.max(-1, Math.min(1, value));

const hexToRgb = (hex: string): [number, number, number] => {
    const safe = typeof hex === 'string' && hex.startsWith('#') && hex.length >= 7 ? hex : '#000000';
    const r = parseInt(safe.slice(1, 3), 16) / 255;
    const g = parseInt(safe.slice(3, 5), 16) / 255;
    const b = parseInt(safe.slice(5, 7), 16) / 255;
    return [r, g, b];
};

interface RecordingVadBackdropProps {
    active: boolean;
    vad: number;
    maskOffset: number;
    isDark: boolean;
    gradient: [string, string];
}

const RecordingVadBackdrop = ({
    active,
    vad,
    maskOffset,
    isDark,
    gradient,
}: RecordingVadBackdropProps) => {
    const [size, setSize] = useState({ width: 1, height: 1 });

    const runtimeEffect = useMemo(() => Skia.RuntimeEffect.Make(RECORDING_SHADER), []);
    const vadShared = useSharedValue(clamp01(vad));
    const activeShared = useSharedValue(active ? 1 : 0);
    const maskShared = useSharedValue(clampMask(maskOffset));

    const palette = useMemo(() => ({
        baseA: hexToRgb(isDark ? '#060f16' : '#e6edf8'),
        baseB: hexToRgb(isDark ? '#152331' : '#f9fbff'),
        glowA: hexToRgb(gradient[0] || '#2fa8ff'),
        glowB: hexToRgb(gradient[1] || '#6dd3ff'),
        accent: hexToRgb(isDark ? '#57e7d4' : '#0ba5a2'),
    }), [gradient, isDark]);

    useEffect(() => {
        vadShared.value = withTiming(clamp01(vad), {
            duration: 100,
            easing: Easing.out(Easing.quad),
        });
    }, [vad, vadShared]);

    useEffect(() => {
        activeShared.value = withTiming(active ? 1 : 0, {
            duration: active ? 150 : 220,
            easing: Easing.out(Easing.cubic),
        });
    }, [active, activeShared]);

    useEffect(() => {
        maskShared.value = withTiming(clampMask(maskOffset), {
            duration: 120,
            easing: Easing.out(Easing.quad),
        });
    }, [maskOffset, maskShared]);

    const uniforms = useDerivedValue(() => ({
        iResolution: [size.width, size.height],
        iVad: vadShared.value,
        iActive: activeShared.value,
        iMask: maskShared.value,
        baseA: palette.baseA,
        baseB: palette.baseB,
        glowA: palette.glowA,
        glowB: palette.glowB,
        accent: palette.accent,
    }), [size.width, size.height, vadShared, activeShared, maskShared, palette]);

    if (!runtimeEffect) return null;

    return (
        <View
            pointerEvents="none"
            style={StyleSheet.absoluteFill}
            onLayout={(event) => {
                const { width, height } = event.nativeEvent.layout;
                if (Math.abs(width - size.width) > 0.5 || Math.abs(height - size.height) > 0.5) {
                    setSize({
                        width: Math.max(1, width),
                        height: Math.max(1, height),
                    });
                }
            }}
        >
            <Canvas style={styles.canvas}>
                <Rect x={0} y={0} width={size.width} height={size.height}>
                    <Shader source={runtimeEffect} uniforms={uniforms} />
                </Rect>
            </Canvas>
        </View>
    );
};

const styles = StyleSheet.create({
    canvas: {
        flex: 1,
    },
});

export default RecordingVadBackdrop;
