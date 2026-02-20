import { create } from 'zustand';
import * as Crypto from 'expo-crypto';
import { Socket as PhxSocket, Channel } from 'phoenix';
import ProxyManager from '../ProxyManager';
import AuthManager from '../AuthManager';
import { useAgentStore } from '../agent/AgentStore';
import { AgentMessage } from '../agent/types';

/**
 * Tool execution event from the AI agent
 */
interface ToolEvent {
    tool: string;
    status: 'running' | 'completed' | 'failed';
    label?: string;
    result?: any;
}

interface PendingResponse {
    id: string;
    userMessage: string;
    response: string;
    isStreaming: boolean;
    isComplete: boolean;
    currentTool: ToolEvent | null;
    timestamp: number;
    error?: string;
}

interface TransientAgentState {
    pendingResponse: PendingResponse | null;
    isConnected: boolean;

    // Actions
    startTransientQuery: (message: string) => void;
    clearPending: () => void;
    promoteToPersistent: () => Promise<string | null>;
}

// Module-level channel reference (separate from AgentStore)
let transientChannel: Channel | null = null;
let transientSocket: PhxSocket | null = null;
let streamingTimeoutId: NodeJS.Timeout | null = null;

export const useTransientAgentStore = create<TransientAgentState>()((set, get) => ({
    pendingResponse: null,
    isConnected: false,

    startTransientQuery: (message: string) => {
        const auth = AuthManager.getInstance().getSession();
        if (!auth) {
            console.log('[TransientAgent] No auth session');
            return;
        }

        // Create pending response immediately
        const pendingId = Crypto.randomUUID();
        set({
            pendingResponse: {
                id: pendingId,
                userMessage: message,
                response: '',
                isStreaming: true,
                isComplete: false,
                currentTool: null,
                timestamp: Date.now()
            }
        });

        // Connect if not connected
        if (!transientSocket || !transientSocket.isConnected()) {
            const proxy = ProxyManager.getInstance();
            const baseUrl = proxy.getBestUrl();
            const socketUrl = baseUrl.replace(/^http/, 'ws') + '/socket';

            console.log('[TransientAgent] Connecting to:', socketUrl);

            transientSocket = new PhxSocket(socketUrl, {
                params: { token: auth.loginToken || auth.userId },
                reconnectAfterMs: () => 5000,
            });

            transientSocket.connect();

            transientSocket.onOpen(() => {
                console.log('[TransientAgent] Socket connected');
                set({ isConnected: true });
                joinAndSend(auth.userId, message, set, get);
            });

            transientSocket.onClose(() => {
                console.log('[TransientAgent] Socket disconnected');
                transientChannel = null;
                set({ isConnected: false });
            });

            transientSocket.onError((e) => {
                console.error('[TransientAgent] Socket error:', e);
                set({ isConnected: false });
                const pending = get().pendingResponse;
                if (pending) {
                    set({
                        pendingResponse: {
                            ...pending,
                            isStreaming: false,
                            isComplete: true,
                            error: 'Connection error'
                        }
                    });
                }
            });
        } else {
            // Already connected, join and send
            joinAndSend(auth.userId, message, set, get);
        }
    },

    clearPending: () => {
        // Clear timeout
        if (streamingTimeoutId) {
            clearTimeout(streamingTimeoutId);
            streamingTimeoutId = null;
        }

        set({ pendingResponse: null });

        // Disconnect socket to clean up
        if (transientChannel) {
            transientChannel.leave();
            transientChannel = null;
        }
    },

    promoteToPersistent: async () => {
        const { pendingResponse } = get();
        if (!pendingResponse || !pendingResponse.response) {
            return null;
        }

        // Use AgentStore to create a new conversation with the messages
        const agentStore = useAgentStore.getState();

        // Create a new conversation
        const convId = agentStore.createConversation(pendingResponse.userMessage.substring(0, 30));

        // Wait a tick for the conversation to be created
        await new Promise(resolve => setTimeout(resolve, 100));

        // Get the updated conversations
        const conversations = useAgentStore.getState().conversations;
        const convIndex = conversations.findIndex(c => c.id === convId);

        if (convIndex > -1) {
            // Add the user message and assistant response
            const userMsg: AgentMessage = {
                id: Crypto.randomUUID(),
                role: 'user',
                content: pendingResponse.userMessage,
                timestamp: pendingResponse.timestamp
            };

            const assistantMsg: AgentMessage = {
                id: Crypto.randomUUID(),
                role: 'assistant',
                content: pendingResponse.response,
                timestamp: Date.now(),
                isStreaming: false
            };

            const updatedConvs = [...conversations];
            updatedConvs[convIndex] = {
                ...updatedConvs[convIndex],
                messages: [userMsg, assistantMsg],
                updatedAt: Date.now()
            };

            useAgentStore.setState({ conversations: updatedConvs });
        }

        // Clear the pending response
        get().clearPending();

        return convId;
    }
}));

// Helper function to join channel and send message
function joinAndSend(
    userId: string,
    message: string,
    set: (state: Partial<TransientAgentState>) => void,
    get: () => TransientAgentState
) {
    if (!transientSocket) return;

    // Leave existing channel if any
    if (transientChannel) {
        transientChannel.leave();
    }

    // Join the agent channel
    transientChannel = transientSocket.channel(`agent:${userId}`, {});

    transientChannel.join()
        .receive('ok', () => {
            console.log('[TransientAgent] Joined channel, sending message');

            // Set up event handlers
            setupChannelHandlers(set, get);

            // Send the message with transient flag
            transientChannel!.push('message', {
                text: message,
                images: [],
                transient: true // Tell server not to persist
            })
                .receive('ok', () => console.log('[TransientAgent] Push OK'))
                .receive('error', (reasons: any) => {
                    console.log('[TransientAgent] Push failed', reasons);
                    const pending = get().pendingResponse;
                    if (pending) {
                        set({
                            pendingResponse: {
                                ...pending,
                                isStreaming: false,
                                isComplete: true,
                                error: 'Failed to send message'
                            }
                        });
                    }
                })
                .receive('timeout', () => {
                    console.log('[TransientAgent] Push timeout');
                    const pending = get().pendingResponse;
                    if (pending) {
                        set({
                            pendingResponse: {
                                ...pending,
                                isStreaming: false,
                                isComplete: true,
                                error: 'Request timed out'
                            }
                        });
                    }
                });

            // Set timeout (30 seconds) - only triggers if still streaming
            if (streamingTimeoutId) clearTimeout(streamingTimeoutId);
            streamingTimeoutId = setTimeout(() => {
                const pending = get().pendingResponse;
                // Only timeout if still streaming AND no response received yet
                if (pending && pending.isStreaming && !pending.isComplete && pending.response.length === 0) {
                    console.log('[TransientAgent] Streaming timeout - no response received');
                    set({
                        pendingResponse: {
                            ...pending,
                            isStreaming: false,
                            isComplete: true,
                            error: 'Request timed out'
                        }
                    });
                }
                streamingTimeoutId = null;
            }, 30000);
        })
        .receive('error', (err) => {
            console.error('[TransientAgent] Failed to join channel:', err);
            const pending = get().pendingResponse;
            if (pending) {
                set({
                    pendingResponse: {
                        ...pending,
                        isStreaming: false,
                        isComplete: true,
                        error: 'Failed to connect'
                    }
                });
            }
        });
}

// Set up channel event handlers
function setupChannelHandlers(
    set: (state: Partial<TransientAgentState>) => void,
    get: () => TransientAgentState
) {
    if (!transientChannel) return;

    // Handle streaming chunks
    transientChannel.on('chunk', (payload: { text: string }) => {
        const pending = get().pendingResponse;
        if (pending) {
            set({
                pendingResponse: {
                    ...pending,
                    response: pending.response + payload.text
                }
            });
        }
    });

    // Handle tool progress
    transientChannel.on('progress', (payload: { label: string; tool?: string; status?: string }) => {
        const pending = get().pendingResponse;
        if (pending) {
            set({
                pendingResponse: {
                    ...pending,
                    currentTool: {
                        tool: payload.tool || payload.label.replace('Using ', '').replace('...', ''),
                        status: (payload.status as any) || 'running',
                        label: payload.label
                    }
                }
            });
        }
    });

    // Handle tool results
    transientChannel.on('tool_result', (payload: { tool: string; result: any }) => {
        const pending = get().pendingResponse;
        if (pending) {
            set({
                pendingResponse: {
                    ...pending,
                    currentTool: {
                        tool: payload.tool,
                        status: 'completed',
                        result: payload.result
                    }
                }
            });
        }
    });

    // Handle completion
    transientChannel.on('done', (payload: { success: boolean }) => {
        console.log('[TransientAgent] Stream complete:', payload.success);

        // Clear timeout
        if (streamingTimeoutId) {
            clearTimeout(streamingTimeoutId);
            streamingTimeoutId = null;
        }

        const pending = get().pendingResponse;
        if (pending) {
            set({
                pendingResponse: {
                    ...pending,
                    isStreaming: false,
                    isComplete: true,
                    currentTool: null
                }
            });
        }
    });

    // Handle errors
    transientChannel.on('error', (payload: { message: string }) => {
        console.error('[TransientAgent] Error:', payload.message);

        // Clear timeout
        if (streamingTimeoutId) {
            clearTimeout(streamingTimeoutId);
            streamingTimeoutId = null;
        }

        const pending = get().pendingResponse;
        if (pending) {
            set({
                pendingResponse: {
                    ...pending,
                    isStreaming: false,
                    isComplete: true,
                    error: payload.message
                }
            });
        }
    });
}
