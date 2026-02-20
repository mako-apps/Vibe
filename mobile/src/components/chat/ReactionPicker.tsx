import { ScrollView, View, Text, StyleSheet, Pressable } from 'react-native';
import { Lock } from 'lucide-react-native';
import SafeLiquidGlass from '../native/SafeLiquidGlass';

const REACTIONS = ["⭐", "✍️", "💡", "🗂️", "🔥", "⚡", "🧾", "🫶"];

interface ReactionPickerProps {
    onSelect: (emoji: string) => void;
    isMe?: boolean;
}

export default function ReactionPicker({ onSelect, isMe }: ReactionPickerProps) {
    return (
        <View style={[styles.outerContainer, { alignItems: isMe ? 'flex-end' : 'flex-start' }]}>
            <SafeLiquidGlass
                blurIntensity={80}
                tint="dark"
                style={styles.container}
            >
                <View style={styles.captionWrap}>
                    <Text style={styles.captionText} numberOfLines={2}>
                        Organize your Saved Messages with tags for quicker access.
                    </Text>
                    <Text style={styles.captionLink}>Learn more...</Text>
                </View>
                <ScrollView
                    horizontal
                    showsHorizontalScrollIndicator={false}
                    contentContainerStyle={styles.scrollContent}
                    scrollEnabled={false}
                >
                    {REACTIONS.map((emoji, index) => (
                        <Pressable
                            key={index}
                            onPress={() => onSelect(emoji)}
                            style={({ pressed }) => [
                                styles.emojiBtn,
                                { opacity: pressed ? 0.7 : 1, transform: [{ scale: pressed ? 0.9 : 1 }] }
                            ]}
                        >
                            <Text style={styles.emoji}>{emoji}</Text>
                            <View style={styles.lockBadge}>
                                <Lock size={8} color="#f4ec9a" strokeWidth={2.3} />
                            </View>
                        </Pressable>
                    ))}
                </ScrollView>
            </SafeLiquidGlass>
        </View>
    );
}

const styles = StyleSheet.create({
    outerContainer: {
        width: 370,
    },
    container: {
        borderRadius: 22,
        overflow: 'hidden',
        minHeight: 108,
        paddingHorizontal: 10,
        paddingTop: 10,
        paddingBottom: 8,
        backgroundColor: 'rgba(24,24,26,0.48)',
        borderWidth: 0.5,
        borderColor: 'rgba(255,255,255,0.15)',
    },
    captionWrap: {
        paddingHorizontal: 8,
        marginBottom: 6,
    },
    captionText: {
        color: 'rgba(255,255,255,0.86)',
        fontSize: 12.5,
        lineHeight: 16,
        fontWeight: '500',
    },
    captionLink: {
        marginTop: 2,
        color: '#4d95ff',
        fontSize: 12.5,
        fontWeight: '500',
    },
    scrollContent: {
        alignItems: 'center',
        paddingHorizontal: 4,
    },
    emojiBtn: {
        width: 42,
        height: 42,
        alignItems: 'center',
        justifyContent: 'center',
        marginHorizontal: 2,
        position: 'relative',
    },
    emoji: {
        fontSize: 28,
    },
    lockBadge: {
        position: 'absolute',
        right: 2,
        bottom: 2,
        width: 14,
        height: 14,
        borderRadius: 7,
        backgroundColor: 'rgba(250,238,175,0.95)',
        alignItems: 'center',
        justifyContent: 'center',
    },
});
