import React, { useState, useEffect, useRef, useMemo } from 'react'
import { Text, View, Pressable, StyleSheet } from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    withDelay,
    Easing as ReanimatedEasing,
} from 'react-native-reanimated'
import { useThemeStore } from '../../lib/stores/theme-store'
import { CurvedArrowIcon } from '../Icons'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import { borderRadius } from '../../lib/theme'

const AnimatedView = Animated.createAnimatedComponent(View)

// ⚡ ANIMATION CONFIG
const FADE_DURATION = 500
const SIMPLE_STAGGER = 10

// Helper to add alpha to hex colors
const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color
}

/**
 * ⚡ AnimatedToken - Works with both Text and View children
 */
const AnimatedToken = React.memo(({
    children,
    shouldAnimate,
    delayMs = 0,
    isInline = true
}: {
    children: React.ReactNode
    shouldAnimate: boolean
    delayMs?: number
    isInline?: boolean
}) => {
    const opacity = useSharedValue(shouldAnimate ? 0 : 1)

    useEffect(() => {
        if (shouldAnimate) {
            opacity.value = withDelay(delayMs,
                withTiming(1, {
                    duration: FADE_DURATION,
                    easing: ReanimatedEasing.bezier(0.25, 0.1, 0.25, 1),
                })
            )
        }
    }, [])

    const animatedStyle = useAnimatedStyle(() => ({
        opacity: opacity.value,
    }))

    return (
        <AnimatedView style={[animatedStyle, isInline && { flexDirection: 'row', alignItems: 'center' }]}>
            {children}
        </AnimatedView>
    )
})

interface StreamingTextProps {
    text: string
    style?: any
    isStreaming: boolean
    children?: React.ReactNode
    onInlinePress?: (type: string, data: any) => void
    onAnimationComplete?: () => void
}

/**
 * Parse Markdown -> Split into Words
 */
const parseTextToWords = (text: string) => {
    if (!text) return []

    const tokens: Array<{ type: string, content: string, url?: string, action?: string, level?: number, headers?: string[], rows?: string[][] }> = []

    // First, detect and extract tables (more flexible regex)
    // Matches: | header | header |\n| --- | --- |\n| cell | cell |
    const tableRegex = /(\|[^\n]+\|\r?\n\|[-:\s|]+\|\r?\n(?:\|[^\n]+\|(?:\r?\n)?)+)/g
    let lastTableEnd = 0
    let match

    while ((match = tableRegex.exec(text)) !== null) {
        // Process text before table
        if (match.index > lastTableEnd) {
            const beforeTable = text.substring(lastTableEnd, match.index)
            parseNonTableText(beforeTable, tokens)
        }

        // Parse the table
        const tableText = match[1]
        console.log('[StreamingText] Found table text:', tableText)
        const tableLines = tableText.trim().split(/\r?\n/)
        if (tableLines.length >= 2) {
            const headerCells = tableLines[0].split('|').filter(c => c.trim()).map(c => c.trim())
            const rows: string[][] = []
            for (let i = 2; i < tableLines.length; i++) {
                const rowCells = tableLines[i].split('|').filter(c => c.trim()).map(c => c.trim())
                if (rowCells.length > 0) rows.push(rowCells)
            }
            console.log('[StreamingText] Parsed table:', { headerCells, rows })
            if (headerCells.length > 0 && rows.length > 0) {
                // Strip markdown formatting from cells (e.g. **bold** -> bold)
                const cleanCell = (text: string) => text.replace(/\*\*([^*]+)\*\*/g, '$1').replace(/\*([^*]+)\*/g, '$1')
                const cleanHeaders = headerCells.map(cleanCell)
                const cleanRows = rows.map(row => row.map(cleanCell))
                tokens.push({ type: 'table', content: '', headers: cleanHeaders, rows: cleanRows })
            }
        }

        lastTableEnd = match.index + match[0].length
    }

    // Process remaining text after last table
    if (lastTableEnd < text.length) {
        parseNonTableText(text.substring(lastTableEnd), tokens)
    }

    return tokens
}

/**
 * Parse non-table text into tokens
 */
const parseNonTableText = (text: string, tokens: Array<{ type: string, content: string, url?: string, action?: string, level?: number }>) => {
    const lines = text.split('\n')

    lines.forEach((line, lineIndex) => {
        if (lineIndex > 0) tokens.push({ type: 'newline', content: '\n' })

        const trimmed = line.trim()
        if (!trimmed) return

        // Header check
        const headerMatch = trimmed.match(/^(#{1,3})\s+(.+)$/)
        if (headerMatch) {
            tokens.push({
                type: 'header',
                content: headerMatch[2],
                level: headerMatch[1].length
            })
            return
        }

        // Bullet check
        const bulletMatch = trimmed.match(/^[-*]\s+(.+)$/)
        let contentToParse = line
        if (bulletMatch) {
            tokens.push({ type: 'bullet', content: '• ' })
            contentToParse = bulletMatch[1]
        }

        // Pattern matches: **bold**, *italic*, [digit] citation, [text](url) link, [Source Name] badge, [TASK:], [EVENT:], [FOLLOWUP:], [LINK:]
        const pattern = /(\*\*([^*]+)\*\*)|(\*([^*]+)\*)|(\[(\d+)\](?!\())|(\[([^\]]+)\]\(([^)]+)\))|(\[TASK:([^\]]+)\])|(\[EVENT:([^\]]+)\])|(\[FOLLOWUP:([^\]]+):([^\]]+)\])|(\[LINK:([^:]+):([^\]]+)\])|(\[([A-Za-z][^\]\[]{1,30})\](?!\())/g

        let lastIndex = 0
        let match

        while ((match = pattern.exec(contentToParse)) !== null) {
            if (match.index > lastIndex) {
                const plainText = contentToParse.substring(lastIndex, match.index)
                const words = plainText.split(/(\s+)/).filter(w => w.length > 0)
                words.forEach(w => tokens.push({ type: 'text', content: w }))
            }

            if (match[1]) tokens.push({ type: 'bold', content: match[2] })
            else if (match[3]) tokens.push({ type: 'italic', content: match[4] })
            else if (match[5]) tokens.push({ type: 'citation', content: match[6] })
            else if (match[7]) tokens.push({ type: 'link', content: match[8], url: match[9] })
            else if (match[10]) tokens.push({ type: 'task', content: match[11] })
            else if (match[12]) tokens.push({ type: 'event', content: match[13] })
            else if (match[14]) tokens.push({ type: 'followup', content: match[15], action: match[16] })
            else if (match[17]) tokens.push({ type: 'link', content: match[19], url: match[18] })
            else if (match[20]) tokens.push({ type: 'source_badge', content: match[21] })

            lastIndex = match.index + match[0].length
        }

        if (lastIndex < contentToParse.length) {
            const plainText = contentToParse.substring(lastIndex)
            const words = plainText.split(/(\s+)/).filter(w => w.length > 0)
            words.forEach(w => tokens.push({ type: 'text', content: w }))
        }
    })
}

/**
 * ⚡ StreamingText - Using flexWrap View for proper inline badges
 */
const StreamingText: React.FC<StreamingTextProps> = ({
    text,
    isStreaming,
    style,
    children,
    onInlinePress,
    onAnimationComplete
}) => {
    const { colors, effectiveTheme } = useThemeStore()
    const isLight = effectiveTheme === 'light'
    const baseFontSize = ((style?.fontSize as number) || 16)
    const lineHeight = style?.lineHeight || baseFontSize * 1.5
    const linkColor = colors.primary || '#007AFF'

    const [showFinal, setShowFinal] = useState(false)

    const animatedTokenCountRef = useRef(0)
    const lastAnimationEndTimeRef = useRef<number>(0)
    const tokenDelaysRef = useRef<Map<number, number>>(new Map())

    const tokens = useMemo(() => parseTextToWords(text), [text])

    useMemo(() => {
        if (!isStreaming) {
            animatedTokenCountRef.current = tokens.length
            tokenDelaysRef.current.clear()
            return
        }

        const previouslyAnimated = animatedTokenCountRef.current
        const newTokenCount = tokens.length

        if (newTokenCount <= previouslyAnimated) return

        for (let i = previouslyAnimated; i < newTokenCount; i++) {
            const batchIndex = i - previouslyAnimated
            const delay = batchIndex * SIMPLE_STAGGER
            tokenDelaysRef.current.set(i, delay)
        }

        animatedTokenCountRef.current = newTokenCount
        const lastTokenDelay = (newTokenCount - previouslyAnimated - 1) * SIMPLE_STAGGER
        lastAnimationEndTimeRef.current = Date.now() + lastTokenDelay + FADE_DURATION

    }, [tokens.length, isStreaming])

    const animationCompleteCalledRef = useRef(false)

    useEffect(() => {
        if (!isStreaming && !animationCompleteCalledRef.current && onAnimationComplete) {
            const now = Date.now()
            const remainingTime = Math.max(0, lastAnimationEndTimeRef.current - now)

            const timer = setTimeout(() => {
                animationCompleteCalledRef.current = true
                onAnimationComplete()
            }, Math.min(remainingTime + 50, 600))

            return () => clearTimeout(timer)
        } else if (isStreaming) {
            animationCompleteCalledRef.current = false
        }
    }, [isStreaming, onAnimationComplete])

    useEffect(() => {
        if (!isStreaming && !showFinal) {
            const timer = setTimeout(() => setShowFinal(true), 600)
            return () => clearTimeout(timer)
        } else if (isStreaming) {
            setShowFinal(false)
        }
    }, [isStreaming, showFinal])

    useEffect(() => {
        if (!text) {
            animatedTokenCountRef.current = 0
            lastAnimationEndTimeRef.current = 0
            tokenDelaysRef.current.clear()
        }
    }, [text])

    if (showFinal && children) return <>{children}</>
    if (!text) return null

    // Base text style
    const baseTextStyle = {
        fontSize: baseFontSize,
        lineHeight: lineHeight,
        color: style?.color || colors.text,
    }

    return (
        <View style={[styles.container, style]}>
            {tokens.map((token, index) => {
                const hasDelay = tokenDelaysRef.current.has(index)
                const shouldAnimate = isStreaming && hasDelay
                const delay = tokenDelaysRef.current.get(index) || 0

                const commonProps = { shouldAnimate, delayMs: delay }

                switch (token.type) {
                    case 'newline':
                        return <View key={index} style={styles.newline} />

                    case 'header':
                        const hSize = token.level === 1 ? baseFontSize * 1.5 : baseFontSize * 1.25
                        return (
                            <AnimatedToken key={index} {...commonProps} isInline={false}>
                                <View style={styles.headerContainer}>
                                    <Text style={[baseTextStyle, { fontWeight: '700', fontSize: hSize, lineHeight: hSize * 1.4 }]}>
                                        {token.content}
                                    </Text>
                                </View>
                            </AnimatedToken>
                        )

                    case 'table':
                        const headers = token.headers || []
                        const rows = token.rows || []
                        return (
                            <View key={index} style={{ width: '100%', marginVertical: 12 }}>
                                <View style={{
                                    backgroundColor: withAlpha(colors.text, 0.04),
                                    borderRadius: 12,
                                    overflow: 'hidden'
                                }}>
                                    {/* Header Row */}
                                    <View style={{
                                        flexDirection: 'row',
                                        paddingVertical: 20,
                                        paddingHorizontal: 12,
                                        borderBottomWidth: 1,
                                        borderBottomColor: withAlpha(colors.text, 0.08)
                                    }}>
                                        {headers.map((header: string, hIdx: number) => (
                                            <Text
                                                key={hIdx}
                                                style={{
                                                    flex: 1,
                                                    color: colors.text,
                                                    fontWeight: '600',
                                                    fontSize: 12,
                                                    opacity: 0.9
                                                }}
                                                numberOfLines={1}
                                            >
                                                {header}
                                            </Text>
                                        ))}
                                    </View>
                                    {/* Data Rows */}
                                    {rows.map((row: string[], rIdx: number) => (
                                        <View
                                            key={rIdx}
                                            style={{
                                                flexDirection: 'row',
                                                paddingVertical: 8,
                                                paddingHorizontal: 12,
                                                borderBottomWidth: rIdx < rows.length - 1 ? 1 : 0,
                                                borderBottomColor: withAlpha(colors.text, 0.04)
                                            }}
                                        >
                                            {row.map((cell: string, cIdx: number) => (
                                                <Text
                                                    key={cIdx}
                                                    style={{
                                                        flex: 1,
                                                        color: withAlpha(colors.text, 0.8),
                                                        fontSize: 11
                                                    }}
                                                    numberOfLines={2}
                                                >
                                                    {cell}
                                                </Text>
                                            ))}
                                        </View>
                                    ))}
                                </View>
                            </View>
                        )

                    case 'bullet':
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <Text style={baseTextStyle}>{token.content}</Text>
                            </AnimatedToken>
                        )

                    case 'bold':
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <Text style={[baseTextStyle, { fontWeight: '700' }]}>{token.content}</Text>
                            </AnimatedToken>
                        )

                    case 'italic':
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <Text style={[baseTextStyle, { fontStyle: 'italic' }]}>{token.content}</Text>
                            </AnimatedToken>
                        )

                    case 'link':
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <Text
                                    onPress={() => onInlinePress?.('link', { url: token.url })}
                                    style={[baseTextStyle, { color: linkColor, textDecorationLine: 'underline' }]}
                                >
                                    {token.content}
                                </Text>
                            </AnimatedToken>
                        )

                    case 'citation':
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <SafeLiquidGlass
                                    intensity={8}
                                    tint={effectiveTheme}
                                    style={{
                                        paddingHorizontal: 12,
                                        paddingVertical: 2,
                                        borderRadius: 8,
                                        marginHorizontal: 2,
                                        marginVertical: 1,
                                        backgroundColor: withAlpha(colors.lime?.[2] || colors.primary, isLight ? 0.24 : 0.12),
                                        overflow: 'hidden',
                                    }}
                                >
                                    <Text style={{
                                        fontSize: baseFontSize * 0.75,
                                        fontWeight: '500',
                                        color: colors.textSecondary,
                                    }}>
                                        {token.content}
                                    </Text>
                                </SafeLiquidGlass>
                            </AnimatedToken>
                        )

                    case 'task':
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <Pressable
                                    onPress={() => onInlinePress?.('task', { title: token.content })}
                                    style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1 })}
                                >
                                    <SafeLiquidGlass
                                        intensity={10}
                                        tint={effectiveTheme}
                                        style={{

                                            borderRadius: 8,
                                            marginHorizontal: 2,
                                            marginVertical: 1,
                                            backgroundColor: withAlpha(colors.lime?.[2] || colors.primary, isLight ? 0.18 : 0.42),
                                            overflow: 'hidden',
                                        }}
                                    >
                                        <Text style={{
                                            fontSize: baseFontSize * 0.8,
                                            fontWeight: '600',
                                            color: colors.text,
                                            paddingHorizontal: 16,
                                            paddingVertical: 4,
                                        }}>
                                            {token.content}
                                        </Text>
                                    </SafeLiquidGlass>
                                </Pressable>
                            </AnimatedToken>
                        )

                    case 'event':
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <Pressable
                                    onPress={() => onInlinePress?.('event', { title: token.content })}
                                    style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1 })}
                                >
                                    <SafeLiquidGlass
                                        intensity={10}
                                        tint={effectiveTheme}
                                        style={{
                                            paddingHorizontal: 6,
                                            paddingVertical: 2,
                                            borderRadius: 8,
                                            marginHorizontal: 2,
                                            marginVertical: 1,
                                            backgroundColor: withAlpha(colors.primary, isLight ? 0.08 : 0.12),
                                            overflow: 'hidden',
                                        }}
                                    >
                                        <Text style={{
                                            fontSize: baseFontSize * 0.8,
                                            fontWeight: '600',
                                            color: colors.text,
                                        }}>
                                            {token.content}
                                        </Text>
                                    </SafeLiquidGlass>
                                </Pressable>
                            </AnimatedToken>
                        )

                    case 'followup':
                        return (
                            <AnimatedToken key={index} {...commonProps} isInline={false}>
                                <View style={styles.followupContainer}>
                                    <Pressable
                                        onPress={() => onInlinePress?.('followup', { label: token.content, action: token.action })}
                                        style={({ pressed }) => [
                                            styles.followupButton,
                                            { opacity: pressed ? 0.6 : 1 }
                                        ]}
                                    >
                                        <View style={{ transform: [{ rotateY: '180deg' }] }}>
                                            <CurvedArrowIcon
                                                size={baseFontSize * 1.1}
                                                color={isLight ? 'rgba(0,0,0,0.4)' : 'rgba(255,255,255,0.4)'}
                                                strokeWidth={1.5}
                                            />
                                        </View>
                                        <Text style={{
                                            fontSize: baseFontSize * 0.95,
                                            fontWeight: '400',
                                            color: isLight ? 'rgba(0,0,0,0.75)' : 'rgba(255,255,255,0.75)',
                                            letterSpacing: 0.2
                                        }}>
                                            {token.content}
                                        </Text>
                                    </Pressable>
                                </View>
                            </AnimatedToken>
                        )

                    case 'source_badge':
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <Pressable
                                    onPress={() => onInlinePress?.('source', { name: token.content })}
                                    style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1 })}
                                >
                                    <SafeLiquidGlass
                                        intensity={8}
                                        tint={effectiveTheme}
                                        style={{
                                            paddingHorizontal: 6,
                                            paddingVertical: 2,
                                            borderRadius: 8,
                                            marginHorizontal: 2,
                                            marginVertical: 1,
                                            backgroundColor: withAlpha(colors.primary, isLight ? 0.24 : 0.42),
                                            overflow: 'hidden',
                                        }}
                                    >
                                        <Text style={{
                                            fontSize: baseFontSize * 0.72,
                                            fontWeight: '500',
                                            color: colors.textSecondary,
                                        }}>
                                            {token.content}
                                        </Text>
                                    </SafeLiquidGlass>
                                </Pressable>
                            </AnimatedToken>
                        )

                    default:
                        // Regular text or whitespace
                        const isWhitespace = /^\s+$/.test(token.content)
                        if (isWhitespace) {
                            return <Text key={index} style={baseTextStyle}>{token.content}</Text>
                        }
                        return (
                            <AnimatedToken key={index} {...commonProps}>
                                <Text style={baseTextStyle}>{token.content}</Text>
                            </AnimatedToken>
                        )
                }
            })}
        </View>
    )
}

const styles = StyleSheet.create({
    container: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        alignItems: 'center',
    },
    newline: {
        width: '100%',
        height: 8,
    },
    headerContainer: {
        width: '100%',
        marginTop: 12,
        marginBottom: 4,
    },
    badge: {
        paddingHorizontal: 6,
        paddingVertical: 2,
        borderRadius: 4,
        marginHorizontal: 2,
        marginVertical: 1,
    },
    badgeText: {
        fontWeight: '500',
        borderRadius: 12,
    },
    followupContainer: {
        width: '100%',
        marginTop: 8,
        marginBottom: 4,
    },
    followupButton: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
    },
    tableContainer: {
        width: '100%',
        marginVertical: 12,
        borderRadius: 12,
        overflow: 'hidden',
    },
    tableGlass: {
        borderRadius: 12,
        overflow: 'hidden',
        padding: 2,
        width: '100%',
    },
    tableRow: {
        flexDirection: 'row',
        paddingVertical: 8,
        paddingHorizontal: 12,
    },
    tableHeaderRow: {
        borderBottomWidth: 1,
        borderBottomColor: 'rgba(255,255,255,0.1)',
    },
    tableBorder: {
        borderBottomWidth: 1,
        borderBottomColor: 'rgba(255,255,255,0.05)',
    },
    tableCell: {
        paddingHorizontal: 4,
    },
    tableHeaderText: {
        fontWeight: '600',
        fontSize: 13,
    },
    tableCellText: {
        fontSize: 13,
    },
})

export default StreamingText
