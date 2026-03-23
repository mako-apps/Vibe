import React, { useEffect } from 'react';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useAgentStore } from '../src/lib/agent/AgentStore';
import { AgentChatScreen, VibeChatMainScreen } from '../src/components/agent';

export default function AgentScreen() {
    const router = useRouter();
    const { setActiveConversation } = useAgentStore();
    const params = useLocalSearchParams<{ conversationId?: string; mode?: string }>();
    const isBuilderMode = params.mode === 'builder';

    // Handle conversationId from navigation (e.g., from @vibe toast)
    useEffect(() => {
        if (!isBuilderMode && params.conversationId) {
            setActiveConversation(params.conversationId);
        }
    }, [isBuilderMode, params.conversationId, setActiveConversation]);

    if (isBuilderMode) {
        return (
            <VibeChatMainScreen
                mode="builder"
                onBack={() => router.back()}
                onOpenBuilder={() => router.replace('/agent?mode=builder')}
                onOpenSettings={() => router.push('/agent-settings')}
            />
        );
    }

    return (
        <AgentChatScreen
            onBack={() => router.back()}
            onSettings={() => router.push('/agent-settings')}
        />
    );
}
