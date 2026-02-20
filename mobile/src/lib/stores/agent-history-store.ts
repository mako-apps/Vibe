import AsyncStorage from '@react-native-async-storage/async-storage';
import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';

export interface AgentMessage {
    id: string;
    role: 'user' | 'assistant';
    content: string;
    timestamp: number;

    // For tool results
    toolResult?: {
        tool: string;
        result: any;
    };

    // For progress indicators
    isLoading?: boolean;
    progressLabel?: string;
}

export interface AgentConversation {
    id: string;
    title: string;
    messages: AgentMessage[];
    createdAt: number;
    updatedAt: number;
}

interface AgentHistoryState {
    // Current active conversation
    currentConversationId: string | null;

    // All conversations
    conversations: Record<string, AgentConversation>;

    // Settings
    settings: {
        maxHistoryPerConversation: number;
        maxConversations: number;
        retainDays: number;
    };

    // Actions
    startNewConversation: () => string;
    addMessage: (message: Omit<AgentMessage, 'id' | 'timestamp'>) => void;
    updateLastMessage: (updates: Partial<AgentMessage>) => void;
    getCurrentConversation: () => AgentConversation | null;
    getConversationHistory: (limit?: number) => AgentMessage[];
    getHistoryForAPI: (limit?: number) => { role: string; content: string }[];
    deleteConversation: (id: string) => void;
    clearAllHistory: () => void;
    setCurrentConversation: (id: string) => void;
    getAllConversations: () => AgentConversation[];
}

const generateId = () => `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

export const useAgentHistoryStore = create<AgentHistoryState>()(
    persist(
        (set, get) => ({
            currentConversationId: null,
            conversations: {},
            settings: {
                maxHistoryPerConversation: 50,
                maxConversations: 20,
                retainDays: 30,
            },

            startNewConversation: () => {
                const id = generateId();
                const now = Date.now();

                set((state) => ({
                    currentConversationId: id,
                    conversations: {
                        ...state.conversations,
                        [id]: {
                            id,
                            title: 'New Conversation',
                            messages: [],
                            createdAt: now,
                            updatedAt: now,
                        },
                    },
                }));

                return id;
            },

            addMessage: (message) => {
                const state = get();
                let convId = state.currentConversationId;

                // Auto-create conversation if none exists
                if (!convId) {
                    convId = get().startNewConversation();
                }

                const now = Date.now();
                const newMessage: AgentMessage = {
                    ...message,
                    id: generateId(),
                    timestamp: now,
                };

                set((state) => {
                    const conv = state.conversations[convId!];
                    if (!conv) return state;

                    // Auto-title from first user message
                    let title = conv.title;
                    if (conv.messages.length === 0 && message.role === 'user') {
                        title = message.content.slice(0, 50) + (message.content.length > 50 ? '...' : '');
                    }

                    // Limit messages per conversation
                    const messages = [...conv.messages, newMessage]
                        .slice(-state.settings.maxHistoryPerConversation);

                    return {
                        conversations: {
                            ...state.conversations,
                            [convId!]: {
                                ...conv,
                                title,
                                messages,
                                updatedAt: now,
                            },
                        },
                    };
                });
            },

            updateLastMessage: (updates) => {
                const state = get();
                const convId = state.currentConversationId;
                if (!convId) return;

                set((state) => {
                    const conv = state.conversations[convId];
                    if (!conv || conv.messages.length === 0) return state;

                    const messages = [...conv.messages];
                    const lastIndex = messages.length - 1;
                    messages[lastIndex] = { ...messages[lastIndex], ...updates };

                    return {
                        conversations: {
                            ...state.conversations,
                            [convId]: {
                                ...conv,
                                messages,
                                updatedAt: Date.now(),
                            },
                        },
                    };
                });
            },

            getCurrentConversation: () => {
                const state = get();
                if (!state.currentConversationId) return null;
                return state.conversations[state.currentConversationId] || null;
            },

            getConversationHistory: (limit = 20) => {
                const conv = get().getCurrentConversation();
                if (!conv) return [];
                return conv.messages.slice(-limit);
            },

            // Format history for API calls (Claude format)
            getHistoryForAPI: (limit = 10) => {
                const messages = get().getConversationHistory(limit);
                return messages
                    .filter(m => !m.isLoading && m.content)
                    .map(m => ({
                        role: m.role,
                        content: m.content,
                    }));
            },

            deleteConversation: (id) => {
                set((state) => {
                    const { [id]: _, ...remaining } = state.conversations;
                    return {
                        conversations: remaining,
                        currentConversationId:
                            state.currentConversationId === id ? null : state.currentConversationId,
                    };
                });
            },

            clearAllHistory: () => {
                set({ conversations: {}, currentConversationId: null });
            },

            setCurrentConversation: (id) => {
                if (get().conversations[id]) {
                    set({ currentConversationId: id });
                }
            },

            getAllConversations: () => {
                const state = get();
                return Object.values(state.conversations)
                    .sort((a, b) => b.updatedAt - a.updatedAt);
            },
        }),
        {
            name: 'vibe-agent-history',
            storage: createJSONStorage(() => AsyncStorage),
            partialize: (state) => ({
                conversations: state.conversations,
                currentConversationId: state.currentConversationId,
                settings: state.settings,
            }),
        }
    )
);

// Utility: Clean up old conversations
export const cleanupOldConversations = () => {
    const state = useAgentHistoryStore.getState();
    const cutoff = Date.now() - (state.settings.retainDays * 24 * 60 * 60 * 1000);

    Object.values(state.conversations).forEach(conv => {
        if (conv.updatedAt < cutoff) {
            state.deleteConversation(conv.id);
        }
    });
};
