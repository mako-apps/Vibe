import React, { useEffect, useMemo, useRef, useState } from 'react'
import { StyleSheet, useWindowDimensions, ViewStyle } from 'react-native'
import {
    Path,
    Circle,
    Group,
    LinearGradient,
    vec,
    BlurMask,
    Points,
    Rect,
    Skia,
    SkiaPictureView,
    drawAsPicture,
    type SkPicture
} from '@shopify/react-native-skia'
import { useThemeStore } from '../lib/stores/theme-store'

export type BackgroundPattern = 'geometric' | 'fluid' | 'bubbles' | 'particles' | 'lines'

interface ThemeBackgroundProps {
    pattern?: BackgroundPattern
    opacity?: number
    style?: ViewStyle
}

export default function ThemeBackground({ pattern = 'fluid', opacity, style }: ThemeBackgroundProps) {
    const { colors, effectiveTheme } = useThemeStore()
    const { width, height } = useWindowDimensions()
    const isDark = effectiveTheme === 'dark'
    const [picture, setPicture] = useState<SkPicture | null>(null)
    const pictureRef = useRef<SkPicture | null>(null)
    const renderTokenRef = useRef(0)

    // Default opacity based on theme - subtle "Telegram-like" feel
    const effectiveOpacity = opacity ?? (isDark ? 0.08 : 0.04)

    // Pattern Generators
    const geometricPath = useMemo(() => {
        let path = ""
        const size = 60
        // Generate diamond grid
        for (let y = -size; y < height + size; y += size) {
            for (let x = -size; x < width + size; x += size) {
                // M top L right L bottom L left Z
                path += `M ${x} ${y - size / 2} L ${x + size / 2} ${y} L ${x} ${y + size / 2} L ${x - size / 2} ${y} Z `
            }
        }
        return path
    }, [width, height])

    const fluidPath = useMemo(() => {
        let path = ""
        // 3 flowing sine waves
        const levels = [height * 0.4, height * 0.6, height * 0.8]
        levels.forEach((yBase, i) => {
            const amplitude = 60 + i * 20
            const frequency = 0.004 + (i * 0.001)
            const phase = i * 2
            path += `M 0 ${yBase} `
            for (let x = 0; x <= width; x += 15) {
                const y = yBase + Math.sin(x * frequency + phase) * amplitude
                path += `L ${x} ${y} `
            }
        })
        return path
    }, [width, height])

    const bubbles = useMemo(() => {
        return [...Array(8)].map((_, i) => ({
            c: vec(Math.random() * width, Math.random() * height),
            r: 40 + Math.random() * 100
        }))
    }, [width, height])

    const particles = useMemo(() => {
        // Random star dust
        return [...Array(100)].map(() => vec(Math.random() * width, Math.random() * height))
    }, [width, height])

    const linesPath = useMemo(() => {
        let path = ""
        const step = 40
        // Diagonal lines /
        for (let i = -height; i < width + height; i += step) {
            path += `M ${i} ${height} L ${i + height} 0 `
        }
        return path
    }, [width, height])

    const scene = useMemo(
        () => (
            <Group>
                {/* Base Gradient Background - Adds depth */}
                <Rect x={0} y={0} width={width} height={height}>
                    <LinearGradient
                        start={vec(0, 0)}
                        end={vec(width, height)}
                        colors={[colors.background, colors.backgroundSecondary || colors.background]}
                    />
                </Rect>

                {/* Pattern Layer */}
                <Group
                    opacity={effectiveOpacity}
                    color={colors.primary}
                    style={pattern === 'bubbles' ? 'fill' : 'stroke'}
                    strokeWidth={pattern === 'particles' || pattern === 'geometric' ? 1.5 : 2}
                    strokeCap="round"
                    strokeJoin="round"
                >
                    <BlurMask blur={pattern === 'bubbles' ? 60 : pattern === 'fluid' ? 12 : 2} style="normal" />

                    {pattern === 'geometric' && <Path path={geometricPath} />}

                    {pattern === 'fluid' && <Path path={fluidPath} strokeWidth={3} />}

                    {pattern === 'bubbles' && (
                        <Group>
                            {bubbles.map((b, i) => (
                                <Circle key={i} c={b.c} r={b.r} />
                            ))}
                        </Group>
                    )}

                    {pattern === 'particles' && <Points points={particles} mode="points" strokeWidth={3} />}

                    {pattern === 'lines' && <Path path={linesPath} />}
                </Group>
            </Group>
        ),
        [width, height, colors.background, colors.backgroundSecondary, colors.primary, effectiveOpacity, pattern, geometricPath, fluidPath, bubbles, particles, linesPath]
    )

    useEffect(() => {
        if (width <= 0 || height <= 0) return
        renderTokenRef.current += 1
        const token = renderTokenRef.current
        const bounds = Skia.XYWHRect(0, 0, width, height)

        drawAsPicture(scene, bounds)
            .then((nextPicture) => {
                if (token !== renderTokenRef.current) {
                    nextPicture.dispose()
                    return
                }
                setPicture((currentPicture) => {
                    if (currentPicture && currentPicture !== nextPicture) {
                        currentPicture.dispose()
                    }
                    pictureRef.current = nextPicture
                    return nextPicture
                })
            })
            .catch(() => {
                // Keep previous picture if offscreen render fails.
            })
    }, [scene, width, height])

    useEffect(() => {
        return () => {
            renderTokenRef.current += 1
            pictureRef.current?.dispose()
            pictureRef.current = null
        }
    }, [])

    return <SkiaPictureView style={[StyleSheet.absoluteFill, style]} pointerEvents="none" picture={picture ?? undefined} />
}
