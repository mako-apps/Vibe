import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { FileText } from 'lucide-react-native';

import { BubbleMeta } from './BubbleMeta';
import { formatBytes } from './format';
import type { ChatListBubbleMessage } from './types';

import { useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../../lib/stores/theme-store';

const FileBubbleBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const theme = activeTheme[effectiveTheme === 'dark' ? 'dark' : 'light'];
    const textColor = item.isMe ? theme.textColorMe : theme.textColorThem;
    const isLightText = textColor.toLowerCase().includes('#f') || textColor.toLowerCase().includes('white');
    const metaColor = isLightText ? 'rgba(255,255,255,0.68)' : 'rgba(0,0,0,0.45)';
    const cardBg = isLightText ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)';

    const label = item.fileName || item.text || 'File';
    const size = formatBytes(item.fileSize);

    return (
        <View style={styles.wrap}>
            <View style={[styles.card, { backgroundColor: cardBg }]}>
                <View style={[styles.iconWrap, { backgroundColor: isLightText ? 'rgba(255,255,255,0.22)' : 'rgba(0,0,0,0.12)' }]}>
                    <FileText size={17} color={textColor} strokeWidth={2} />
                </View>
                <View style={styles.textWrap}>
                    <Text style={[styles.name, { color: textColor }]} numberOfLines={1}>{label}</Text>
                    {!!size && <Text style={[styles.size, { color: metaColor }]}>{size}</Text>}
                </View>
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
        maxWidth: 248,
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
    textWrap: {
        flex: 1,
    },
    name: {
        fontSize: 13,
        fontWeight: '600',
    },
    size: {
        fontSize: 11,
        marginTop: 2,
    },
    metaRow: {
        marginTop: 4,
        alignItems: 'flex-end',
    },
});

export default FileBubbleBody;
