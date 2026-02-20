import React, { useEffect } from 'react';
import {
    View,
    Text,
    StyleSheet,
    Image,
    TouchableOpacity,
    Modal,
    Dimensions,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
    X,
    Check,
    MessageSquare,
    AlarmClock,
    Video,
    PhoneIncoming,
} from 'lucide-react-native';
import * as Haptics from 'expo-haptics';
import * as Notifications from 'expo-notifications';
import { Alert } from 'react-native';
import { useChatStore } from '../../lib/ChatStore';

import { useCallStore, useHasIncomingCall } from '../../lib/stores/CallStore';
import { useThemeStore } from '../../lib/stores/theme-store';
import { getUserChannel } from '../../lib/ChatStore';
import { requestPermissionsAndGetToken } from '../../lib/NotificationManager';
import SafeLiquidGlass from '../native/SafeLiquidGlass';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

// Helper for alpha colors
const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(127, 127, 127, ${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    if (color.startsWith('rgba')) {
        return color.replace(/[\d\.]+\)$/g, `${alpha})`);
    }
    return color;
};

// Button Component
const ActionButton = ({
    icon,
    label,
    onPress,
    color,
    size = 56,
    iconSize = 24,
    iconColor,
    labelColor,
    borderColor,
    tint,
}: any) => (
    <View style={{ alignItems: 'center', gap: 10 }}>
        <TouchableOpacity
            onPress={() => {
                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
                onPress();
            }}
            activeOpacity={0.7}
        >
            <SafeLiquidGlass
                style={[
                    styles.actionBtn,
                    {
                        width: size,
                        height: size,
                        borderRadius: size / 2,
                        backgroundColor: color,
                        borderColor,
                    }
                ]}
                blurIntensity={20}
                tint={tint}
            >
                {React.cloneElement(icon, { size: iconSize, color: iconColor })}
            </SafeLiquidGlass>
        </TouchableOpacity>
        {label && <Text style={[styles.actionLabel, { color: labelColor }]}>{label}</Text>}
    </View>
);

export default function IncomingCallModal() {
    const { colors, effectiveTheme } = useThemeStore();
    const insets = useSafeAreaInsets();
    const hasIncomingCall = useHasIncomingCall();

    const {
        incomingCallData,
        acceptCall,
        declineCall,
    } = useCallStore();

    useEffect(() => {
        const checkPermissions = async () => {
            const settings = await Notifications.getPermissionsAsync();
            if (settings.status !== 'granted' && settings.canAskAgain) {
                await requestPermissionsAndGetToken();
            }
        };
        checkPermissions();
    }, []);

    // Haptic loop
    useEffect(() => {
        let interval: NodeJS.Timeout;
        if (hasIncomingCall) {
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
            interval = setInterval(() => {
                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
            }, 2000);
        }
        return () => clearInterval(interval);
    }, [hasIncomingCall]);

    const handleAccept = async () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
        await acceptCall(getUserChannel());
    };

    const handleDecline = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
        declineCall(getUserChannel());
    };

    const handleMessage = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        Alert.alert(
            "Respond with Message",
            "Choose a quick response:",
            [
                { text: "I'll call you back", onPress: () => sendQuickMessage("I'll call you back") },
                { text: "I'm busy right now", onPress: () => sendQuickMessage("I'm busy right now") },
                { text: "What's up?", onPress: () => sendQuickMessage("What's up?") },
                { text: "Cancel", style: "cancel" }
            ]
        );
    };

    const sendQuickMessage = async (text: string) => {
        if (!incomingCallData) return;

        // Find or start chat with this user
        const chatStore = useChatStore.getState();
        const existingChat = chatStore.chats.find(c => c.friendId?.toUpperCase() === incomingCallData.fromUserId?.toUpperCase());

        let chatId = existingChat?.chatId;
        if (!chatId) {
            chatId = await chatStore.startChat(incomingCallData.fromUserId, {
                username: incomingCallData.fromUserName,
                profileImage: incomingCallData.fromUserImage
            });
        }

        if (chatId) {
            await chatStore.sendMessage(chatId, text);
            handleDecline();
        }
    };

    const handleRemindMe = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        Alert.alert(
            "Remind Me",
            "When should we remind you?",
            [
                { text: "In 1 hour", onPress: () => scheduleReminder(3600) },
                { text: "Today at 6:00 PM", onPress: () => scheduleReminder(null, 18) },
                { text: "Tomorrow morning", onPress: () => scheduleReminder(null, 9, true) },
                { text: "Cancel", style: "cancel" }
            ]
        );
    };

    const scheduleReminder = async (seconds?: number | null, hour?: number, tomorrow = false) => {
        if (!incomingCallData) return;

        let trigger: Notifications.NotificationTriggerInput;

        if (seconds) {
            trigger = { type: 'timeInterval', seconds } as Notifications.NotificationTriggerInput;
        } else if (hour !== undefined) {
            const date = new Date();
            date.setHours(hour, 0, 0, 0);
            if (tomorrow || date.getTime() < Date.now()) {
                date.setDate(date.getDate() + 1);
            }
            trigger = { type: 'date', date } as Notifications.NotificationTriggerInput;
        } else {
            return;
        }

        await Notifications.scheduleNotificationAsync({
            content: {
                title: "Call Reminder",
                body: `Don't forget to call back ${incomingCallData.fromUserName}`,
                data: { friendId: incomingCallData.fromUserId },
            },
            trigger,
        });

        Alert.alert("Reminder Set", `We'll remind you to call ${incomingCallData.fromUserName} back.`);
        handleDecline();
    };

    if (!hasIncomingCall || !incomingCallData) return null;

    const isVideoCall = incomingCallData.callType === 'video';
    const isDark = effectiveTheme === 'dark';
    const glassTint = isDark ? 'dark' : 'light';
    const palette = {
        background: colors.background,
        text: colors.text,
        subtleText: withAlpha(colors.text, isDark ? 0.64 : 0.58),
        avatarSurface: withAlpha(colors.card, isDark ? 0.38 : 0.54),
        utilityAction: withAlpha(colors.surface || colors.card, isDark ? 0.52 : 0.78),
        actionLabel: withAlpha(colors.text, isDark ? 0.95 : 0.9),
        actionBorder: withAlpha(colors.text, isDark ? 0.16 : 0.12),
        acceptAction: 'rgba(43, 112, 255, 0.9)',
        declineAction: 'rgba(255, 59, 48, 0.9)',
    } as const;

    return (
        <Modal
            visible={true}
            animationType="fade"
            transparent={false}
            presentationStyle="fullScreen"
        >
            <View style={[styles.container, { backgroundColor: palette.background, paddingTop: insets.top }]}>

                {/* Header Information */}
                <View style={[styles.header, { marginTop: insets.top + 40 }]}>
                    <View style={styles.callTypeRef}>
                        {isVideoCall ? <Video size={16} color={palette.subtleText} /> : <PhoneIncoming size={16} color={palette.subtleText} />}
                        <Text style={[styles.subText, { color: palette.subtleText }]}>
                            {isVideoCall ? 'Vibe Video' : 'Vibe Audio'}
                        </Text>
                    </View>
                </View>

                {/* Avatar */}
                <View style={styles.avatarContainer}>
                    <View style={[styles.avatarFrame, { backgroundColor: palette.avatarSurface }]}>
                        {incomingCallData.fromUserImage ? (
                            <Image
                                source={{ uri: incomingCallData.fromUserImage }}
                                style={styles.avatarImage}
                                resizeMode="cover"
                            />
                        ) : (
                            <Text style={[styles.initials, { color: palette.text }]}>
                                {incomingCallData.fromUserName?.[0]?.toUpperCase()}
                            </Text>
                        )}
                    </View>
                    <Text style={[styles.nameText, { color: palette.text }]}>
                        {incomingCallData.fromUserName || 'Unknown'}
                    </Text>
                </View>

                {/* Spacer pushed to bottom */}
                <View style={{ flex: 1 }} />

                {/* Improved Action Grid - Matches UI Screenshot */}
                <View style={[styles.actionsGrid, { paddingBottom: insets.bottom + 40 }]}>
                    {/* Top Row: Utility buttons */}
                    <View style={styles.actionRow}>
                        <ActionButton
                            icon={<MessageSquare />}
                            label="Message"
                            onPress={handleMessage}
                            size={52}
                            iconSize={22}
                            color={palette.utilityAction}
                            iconColor={palette.text}
                            labelColor={palette.actionLabel}
                            borderColor={palette.actionBorder}
                            tint={glassTint}
                        />
                        <ActionButton
                            icon={<AlarmClock />}
                            label="Remind Me"
                            onPress={handleRemindMe}
                            size={52}
                            iconSize={22}
                            color={palette.utilityAction}
                            iconColor={palette.text}
                            labelColor={palette.actionLabel}
                            borderColor={palette.actionBorder}
                            tint={glassTint}
                        />
                    </View>

                    {/* Bottom Row: Call Actions */}
                    <View style={styles.actionRow}>
                        <ActionButton
                            icon={<X strokeWidth={3} />}
                            label="Decline"
                            onPress={handleDecline}
                            size={76}
                            iconSize={32}
                            color={palette.declineAction}
                            iconColor={palette.text}
                            labelColor={palette.actionLabel}
                            borderColor={palette.actionBorder}
                            tint={glassTint}
                        />
                        <ActionButton
                            icon={<Check strokeWidth={3} />}
                            label="Accept"
                            onPress={handleAccept}
                            size={76}
                            iconSize={32}
                            color={palette.acceptAction}
                            iconColor={palette.text}
                            labelColor={palette.actionLabel}
                            borderColor={palette.actionBorder}
                            tint={glassTint}
                        />
                    </View>
                </View>

            </View>
        </Modal>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        alignItems: 'center',
    },
    header: {
        alignItems: 'center',
        gap: 8,
    },
    callTypeRef: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
        marginBottom: 8,
    },
    subText: {
        fontSize: 15,
        fontWeight: '500',
        letterSpacing: 0.2,
    },
    nameText: {
        fontSize: 34,
        fontWeight: '700',
        letterSpacing: -0.5,
        textAlign: 'center',
        paddingHorizontal: 20
    },
    avatarContainer: {
        marginTop: 60,
        justifyContent: 'center',
        alignItems: 'center',
        gap: 18,
    },
    avatarFrame: {
        width: 140,
        height: 140,
        borderRadius: 70,
        justifyContent: 'center',
        alignItems: 'center',
    },
    avatarImage: {
        width: 140,
        height: 140,
        borderRadius: 70,
    },
    initials: {
        fontSize: 56,
        fontWeight: '700',
    },
    actionsGrid: {
        width: '100%',
        paddingHorizontal: 54,
        gap: 48,
    },
    actionRow: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'flex-start',
    },
    actionBtn: {
        justifyContent: 'center',
        alignItems: 'center',
        borderWidth: 0.5,
        overflow: 'hidden',
    },
    actionLabel: {
        fontSize: 14,
        fontWeight: '500',
        textAlign: 'center',
        opacity: 0.9,
    }
});
