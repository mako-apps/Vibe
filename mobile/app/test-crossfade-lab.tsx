import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
    FlatList,
    Platform,
    Pressable,
    StyleSheet,
    Text,
    TextInput,
    View,
} from 'react-native';
import Animated, {
    Easing,
    interpolate,
    runOnJS,
    useAnimatedStyle,
    useDerivedValue,
    useSharedValue,
    withTiming,
} from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import * as ExpoCrypto from 'expo-crypto';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ChevronLeft, SendHorizontal } from 'lucide-react-native';
import { useRouter } from 'expo-router';
import { useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';

type Message = {
    id: string;
    text: string;
    isMe: boolean;
    timestamp: string;
    isHidden?: boolean;
};

type PendingGhost = {
    id: string;
    text: string;
    startX: number;
    startY: number;
    startW: number;
    startH: number;
};

type GhostData = PendingGhost & {
    targetX: number;
    targetY: number;
    targetW: number;
    targetH: number;
};

type AnimationPreset = {
    id: string;
    label: string;
    duration: number;
    easing: (v: number) => number;
    yMode: 'linear' | 'hold';
    yHoldPoint: number;
    yHoldAmount: number;
    bgFadeStart: number;
    bgFadeEnd: number;
    textFadeStart: number;
    textFadeEnd: number;
    inputFadeEnd: number;
};

const BUBBLE_RADIUS = 18;
const MASK_PADDING = 16;

const PRESETS: AnimationPreset[] = [
    {
        id: 'linear',
        label: 'Linear',
        duration: 230,
        easing: Easing.linear,
        yMode: 'linear',
        yHoldPoint: 0.5,
        yHoldAmount: 0.5,
        bgFadeStart: 0.05,
        bgFadeEnd: 0.2,
        textFadeStart: 0.08,
        textFadeEnd: 0.22,
        inputFadeEnd: 0.14,
    },
    {
        id: 'easeOut',
        label: 'Ease Out',
        duration: 280,
        easing: Easing.bezier(0.18, 0.92, 0.32, 1),
        yMode: 'linear',
        yHoldPoint: 0.5,
        yHoldAmount: 0.5,
        bgFadeStart: 0.06,
        bgFadeEnd: 0.25,
        textFadeStart: 0.08,
        textFadeEnd: 0.24,
        inputFadeEnd: 0.12,
    },
    {
        id: 'holdYSoft',
        label: 'Hold Y Soft',
        duration: 300,
        easing: Easing.bezier(0.22, 0.7, 0.3, 1),
        yMode: 'hold',
        yHoldPoint: 0.62,
        yHoldAmount: 0.28,
        bgFadeStart: 0.08,
        bgFadeEnd: 0.28,
        textFadeStart: 0.1,
        textFadeEnd: 0.29,
        inputFadeEnd: 0.14,
    },
    {
        id: 'holdYLate',
        label: 'Hold Y Late',
        duration: 320,
        easing: Easing.bezier(0.22, 0.65, 0.3, 1),
        yMode: 'hold',
        yHoldPoint: 0.72,
        yHoldAmount: 0.84,
        bgFadeStart: 0.1,
        bgFadeEnd: 0.32,
        textFadeStart: 0.12,
        textFadeEnd: 0.34,
        inputFadeEnd: 0.15,
    },
    {
        id: 'snappy',
        label: 'Snappy',
        duration: 210,
        easing: Easing.bezier(0.2, 1, 0.2, 1),
        yMode: 'linear',
        yHoldPoint: 0.5,
        yHoldAmount: 0.5,
        bgFadeStart: 0.03,
        bgFadeEnd: 0.15,
        textFadeStart: 0.05,
        textFadeEnd: 0.18,
        inputFadeEnd: 0.09,
    },
];

const formatTime = () => new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });

function MessageBubble({
    item,
    onMeasure,
}: {
    item: Message;
    onMeasure?: (id: string, x: number, y: number, w: number, h: number) => void;
}) {
    const bubbleRef = useRef<View>(null);

    const measure = useCallback(() => {
        bubbleRef.current?.measureInWindow((x, y, w, h) => {
            if (w > 0 && h > 0 && onMeasure) onMeasure(item.id, x, y, w, h);
        });
    }, [item.id, onMeasure]);

    useEffect(() => {
        const raf = requestAnimationFrame(measure);
        return () => cancelAnimationFrame(raf);
    }, [measure, item.text, item.isHidden]);

    return (
        <View
            style={[
                styles.row,
                { alignItems: item.isMe ? 'flex-end' : 'flex-start' },
                item.isHidden && { opacity: 0 },
            ]}
        >
            <View ref={bubbleRef} collapsable={false}>
                {item.isMe ? (
                    <LinearGradient
                        colors={['#6E4BFF', '#4F87FF']}
                        start={{ x: 0, y: 0 }}
                        end={{ x: 1, y: 1 }}
                        style={styles.meBubble}
                    >
                        <Text style={styles.meText}>{item.text}</Text>
                        <Text style={styles.meTime}>{item.timestamp}</Text>
                    </LinearGradient>
                ) : (
                    <View style={styles.themBubble}>
                        <Text style={styles.themText}>{item.text}</Text>
                        <Text style={styles.themTime}>{item.timestamp}</Text>
                    </View>
                )}
            </View>
        </View>
    );
}

function CrossfadeGhost({
    data,
    preset,
    onComplete,
}: {
    data: GhostData;
    preset: AnimationPreset;
    onComplete: () => void;
}) {
    const progress = useSharedValue(0);

    useEffect(() => {
        progress.value = withTiming(1, { duration: preset.duration, easing: preset.easing }, (finished) => {
            if (finished) runOnJS(onComplete)();
        });
    }, [preset, onComplete]);

    const containerStyle = useAnimatedStyle(() => {
        const p = progress.value;
        const tx = interpolate(p, [0, 1], [data.startX - data.targetX, 0]);
        const yProgress = preset.yMode === 'hold'
            ? interpolate(p, [0, preset.yHoldPoint, 1], [0, preset.yHoldAmount, 1], 'clamp')
            : p;
        const ty = (data.startY - data.targetY) * (1 - yProgress);
        return {
            position: 'absolute' as const,
            left: data.targetX,
            top: data.targetY,
            width: data.targetW,
            height: data.targetH,
            zIndex: 999,
            transform: [{ translateX: tx }, { translateY: ty }],
        };
    });

    const bgStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [preset.bgFadeStart, preset.bgFadeEnd], [0, 1], 'clamp'),
    }));

    const textStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [preset.textFadeStart, preset.textFadeEnd], [0, 1], 'clamp'),
    }));

    const inputTextStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, preset.inputFadeEnd], [1, 0], 'clamp'),
    }));

    return (
        <Animated.View style={containerStyle} pointerEvents="none">
            <Animated.View style={[styles.ghostBg, bgStyle]}>
                <LinearGradient
                    colors={['#6E4BFF', '#4F87FF']}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 1 }}
                    style={StyleSheet.absoluteFillObject}
                />
            </Animated.View>
            <View style={styles.ghostContent}>
                <Animated.View style={[styles.ghostInputTextWrap, inputTextStyle]}>
                    <Text style={styles.ghostInputText}>{data.text}</Text>
                </Animated.View>
                <Animated.View style={textStyle}>
                    <Text style={styles.ghostText}>{data.text}</Text>
                </Animated.View>
            </View>
        </Animated.View>
    );
}

export default function TestCrossfadeLab() {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const [presetId, setPresetId] = useState(PRESETS[0].id);
    const [text, setText] = useState('');
    const [messages, setMessages] = useState<Message[]>([
        { id: 'seed-1', text: 'Try presets and compare smoothness.', isMe: false, timestamp: formatTime() },
    ]);
    const [pendingGhost, setPendingGhost] = useState<PendingGhost | null>(null);
    const [ghostData, setGhostData] = useState<GhostData | null>(null);
    const inputAnchorRef = useRef<View>(null);
    const preset = useMemo(() => PRESETS.find(p => p.id === presetId) || PRESETS[0], [presetId]);
    const { height: keyboardHeight } = useReanimatedKeyboardAnimation();
    // Android uses `adjustResize` via keyboard-controller; applying extra translateY double-shifts.
    const keyboardShift = useDerivedValue(() => (Platform.OS === 'ios' ? Math.max(Math.abs(keyboardHeight.value), 0) : 0));
    const pageShiftStyle = useAnimatedStyle(() => ({ transform: [{ translateY: -keyboardShift.value }] }));
    const footerHeight = 48 + (insets.bottom + 8) + 10;

    const onBubbleMeasure = useCallback((id: string, x: number, y: number, w: number, h: number) => {
        setPendingGhost(prev => {
            if (!prev || prev.id !== id) return prev;
            setGhostData({
                ...prev,
                targetX: x,
                targetY: y,
                targetW: w,
                targetH: h,
            });
            return null;
        });
    }, []);

    const onGhostComplete = useCallback(() => {
        if (!ghostData) return;
        setMessages(prev => prev.map(m => (m.id === ghostData.id ? { ...m, isHidden: false } : m)));
        setGhostData(null);
    }, [ghostData]);

    const send = useCallback(() => {
        const content = text.trim();
        if (!content) return;
        const id = ExpoCrypto.randomUUID();
        inputAnchorRef.current?.measureInWindow((x, y, w) => {
            const startW = Math.max(80, Math.min(w - 80, content.length * 8 + 24));
            const startX = x + MASK_PADDING;
            const startY = y + 8;
            setMessages(prev => [{ id, text: content, isMe: true, timestamp: formatTime(), isHidden: true }, ...prev]);
            setPendingGhost({
                id,
                text: content,
                startX,
                startY,
                startW,
                startH: 34,
            });
            setText('');
        });
    }, [text]);

    return (
        <View style={styles.screen}>
            <Animated.View style={[styles.screenInner, pageShiftStyle]}>
                <View style={[styles.topBar, { paddingTop: insets.top + 6 }]}>
                    <Pressable onPress={() => router.back()} style={styles.backBtn}>
                        <ChevronLeft size={24} color="#fff" />
                    </Pressable>
                    <Text style={styles.topTitle}>Crossfade Lab</Text>
                </View>

                <View style={styles.presetStrip}>
                    <FlatList
                        data={PRESETS}
                        horizontal
                        keyExtractor={(item) => item.id}
                        showsHorizontalScrollIndicator={false}
                        contentContainerStyle={styles.presetListContent}
                        renderItem={({ item }) => {
                            const selected = item.id === presetId;
                            return (
                                <Pressable
                                    onPress={() => setPresetId(item.id)}
                                    style={[styles.presetChip, selected && styles.presetChipActive]}
                                >
                                    <Text style={[styles.presetChipText, selected && styles.presetChipTextActive]}>{item.label}</Text>
                                </Pressable>
                            );
                        }}
                    />
                </View>

                <FlatList
                    data={messages}
                    inverted
                    keyExtractor={(item) => item.id}
                    renderItem={({ item }) => <MessageBubble item={item} onMeasure={onBubbleMeasure} />}
                    contentContainerStyle={styles.listContent}
                    // In an inverted list, `ListHeaderComponent` is visually at the bottom.
                    ListHeaderComponent={<View style={{ height: footerHeight + 8 }} />}
                    ListFooterComponent={<View style={{ height: insets.top + 12 }} />}
                    showsVerticalScrollIndicator={false}
                    keyboardDismissMode="interactive"
                    keyboardShouldPersistTaps="handled"
                    maintainVisibleContentPosition={{ minIndexForVisible: 1, autoscrollToTopThreshold: 8 }}
                />

                <View style={styles.inputSticky}>
                    <View style={[styles.inputDock, { paddingBottom: insets.bottom + 8 }]}>
                        <View ref={inputAnchorRef} style={styles.inputRow}>
                        <TextInput
                            value={text}
                            onChangeText={setText}
                            placeholder="Type test message"
                            placeholderTextColor="rgba(255,255,255,0.4)"
                            style={styles.input}
                            multiline={false}
                            returnKeyType="send"
                            onSubmitEditing={send}
                        />
                        <Pressable onPress={send} style={styles.sendBtn}>
                            <SendHorizontal size={16} color="#fff" />
                        </Pressable>
                        </View>
                    </View>
                </View>

                {ghostData && (
                    <CrossfadeGhost
                        data={ghostData}
                        preset={preset}
                        onComplete={onGhostComplete}
                    />
                )}
            </Animated.View>
        </View>
    );
}

const styles = StyleSheet.create({
    screen: {
        flex: 1,
        backgroundColor: '#06080f',
    },
    screenInner: {
        flex: 1,
    },
    topBar: {
        paddingHorizontal: 10,
        flexDirection: 'row',
        alignItems: 'center',
    },
    backBtn: {
        width: 38,
        height: 38,
        alignItems: 'center',
        justifyContent: 'center',
    },
    topTitle: {
        color: '#fff',
        fontSize: 17,
        fontWeight: '700',
    },
    presetStrip: {
        marginTop: 8,
    },
    presetListContent: {
        paddingHorizontal: 12,
    },
    presetChip: {
        marginRight: 8,
        paddingHorizontal: 10,
        paddingVertical: 6,
        borderRadius: 13,
        backgroundColor: 'rgba(255,255,255,0.08)',
    },
    presetChipActive: {
        backgroundColor: 'rgba(138,170,255,0.35)',
    },
    presetChipText: {
        color: 'rgba(255,255,255,0.72)',
        fontSize: 12,
        fontWeight: '600',
    },
    presetChipTextActive: {
        color: '#fff',
    },
    listContent: {
        paddingHorizontal: 0,
        paddingTop: 8,
    },
    row: {
        marginVertical: 2,
        paddingHorizontal: 8,
    },
    meBubble: {
        borderRadius: BUBBLE_RADIUS,
        paddingHorizontal: 12,
        paddingVertical: 8,
        maxWidth: '85%',
        alignSelf: 'flex-end',
    },
    themBubble: {
        borderRadius: BUBBLE_RADIUS,
        paddingHorizontal: 12,
        paddingVertical: 8,
        maxWidth: '85%',
        backgroundColor: 'rgba(255,255,255,0.12)',
        alignSelf: 'flex-start',
    },
    meText: {
        color: '#fff',
        fontSize: 16,
        lineHeight: 20,
    },
    meTime: {
        color: 'rgba(255,255,255,0.72)',
        fontSize: 10,
        marginTop: 1,
        textAlign: 'right',
    },
    themText: {
        color: '#e5e9ff',
        fontSize: 16,
        lineHeight: 20,
    },
    themTime: {
        color: 'rgba(255,255,255,0.52)',
        fontSize: 10,
        marginTop: 1,
        textAlign: 'right',
    },
    inputSticky: {
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: 0,
        zIndex: 50,
    },
    inputDock: {
        paddingHorizontal: 10,
    },
    inputRow: {
        height: 48,
        borderRadius: 24,
        backgroundColor: 'rgba(255,255,255,0.1)',
        borderWidth: StyleSheet.hairlineWidth,
        borderColor: 'rgba(255,255,255,0.24)',
        paddingLeft: 14,
        paddingRight: 6,
        flexDirection: 'row',
        alignItems: 'center',
    },
    input: {
        flex: 1,
        color: '#fff',
        fontSize: 16,
        paddingVertical: 0,
    },
    sendBtn: {
        width: 36,
        height: 36,
        borderRadius: 18,
        backgroundColor: '#4F87FF',
        alignItems: 'center',
        justifyContent: 'center',
    },
    ghostBg: {
        ...StyleSheet.absoluteFillObject,
        borderRadius: BUBBLE_RADIUS,
        overflow: 'hidden',
    },
    ghostContent: {
        flex: 1,
        paddingHorizontal: 12,
        paddingVertical: 8,
    },
    ghostText: {
        color: '#fff',
        fontSize: 16,
        lineHeight: 20,
    },
    ghostInputTextWrap: {
        position: 'absolute',
        right: 12,
        top: 8,
    },
    ghostInputText: {
        color: '#fff',
        fontSize: 16,
        lineHeight: 20,
    },
});
