import React from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { BubbleMeta } from './BubbleMeta';
import type { ChatListBubbleMessage } from './types';
import { useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../../lib/stores/theme-store';

const TextBubbleBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const isDark = effectiveTheme === 'dark';
    const theme = activeTheme[isDark ? 'dark' : 'light'];

    const textColor = item.isMe ? theme.textColorMe : theme.textColorThem;

    return (
        <View style={styles.row}>
            <Text style={[styles.text, { color: textColor }]}>{item.text}</Text>
            <BubbleMeta timestamp={item.timestamp} status={item.status} isMe={item.isMe} isEdited={item.isEdited} isPinned={item.isPinned} />
        </View>
    );
});

const styles = StyleSheet.create({
    row: {
        flexDirection: 'row',
        alignItems: 'flex-end',
    },
    text: {
        fontSize: 16,
        lineHeight: 20,
        flexShrink: 1,
    },
});

export default TextBubbleBody;
