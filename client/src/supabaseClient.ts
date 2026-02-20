/**
 * Supabase Client for Vibe Chat
 * Handles real-time subscriptions and direct database access
 */

import { createClient, RealtimeChannel } from '@supabase/supabase-js';

// These should be set via environment variables in production
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL || '';
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY || '';

// Only create client if credentials are available
export const supabase = supabaseUrl && supabaseAnonKey
    ? createClient(supabaseUrl, supabaseAnonKey)
    : null;

export const isSupabaseEnabled = !!supabase;

// Types
export interface RealtimeMessage {
    id: string;
    chat_id: string;
    from_id: string;
    encrypted_content: string;
    type: string;
    media_url?: string;
    timestamp: number;
    status: string;
    reply_to_id?: string;
}

// Real-time subscription manager
class SupabaseRealtime {
    private channels: Map<string, RealtimeChannel> = new Map();

    // Subscribe to new messages in a chat
    subscribeToChat(chatId: string, onMessage: (msg: RealtimeMessage) => void): () => void {
        if (!supabase) return () => {};

        const channelName = `chat:${chatId}`;

        // Unsubscribe from existing channel if any
        this.unsubscribeFromChat(chatId);

        const channel = supabase
            .channel(channelName)
            .on(
                'postgres_changes',
                {
                    event: 'INSERT',
                    schema: 'public',
                    table: 'messages',
                    filter: `chat_id=eq.${chatId}`
                },
                (payload) => {
                    const msg = payload.new as RealtimeMessage;
                    onMessage(msg);
                }
            )
            .subscribe();

        this.channels.set(channelName, channel);

        return () => this.unsubscribeFromChat(chatId);
    }

    // Subscribe to user's chat list changes
    subscribeToUserChats(userId: string, onChatUpdate: (payload: any) => void): () => void {
        if (!supabase) return () => {};

        const channelName = `user_chats:${userId}`;

        const channel = supabase
            .channel(channelName)
            .on(
                'postgres_changes',
                {
                    event: '*',
                    schema: 'public',
                    table: 'chat_participants',
                    filter: `user_id=eq.${userId}`
                },
                onChatUpdate
            )
            .subscribe();

        this.channels.set(channelName, channel);

        return () => {
            const ch = this.channels.get(channelName);
            if (ch) {
                supabase?.removeChannel(ch);
                this.channels.delete(channelName);
            }
        };
    }

    // Subscribe to presence (online status)
    subscribeToPresence(onPresenceChange: (users: { id: string; online: boolean }[]) => void): () => void {
        if (!supabase) return () => {};

        const channelName = 'presence';

        const channel = supabase
            .channel(channelName)
            .on(
                'postgres_changes',
                {
                    event: 'UPDATE',
                    schema: 'public',
                    table: 'users',
                    filter: 'online=eq.true'
                },
                (payload) => {
                    onPresenceChange([{ id: payload.new.id, online: payload.new.online }]);
                }
            )
            .subscribe();

        this.channels.set(channelName, channel);

        return () => {
            const ch = this.channels.get(channelName);
            if (ch) {
                supabase?.removeChannel(ch);
                this.channels.delete(channelName);
            }
        };
    }

    unsubscribeFromChat(chatId: string) {
        const channelName = `chat:${chatId}`;
        const channel = this.channels.get(channelName);
        if (channel && supabase) {
            supabase.removeChannel(channel);
            this.channels.delete(channelName);
        }
    }

    unsubscribeAll() {
        if (!supabase) return;
        this.channels.forEach((channel) => {
            supabase.removeChannel(channel);
        });
        this.channels.clear();
    }
}

export const realtimeManager = new SupabaseRealtime();

// Helper functions for direct Supabase queries (optional, as server handles most)
export const supabaseHelpers = {
    async getUserChats(userId: string) {
        if (!supabase) return [];
        const { data, error } = await supabase.rpc('get_user_chats', { p_user_id: userId });
        if (error) {
            console.error('[Supabase] getUserChats error:', error);
            return [];
        }
        return data || [];
    },

    async getChatMessages(chatId: string) {
        if (!supabase) return [];
        const { data, error } = await supabase
            .from('messages')
            .select('*')
            .eq('chat_id', chatId)
            .order('timestamp', { ascending: true });
        if (error) {
            console.error('[Supabase] getChatMessages error:', error);
            return [];
        }
        return data || [];
    },

    async markMessageRead(messageId: string, readerId: string) {
        if (!supabase) return false;
        const { error } = await supabase
            .from('message_reads')
            .upsert({ message_id: messageId, reader_id: readerId }, { onConflict: 'message_id,reader_id' });
        return !error;
    }
};

export default supabase;
