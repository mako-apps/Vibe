import React, { useState, useEffect } from 'react';
import {
    View, Text, StyleSheet, TouchableOpacity, ScrollView,
    Switch, TextInput, Alert, Share, ActivityIndicator, Dimensions, Keyboard, Platform, Pressable
} from 'react-native';
import {
    X, Globe, Shield, Radio, Users, Wifi, Copy,
    ChevronRight, Server, Check, Share2, Activity, Lock
} from 'lucide-react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    runOnJS,
    Easing,
} from 'react-native-reanimated';
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler';
import { useThemeStore } from '../../lib/stores/theme-store';
import AnimatedGlassButton from '../native/AnimatedGlassButton';
import * as Clipboard from 'expo-clipboard';
import * as Haptics from 'expo-haptics';

import RelayNode from '../../lib/relay/RelayNode';
import { getPhoenixSocket } from '../../lib/ChatStore';
import type { RelayStatus, RelayConfig } from '../../lib/relay/RelayNode';

const { height: SCREEN_HEIGHT } = Dimensions.get('window');
const MODAL_HEIGHT = SCREEN_HEIGHT * 0.94;
const OPEN_Y = 0;
const CLOSED_Y = SCREEN_HEIGHT;
const SMOOTH_TIMING = { duration: 400, easing: Easing.bezier(0.25, 0.1, 0.25, 1) };
const AnimatedView = Animated.View as any;
const GestureHandlerRootViewAny = GestureHandlerRootView as any;

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

const formatBytes = (bytes: number): string => {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
};

// ─── Shared UI Components ─────────────────────────────────────────────

const SettingRow = ({
    icon: Icon,
    iconBg,
    label,
    sublabel,
    value,
    onPress,
    right,
    showArrow = true,
    isLast = false,
}: {
    icon: any,
    iconBg: string,
    label: string,
    sublabel?: string,
    value?: string,
    onPress?: () => void,
    right?: React.ReactNode,
    showArrow?: boolean,
    isLast?: boolean
}) => {
    const { colors } = useThemeStore();
    return (
        <View style={{ width: '100%' }}>
            <TouchableOpacity
                style={[s.settingRow, { minHeight: 52, paddingVertical: 12, paddingHorizontal: 16 }]}
                onPress={onPress}
                disabled={!onPress}
                activeOpacity={0.7}
            >
                {Icon && (
                    <View style={[s.settingIconContainer, { backgroundColor: iconBg || withAlpha(colors.primary, 0.1), marginRight: 12 }]}>
                        <Icon size={16} color="#fff" />
                    </View>
                )}
                <View style={s.rowContent}>
                    <View style={{ flex: 1, justifyContent: 'center' }}>
                        <Text style={[s.settingLabel, { color: colors.text }]}>{label}</Text>
                        {sublabel && <Text style={[s.rowSub, { color: colors.textSecondary }]}>{sublabel}</Text>}
                    </View>
                    <View style={s.rowRight}>
                        {value && <Text style={[s.settingValue, { color: colors.textSecondary }]}>{value}</Text>}
                        {right}
                        {onPress && showArrow && <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />}
                    </View>
                </View>
            </TouchableOpacity>
            {!isLast && <View style={[s.divider, { backgroundColor: withAlpha(colors.text, 0.05), marginLeft: Icon ? 58 : 16 }]} />}
        </View>
    );
};

const SettingGroup = ({ children }: { children: React.ReactNode }) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    return (
        <View style={[s.sectionContainer, {
            backgroundColor: isLight ? '#ffffff' : colors.card,
            borderRadius: 28,
            marginBottom: 20
        }]}>
            {children}
        </View>
    );
};

const MetricBox = ({ label, value, icon: Icon, color }: { label: string; value: string; icon: any; color: string }) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    return (
        <View style={{
            flex: 1,
            backgroundColor: isLight ? '#ffffff' : colors.card,
            borderRadius: 28,
            padding: 16,
            minHeight: 88,
            justifyContent: 'center',
            gap: 6
        }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                <View style={{ width: 24, height: 24, borderRadius: 8, backgroundColor: withAlpha(color, 0.1), alignItems: 'center', justifyContent: 'center' }}>
                    <Icon size={14} color={color} />
                </View>
                <Text style={{ fontSize: 13, color: colors.textSecondary, fontWeight: '500' }}>{label}</Text>
            </View>
            <Text style={{ fontSize: 17, color: colors.text, fontWeight: '600', marginLeft: 2 }}>{value}</Text>
        </View>
    );
};

// ─── Host Settings Modal (Default Export) ──────────────────────────────────────────────
export default function RelayModal({ visible, onClose, parentScale }: any) {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const bg = colors.background;

    const translateY = useSharedValue(CLOSED_Y);
    const backdrop = useSharedValue(0);
    const startY = useSharedValue(0);

    // Node State
    const [relayEnabled, setRelayEnabled] = useState(false);
    const [relayStatus, setRelayStatus] = useState<RelayStatus>('stopped');
    const [peerCount, setPeerCount] = useState(0);
    const [bytesRelayed, setBytesRelayed] = useState(0);
    const [connectedPeers, setConnectedPeers] = useState<{ id: string; region?: string; connectedAt: number }[]>([]);
    const [config, setConfig] = useState<RelayConfig | null>(null);
    const [codeCopied, setCodeCopied] = useState(false);

    // Name Editing
    const [editingName, setEditingName] = useState(false);
    const [nameInput, setNameInput] = useState('');

    const [mounted, setMounted] = useState(visible);

    useEffect(() => {
        if (visible) {
            setMounted(true);
            translateY.value = withTiming(OPEN_Y, { duration: 350, easing: Easing.out(Easing.exp) });
            backdrop.value = withTiming(1, { duration: 250 });
            if (parentScale) parentScale.value = withTiming(0.92, SMOOTH_TIMING);
        } else {
            backdrop.value = withTiming(0, { duration: 200 });
            translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => {
                runOnJS(setMounted)(false);
            });
            if (parentScale) parentScale.value = withTiming(1, SMOOTH_TIMING);
        }
    }, [visible]);

    useEffect(() => {
        const node = RelayNode.getInstance();
        const nodeConfig = node.getConfig();
        setConfig(nodeConfig);
        setRelayEnabled(nodeConfig.enabled);
        setRelayStatus(node.getStatus());
        setPeerCount(node.getPeerCount());
        setBytesRelayed(node.getTotalBytesRelayed());

        const u1 = node.subscribe((ev, d) => {
            if (ev === 'status-changed') setRelayStatus(d);
            if (ev === 'config-changed') { setConfig(d); setRelayEnabled(d.enabled); }
            if (ev === 'peer-connected') {
                setPeerCount(d.peerCount);
                setConnectedPeers(prev => [...prev, { id: d.peerId, region: d.region || 'Unknown', connectedAt: Date.now() }]);
            }
            if (ev === 'peer-disconnected') {
                setPeerCount(d.peerCount);
                setConnectedPeers(prev => prev.filter(p => p.id !== d.peerId));
            }
            setBytesRelayed(node.getTotalBytesRelayed());
        });
        return () => u1();
    }, []);

    // Re-sync state when modal becomes visible
    useEffect(() => {
        if (visible) {
            const node = RelayNode.getInstance();
            setConfig(node.getConfig());
            setRelayEnabled(node.getConfig().enabled);
            setRelayStatus(node.getStatus());
            setPeerCount(node.getPeerCount());
            setBytesRelayed(node.getTotalBytesRelayed());
        }
    }, [visible]);

    const handleClose = () => {
        onClose();
    };

    const handleToggleRelay = async (val: boolean) => {
        const node = RelayNode.getInstance();
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        if (val) {
            const res = await node.startRelay(getPhoenixSocket());
            if (res.success) {
                setRelayEnabled(true);
                setConfig(node.getConfig());
            }
            else Alert.alert('Error', res.error || 'Failed to start');
        } else {
            await node.stopRelay();
            setRelayEnabled(false);
            setConnectedPeers([]);
            setConfig(node.getConfig());
        }
    };

    const handleTogglePublic = async (val: boolean) => {
        const node = RelayNode.getInstance();
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
        await node.updateConfig({ isPublic: val });
        setConfig(node.getConfig());
    };

    const handleToggleWifiOnly = async (val: boolean) => {
        const node = RelayNode.getInstance();
        await node.updateConfig({ wifiOnly: val });
        setConfig(node.getConfig());
    };

    const handleSetMaxPeers = async (count: number) => {
        const node = RelayNode.getInstance();
        await node.updateConfig({ maxPeers: count });
        setConfig(node.getConfig());
    };

    const handleSaveName = async () => {
        if (nameInput.trim()) {
            const node = RelayNode.getInstance();
            await node.updateConfig({ name: nameInput.trim() });
            setConfig(node.getConfig());
        }
        setEditingName(false);
    };

    const handleCopyInviteCode = async () => {
        if (config?.inviteCode) {
            await Clipboard.setStringAsync(config.inviteCode);
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            setCodeCopied(true);
            setTimeout(() => setCodeCopied(false), 2000);
        }
    };

    const handleShareInviteCode = async () => {
        if (config?.inviteCode) {
            await Share.share({
                message: `Join my Vibe relay node: ${config.inviteCode}`,
            });
        }
    };

    const getStatusText = () => {
        if (!relayEnabled) return 'Offline';
        if (relayStatus === 'running') return 'Running';
        if (relayStatus === 'starting') return 'Starting...';
        return 'Stopped';
    };

    const getStatusColor = () => {
        if (!relayEnabled) return colors.textSecondary;
        if (relayStatus === 'running') return '#10b981';
        if (relayStatus === 'starting') return '#f59e0b';
        return '#ef4444';
    };


    const gesture = Gesture.Pan()
        .activeOffsetY([-10, 10])
        .onBegin(() => { startY.value = translateY.value })
        .onUpdate((e) => {
            const nextY = startY.value + e.translationY;
            translateY.value = Math.max(OPEN_Y, Math.min(CLOSED_Y, nextY));
        })
        .onEnd((e) => {
            if (translateY.value > 120 || e.velocityY > 1000) {
                runOnJS(handleClose)();
            } else {
                translateY.value = withTiming(OPEN_Y, { duration: 250 });
            }
        });

    const panelStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }],
        opacity: backdrop.value,
        borderTopLeftRadius: 28,
        borderTopRightRadius: 28,
        height: MODAL_HEIGHT,
        bottom: 0,
        position: 'absolute',
        left: 0,
        right: 0,
        overflow: 'hidden',
    }));

    const overlayStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value,
        backgroundColor: 'rgba(0,0,0,0.3)'
    }));

    const activeHeader = useSharedValue(0);

    if (!mounted) return null;

    return (
        <GestureHandlerRootViewAny style={[StyleSheet.absoluteFill, { zIndex: 999 }]}>
            <AnimatedView style={[StyleSheet.absoluteFill, overlayStyle]}>
                <Pressable style={StyleSheet.absoluteFill} onPress={handleClose} />
            </AnimatedView>

            <GestureDetector gesture={gesture}>
                <AnimatedView style={[panelStyle, { backgroundColor: bg }]}>
                    {/* Header - Referral Style */}
                    <View style={[s.header, { position: 'absolute', top: 20, left: 0, right: 0, zIndex: 120, justifyContent: 'space-between', alignItems: 'center' }]}>
                        <View style={{ width: 40 }} />
                        <Text style={[s.headerTitle, { color: colors.text }]}>Host Settings</Text>
                        <AnimatedGlassButton
                            onPress={handleClose}
                            progress={activeHeader}
                            showPanelIcon={false}
                            effectiveTheme={effectiveTheme}
                            size={40}
                            homeIcon={<X size={20} color={colors.text} strokeWidth={2.5} />}
                            panelIcon={<View />}
                            homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                        />
                    </View>

                    <ScrollView
                        contentContainerStyle={[s.childScrollContent, { paddingTop: 100 }]}
                        showsVerticalScrollIndicator={false}
                    >
                        {/* Node Identity - Input Only */}
                        <View style={s.groupHeader}>
                            <Text style={[s.groupTitle, { color: colors.textSecondary }]}>Node Identity</Text>
                        </View>
                        <SettingGroup>
                            <View style={{ paddingHorizontal: 20, paddingVertical: 16 }}>
                                <View style={{
                                    flexDirection: 'row',
                                    alignItems: 'center',

                                    borderRadius: 22,
                                    height: 25,
                                    paddingHorizontal: 0
                                }}>

                                    <TextInput
                                        style={{
                                            flex: 1,
                                            marginLeft: 11,
                                            color: colors.text,
                                            fontSize: 16,
                                            fontWeight: '500',
                                            height: '100%'
                                        }}
                                        value={config?.name || ''}
                                        onChangeText={(t) => {
                                            setNameInput(t);
                                            // Optional: update node name on change or leave as is
                                        }}
                                        onBlur={handleSaveName}
                                        placeholder="Enter node name"
                                        placeholderTextColor={withAlpha(colors.textSecondary, 0.4)}
                                        returnKeyType="done"
                                        onSubmitEditing={handleSaveName}
                                    />
                                </View>
                            </View>
                        </SettingGroup>

                        {/* Invite Code */}
                        {config?.inviteCode && (
                            <>
                                <View style={s.groupHeader}>
                                    <Text style={[s.groupTitle, { color: colors.textSecondary }]}>Invite Code</Text>
                                </View>
                                <SettingGroup>
                                    <SettingRow
                                        label="Invite Code"
                                        value={config.inviteCode}
                                        onPress={handleCopyInviteCode}
                                        icon={codeCopied ? Check : Copy}
                                        iconBg={codeCopied ? withAlpha('#10b981', 0.1) : withAlpha(colors.textSecondary, 0.1)}
                                        showArrow={false}
                                        right={<Share2 size={18} color={colors.textSecondary} onPress={handleShareInviteCode} />}
                                        isLast
                                    />
                                </SettingGroup>
                            </>
                        )}

                        {/* Configuration */}
                        <View style={s.groupHeader}>
                            <Text style={[s.groupTitle, { color: colors.textSecondary }]}>Configuration</Text>
                        </View>
                        <SettingGroup>
                            <SettingRow
                                icon={config?.isPublic ? Globe : Lock}
                                iconBg={config?.isPublic ? '#10b981' : '#f59e0b'}
                                label={config?.isPublic ? 'Public' : 'Private'}
                                right={<Switch
                                    value={config?.isPublic ?? false}
                                    onValueChange={handleTogglePublic}
                                    trackColor={{ false: '#3a3a3c', true: '#34c759' }}
                                    thumbColor="#fff"
                                />}
                                showArrow={false}
                            />
                            <SettingRow
                                icon={Users}
                                iconBg="#8b5cf6"
                                label="Max Peers"
                                value={(config?.maxPeers ?? 5).toString()}
                                onPress={() => {
                                    const options = [3, 5, 10, 20];
                                    const current = config?.maxPeers ?? 5;
                                    const next = options[(options.indexOf(current) + 1) % options.length];
                                    handleSetMaxPeers(next);
                                }}
                                showArrow={true}
                            />
                            <SettingRow
                                icon={Wifi}
                                iconBg="#ec4899"
                                label="Wi-Fi Only"
                                right={<Switch
                                    value={config?.wifiOnly ?? true}
                                    onValueChange={handleToggleWifiOnly}
                                    trackColor={{ false: '#3a3a3c', true: '#34c759' }}
                                    thumbColor="#fff"
                                />}
                                showArrow={false}
                                isLast
                            />
                        </SettingGroup>


                    </ScrollView>
                </AnimatedView>
            </GestureDetector>
        </GestureHandlerRootViewAny>
    );
}

const s = StyleSheet.create({
    settingRow: { flexDirection: 'row', alignItems: 'center' },
    settingIconContainer: { width: 28, height: 28, borderRadius: 6, alignItems: 'center', justifyContent: 'center' },
    rowContent: { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
    settingLabel: { fontSize: 15, fontWeight: '500' },
    rowSub: { fontSize: 12, marginTop: 2, marginRight: 8 },
    rowRight: { flexDirection: 'row', alignItems: 'center', gap: 8 },
    settingValue: { fontSize: 15, opacity: 0.7 },
    divider: { height: 1, marginLeft: 58 },
    sectionContainer: { borderRadius: 28, overflow: 'hidden' },
    groupHeader: { marginTop: 20, marginBottom: 8, paddingHorizontal: 16, paddingRight: 4, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
    groupTitle: { fontSize: 13, fontWeight: '500', color: '#8e8e93' },

    header: { flexDirection: 'row', paddingHorizontal: 10 },
    headerTitle: { fontSize: 17, fontWeight: '600' },
    childScrollContent: { paddingHorizontal: 16, paddingBottom: 60 },
    description: { fontSize: 13, textAlign: 'center', marginTop: 8, paddingHorizontal: 20, lineHeight: 18 },

    inlineEdit: { padding: 12, borderRadius: 16, marginTop: 8, flexDirection: 'row', alignItems: 'center', gap: 8 },
    input: { flex: 1, height: 44, borderRadius: 12, paddingHorizontal: 12, fontSize: 16 },
    connectBtn: { width: 44, height: 44, borderRadius: 12, alignItems: 'center', justifyContent: 'center' },

    inviteCodeContainer: { padding: 16, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
    inviteCodeText: { fontSize: 18, fontWeight: '700', letterSpacing: 2, fontFamily: Platform.OS === 'ios' ? 'Courier' : 'monospace' },
    inviteBtn: { width: 36, height: 36, borderRadius: 10, alignItems: 'center', justifyContent: 'center' },

    relayIdBox: { padding: 16, borderRadius: 12, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 },
    relayIdLabel: { fontSize: 12, fontWeight: '600', textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 4 },
    relayIdValue: { fontSize: 18, fontWeight: '700', letterSpacing: 2, fontFamily: Platform.OS === 'ios' ? 'Courier' : 'monospace' },
    copyBtn: { width: 40, height: 40, borderRadius: 10, alignItems: 'center', justifyContent: 'center' }
});
