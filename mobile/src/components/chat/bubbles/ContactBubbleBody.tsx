import React from 'react';
import { Image, StyleSheet, Text, View } from 'react-native';
import { UserRound } from 'lucide-react-native';

import { BubbleMeta } from './BubbleMeta';
import type { ChatListBubbleMessage } from './types';
import { useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../../lib/stores/theme-store';

const ContactBubbleBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const theme = activeTheme[effectiveTheme === 'dark' ? 'dark' : 'light'];
    const textColor = item.isMe ? theme.textColorMe : theme.textColorThem;
    const isLightText = textColor.toLowerCase().includes('#f') || textColor.toLowerCase().includes('white');
    const metaColor = isLightText ? 'rgba(255,255,255,0.68)' : 'rgba(0,0,0,0.45)';
    const cardBg = isLightText ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)';

    const name = item.contact?.username || item.text || 'Contact';
    const phone = item.contact?.phoneNumber || '';

    return (
        <View style={styles.wrap}>
            <View style={[styles.card, { backgroundColor: cardBg }]}>
                {item.contact?.profileImage ? (
                    <Image source={{ uri: item.contact.profileImage }} style={[styles.avatarImage, { backgroundColor: isLightText ? 'rgba(255,255,255,0.22)' : 'rgba(0,0,0,0.1)' }]} resizeMode="cover" />
                ) : (
                    <View style={[styles.avatarFallback, { backgroundColor: isLightText ? 'rgba(255,255,255,0.22)' : 'rgba(0,0,0,0.1)' }]}>
                        <UserRound size={17} color={textColor} strokeWidth={2.4} opacity={0.9} />
                    </View>
                )}

                <View style={styles.textWrap}>
                    <Text style={[styles.name, { color: textColor }]} numberOfLines={1}>{name}</Text>
                    {!!phone && <Text style={[styles.phone, { color: metaColor }]} numberOfLines={1}>{phone}</Text>}
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
    avatarImage: {
        width: 42,
        height: 42,
        borderRadius: 21,
        marginRight: 10,
    },
    avatarFallback: {
        width: 42,
        height: 42,
        borderRadius: 21,
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
    phone: {
        fontSize: 11,
        marginTop: 2,
    },
    metaRow: {
        marginTop: 4,
        alignItems: 'flex-end',
    },
});

export default ContactBubbleBody;
