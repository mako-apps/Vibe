/**
 * Root-level Agent Screen - AI Assistant
 * This is a full-screen overlay that can be pushed from anywhere in the app
 * Config is handled by backend - just render the chat screen directly
 */

import React, { useEffect } from 'react';
import { View, StyleSheet } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { AgentChatScreen } from '../src/components/agent';
import { useAgentStore } from '../src/lib/agent/AgentStore';
import { useThemeStore } from '../src/lib/stores/theme-store';

export default function AgentScreen() {
    const router = useRouter();
    const { colors } = useThemeStore();
    const { setActiveConversation } = useAgentStore();
    const params = useLocalSearchParams<{ conversationId?: string }>();

    console.log('[AgentScreen] Mounted');

    // Handle conversationId from navigation (e.g., from @vibe toast)
    useEffect(() => {
        if (params.conversationId) {
            console.log('[AgentScreen] Opening conversation from param:', params.conversationId);
            setActiveConversation(params.conversationId);
        }
    }, [params.conversationId]);

    const handleBack = () => {
        router.back();
    };

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <AgentChatScreen onBack={handleBack} />
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
});
