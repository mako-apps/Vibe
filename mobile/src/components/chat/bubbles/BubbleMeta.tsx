import React from 'react';
import { StyleSheet, Text, View } from 'react-native';

import type { BubbleStatus } from './types';
import { CheckIcon, DoubleCheckIcon } from '../../Icons';
import { useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../../lib/stores/theme-store';

const DoubleCheck = React.memo(({ color }: { color: string }) => (
    <DoubleCheckIcon size={14} color={color} strokeWidth={2.4} />
));

export const BubbleStatusIcon = React.memo(({ status, isMe, color }: { status?: BubbleStatus; isMe: boolean; color: string }) => {
    if (!isMe || !status || status === 'sending') {
        return <View style={styles.statusSlot} />;
    }

    let icon: React.ReactNode = null;
    if (status === 'pending') icon = <Text style={[styles.statusPending, { color }]}>◷</Text>;
    if (status === 'sent') icon = <CheckIcon size={14} color={color} strokeWidth={2.4} />;
    if (status === 'delivered') icon = <DoubleCheck color={color} />;
    if (status === 'read') icon = <DoubleCheck color="#00A3FF" />;
    if (status === 'error') icon = <Text style={styles.statusError}>!</Text>;

    return (
        <View style={styles.statusSlot}>{icon}</View>
    );
});

export const BubbleMeta = React.memo(({
    timestamp,
    status,
    isMe,
    isEdited,
    isPinned,
}: {
    timestamp: string;
    status?: BubbleStatus;
    isMe: boolean;
    isEdited?: boolean;
    isPinned?: boolean;
}) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const isDark = effectiveTheme === 'dark';

    // Manual resolution for consistent logic
    const theme = activeTheme[isDark ? 'dark' : 'light'];
    const textColor = isMe ? theme.textColorMe : theme.textColorThem;

    // High contrast meta color
    const isLightText = textColor.toLowerCase().includes('#f') || textColor.toLowerCase().includes('white');
    const metaColor = isLightText ? 'rgba(255,255,255,0.65)' : 'rgba(0,0,0,0.55)';

    return (
        <View style={styles.timeMetaInline}>
            {isEdited ? <Text style={[styles.editedText, { color: metaColor }]}>edited</Text> : null}
            {isPinned ? <Text style={[styles.editedText, { color: metaColor }]}>pinned</Text> : null}
            <Text style={[styles.timeText, { color: metaColor }]}>{timestamp}</Text>
            <BubbleStatusIcon status={status} isMe={isMe} color={metaColor} />
        </View>
    );
});

const styles = StyleSheet.create({
    timeMetaInline: {
        flexDirection: 'row',
        alignItems: 'center',
        marginLeft: 6,
        gap: 3,
        flexShrink: 0,
        minHeight: 14,
        opacity: 0.72,
    },
    timeText: {
        fontSize: 10,
        fontWeight: '500',
    },
    editedText: {
        fontSize: 10,
        color: 'rgba(255,255,255,0.48)',
        fontWeight: '500',
    },
    statusPending: {
        fontSize: 10.5,
        lineHeight: 12,
        color: 'rgba(255,255,255,0.78)',
        marginLeft: 1,
        fontWeight: '600',
    },
    statusSending: {
        fontSize: 11,
        lineHeight: 12,
        color: 'rgba(255,255,255,0.78)',
        marginLeft: 1,
        fontWeight: '700',
    },
    statusSent: {
        fontSize: 11,
        lineHeight: 12,
        color: 'rgba(255,255,255,0.92)',
        marginLeft: 1,
        fontWeight: '700',
        textShadowColor: 'rgba(255,255,255,0.3)',
        textShadowRadius: 2,
    },
    statusError: {
        fontSize: 10,
        lineHeight: 11,
        color: '#ff7b7b',
        marginLeft: 1,
        fontWeight: '700',
    },
    doubleCheckWrap: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    statusSlot: {
        width: 16,
        minWidth: 16,
        height: 14,
        alignItems: 'center',
        justifyContent: 'center',
    },
});
