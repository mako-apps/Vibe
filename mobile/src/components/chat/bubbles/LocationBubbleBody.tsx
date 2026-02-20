import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { MapPin } from 'lucide-react-native';

import { BubbleMeta } from './BubbleMeta';
import type { ChatListBubbleMessage } from './types';
import { useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../../lib/stores/theme-store';

const formatCoords = (lat?: number, lng?: number) => {
    if (typeof lat !== 'number' || typeof lng !== 'number') return 'Location';
    return `${lat.toFixed(5)}, ${lng.toFixed(5)}`;
};

const LocationBubbleBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const theme = activeTheme[effectiveTheme === 'dark' ? 'dark' : 'light'];
    const textColor = item.isMe ? theme.textColorMe : theme.textColorThem;
    const isLightText = textColor.toLowerCase().includes('#f') || textColor.toLowerCase().includes('white');
    const cardBg = isLightText ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)';
    return (
        <View style={styles.wrap}>
            <View style={[styles.card, { backgroundColor: cardBg }]}>
                <View style={[styles.iconWrap, { backgroundColor: isLightText ? 'rgba(255,255,255,0.22)' : 'rgba(0,0,0,0.12)' }]}>
                    <MapPin size={20} color={textColor} strokeWidth={2.4} />
                </View>
                <Text style={[styles.label, { color: textColor }]} numberOfLines={1}>
                    {formatCoords(item.latitude, item.longitude)}
                </Text>
            </View>
            <View style={styles.metaRow}>
                <BubbleMeta timestamp={item.timestamp} status={item.status} isMe={item.isMe} isPinned={item.isPinned} />
            </View>
        </View>
    );
});

const styles = StyleSheet.create({
    wrap: {
        minWidth: 170,
    },
    card: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 8,
        borderRadius: 12,
        marginBottom: 2,
        marginTop: 2,
    },
    iconWrap: {
        width: 40,
        height: 40,
        borderRadius: 20,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 10,
    },
    label: {
        flex: 1,
        fontSize: 13,
        fontWeight: '600',
    },
    metaRow: {
        marginTop: 4,
        alignItems: 'flex-end',
    },
});

export default LocationBubbleBody;
