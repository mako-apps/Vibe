/**
 * AgentMessage - Renders a single message in the agent chat
 * Supports streaming text animation
 */

import React, { useEffect, useState } from 'react';
import { View, Text, StyleSheet, ActivityIndicator } from 'react-native';
import Animated, { FadeInUp, FadeIn } from 'react-native-reanimated';
import { Bot, User, Sparkles } from 'lucide-react-native';
import { AgentMessage as AgentMessageType, AIProvider } from '../../lib/agent/types';
import { theme } from '../../lib/theme';

interface AgentMessageProps {
    message: AgentMessageType;
    isStreaming?: boolean;
    streamingContent?: string;
}

export default function AgentMessage({ message, isStreaming, streamingContent }: AgentMessageProps) {
    const isUser = message.role === 'user';
    const isAssistant = message.role === 'assistant';

    // Display content: use streaming content if streaming, otherwise message content
    const displayContent = isStreaming && streamingContent ? streamingContent : message.content;

    return (
        <Animated.View
            entering={FadeInUp.duration(300).springify()}
            style={[
                styles.container,
                isUser ? styles.userContainer : styles.assistantContainer
            ]}
        >
            {/* Avatar */}
            <View style={[styles.avatar, isUser ? styles.userAvatar : styles.assistantAvatar]}>
                {isUser ? (
                    <User size={18} color={theme.colors.background} />
                ) : (
                    <Bot size={18} color={theme.colors.background} />
                )}
            </View>

            {/* Message bubble */}
            <View style={[styles.bubble, isUser ? styles.userBubble : styles.assistantBubble]}>
                {/* Provider badge for assistant */}
                {isAssistant && message.provider && (
                    <View style={styles.providerBadge}>
                        <Sparkles size={10} color={theme.colors.primary} />
                        <Text style={styles.providerText}>
                            {message.provider === 'claude' ? 'Claude' : 'Gemini'}
                        </Text>
                    </View>
                )}

                {/* Message content */}
                <Text style={[styles.content, isUser ? styles.userContent : styles.assistantContent]}>
                    {displayContent}
                </Text>

                {/* Streaming indicator */}
                {isStreaming && (
                    <View style={styles.streamingIndicator}>
                        <ActivityIndicator size="small" color={theme.colors.primary} />
                    </View>
                )}

                {/* Metadata */}
                {!isStreaming && isAssistant && message.latencyMs && (
                    <Text style={styles.metadata}>
                        {(message.latencyMs / 1000).toFixed(1)}s
                        {message.tokens && ` · ${message.tokens.output} tokens`}
                    </Text>
                )}
            </View>
        </Animated.View>
    );
}

const styles = StyleSheet.create({
    container: {
        flexDirection: 'row',
        marginVertical: 8,
        paddingHorizontal: 16,
    },
    userContainer: {
        justifyContent: 'flex-end',
    },
    assistantContainer: {
        justifyContent: 'flex-start',
    },
    avatar: {
        width: 32,
        height: 32,
        borderRadius: 16,
        justifyContent: 'center',
        alignItems: 'center',
        marginHorizontal: 8,
    },
    userAvatar: {
        backgroundColor: theme.colors.primary,
    },
    assistantAvatar: {
        backgroundColor: theme.colors.bg.secondary || '#6366f1',
    },
    bubble: {
        maxWidth: '75%',
        borderRadius: 20,
        paddingHorizontal: 16,
        paddingVertical: 12,
    },
    userBubble: {
        backgroundColor: theme.colors.primary,
        borderBottomRightRadius: 4,
    },
    assistantBubble: {
        backgroundColor: theme.colors.bg.card || 'rgba(255,255,255,0.1)',
        borderBottomLeftRadius: 4,
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.1)',
    },
    providerBadge: {
        flexDirection: 'row',
        alignItems: 'center',
        marginBottom: 6,
        gap: 4,
    },
    providerText: {
        fontSize: 10,
        color: theme.colors.primary,
        fontWeight: '600',
        textTransform: 'uppercase',
        letterSpacing: 0.5,
    },
    content: {
        fontSize: 15,
        lineHeight: 22,
    },
    userContent: {
        color: '#fff',
    },
    assistantContent: {
        color: theme.colors.text,
    },
    streamingIndicator: {
        marginTop: 8,
        alignItems: 'flex-start',
    },
    metadata: {
        fontSize: 10,
        color: theme.colors.textSecondary || 'rgba(255,255,255,0.5)',
        marginTop: 8,
    },
});
