import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Phone } from 'lucide-react-native';

import TextBubbleBody from './TextBubbleBody';
import ImageBubbleBody from './ImageBubbleBody';
import VideoBubbleBody from './VideoBubbleBody';
import AudioBubbleBody from './AudioBubbleBody';
import FileBubbleBody from './FileBubbleBody';
import LocationBubbleBody from './LocationBubbleBody';
import ContactBubbleBody from './ContactBubbleBody';
import { BubbleMeta } from './BubbleMeta';
import type { ChatListBubbleMessage } from './types';
import { useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../../lib/stores/theme-store';

const FallbackBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const theme = activeTheme[effectiveTheme === 'dark' ? 'dark' : 'light'];
    const textColor = item.isMe ? theme.textColorMe : theme.textColorThem;

    return (
        <View style={styles.fallbackWrap}>
            <Text style={[styles.fallbackText, { color: textColor }]}>{item.text || 'Message'}</Text>
            <BubbleMeta timestamp={item.timestamp} status={item.status} isMe={item.isMe} isPinned={item.isPinned} />
        </View>
    );
});

const CallBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const theme = activeTheme[effectiveTheme === 'dark' ? 'dark' : 'light'];
    const textColor = item.isMe ? theme.textColorMe : theme.textColorThem;
    const isLightText = textColor.toLowerCase().includes('#f') || textColor.toLowerCase().includes('white');

    return (
        <View style={styles.callWrap}>
            <View style={[styles.callIcon, { backgroundColor: isLightText ? 'rgba(255,255,255,0.2)' : 'rgba(0,0,0,0.06)' }]}>
                <Phone size={14} color={textColor} strokeWidth={2.4} opacity={0.92} />
            </View>
            <Text style={[styles.fallbackText, { color: textColor }]}>Call</Text>
            <BubbleMeta timestamp={item.timestamp} status={item.status} isMe={item.isMe} isPinned={item.isPinned} />
        </View>
    );
});

const MessageBubbleBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    if (item.type === 'text' || item.type === 'sticker') return <TextBubbleBody item={item} />;
    if (item.type === 'image' || item.type === 'gif') return <ImageBubbleBody item={item} />;
    if (item.type === 'video') return <VideoBubbleBody item={item} />;
    if (item.type === 'voice' || item.type === 'music') return <AudioBubbleBody item={item} />;
    if (item.type === 'file') return <FileBubbleBody item={item} />;
    if (item.type === 'location') return <LocationBubbleBody item={item} />;
    if (item.type === 'contact') return <ContactBubbleBody item={item} />;
    if (item.type === 'call') return <CallBody item={item} />;
    return <FallbackBody item={item} />;
});

const styles = StyleSheet.create({
    fallbackWrap: {
        flexDirection: 'row',
        alignItems: 'flex-end',
    },
    fallbackText: {
        fontSize: 15,
        lineHeight: 19,
        flexShrink: 1,
    },
    callWrap: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 7,
    },
    callIcon: {
        width: 24,
        height: 24,
        borderRadius: 12,
        alignItems: 'center',
        justifyContent: 'center',
    },
});

export default MessageBubbleBody;
