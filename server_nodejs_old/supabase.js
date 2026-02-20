/**
 * Supabase Database Module for Vibe Chat
 * Replace SQLite with Supabase for better reliability and real-time features
 */

const { createClient } = require('@supabase/supabase-js');

// Initialize Supabase client
const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_SERVICE_KEY || process.env.SUPABASE_ANON_KEY;
// Note: Service Key is preferred for backend admin access, but Anon Key works if RLS allows or checks are minimal.

if (!supabaseUrl || !supabaseKey) {
    console.error('[SUPABASE] Missing SUPABASE_URL or SUPABASE_SERVICE_KEY/SUPABASE_ANON_KEY environment variables');
}

const supabase = createClient(supabaseUrl || '', supabaseKey || '', {
    auth: { persistSession: false }
});

class SupabaseDatabase {
    constructor() {
        this.supabase = supabase;
    }

    async initialize() {
        try {
            // Test connection
            const { data, error } = await this.supabase.from('users').select('count').limit(1);
            if (error && error.code !== 'PGRST116') {
                throw error;
            }
            console.log('[SUPABASE] Connected successfully');

            // Get counts
            const userCount = await this.getUserCount();
            const chatCount = await this.getChatCount();
            console.log(`[SUPABASE] Ready - ${userCount} users, ${chatCount} chats`);
        } catch (e) {
            console.error('[SUPABASE] Connection failed:', e.message);
            throw e;
        }
    }

    // ==================== USER OPERATIONS ====================

    async createUser({ id, secureId, publicKey, identityKey, encryptedPrivateKey, username, passwordHash, deviceId, loginToken }) {
        // Store ID as uppercase to match getUserById query format
        const uppercaseId = id.toUpperCase();
        const { error } = await this.supabase.from('users').insert({
            id: uppercaseId,
            secure_id: secureId,
            public_key: publicKey,
            identity_key: identityKey,
            encrypted_private_key: encryptedPrivateKey,
            username: username.toLowerCase(),
            password_hash: passwordHash,
            device_id: deviceId,
            login_token: loginToken
        });
        if (error) throw error;
    }

    async getUserById(id) {
        // Try uppercase first (new format)
        let { data, error } = await this.supabase
            .from('users')
            .select('*')
            .eq('id', id.toUpperCase())
            .single();

        // Fallback: try original case for legacy lowercase IDs
        if (!data && error?.code === 'PGRST116') {
            const fallback = await this.supabase
                .from('users')
                .select('*')
                .eq('id', id)
                .single();
            data = fallback.data;
            error = fallback.error;
        }

        if (error && error.code !== 'PGRST116') throw error;
        return data ? this.mapUserRow(data) : null;
    }

    async getUserByUsername(username) {
        const { data, error } = await this.supabase
            .from('users')
            .select('*')
            .eq('username', username.toLowerCase())
            .single();
        if (error && error.code !== 'PGRST116') throw error;
        return data ? this.mapUserRow(data) : null;
    }

    async getUserByDeviceId(deviceId) {
        const { data, error } = await this.supabase
            .from('users')
            .select('*')
            .eq('device_id', deviceId)
            .single();
        if (error && error.code !== 'PGRST116') throw error;
        return data ? this.mapUserRow(data) : null;
    }

    async getUserBySecureId(secureId) {
        const { data, error } = await this.supabase
            .from('users')
            .select('*')
            .eq('secure_id', secureId)
            .single();
        if (error && error.code !== 'PGRST116') throw error;
        return data ? this.mapUserRow(data) : null;
    }

    async getUserByToken(token) {
        const { data, error } = await this.supabase
            .from('users')
            .select('*')
            .eq('login_token', token)
            .single();
        if (error && error.code !== 'PGRST116') throw error;
        return data ? this.mapUserRow(data) : null;
    }

    async getUserByCredential(cred) {
        // Can be username or secure_id
        const { data, error } = await this.supabase
            .from('users')
            .select('*')
            .or(`username.eq.${cred.toLowerCase()},secure_id.eq.${cred.toUpperCase()}`)
            .single();
        if (error && error.code !== 'PGRST116') throw error;
        return data ? this.mapUserRow(data) : null;
    }

    async updateUser(id, updates) {
        const dbUpdates = {};
        if (updates.publicKey !== undefined) dbUpdates.public_key = updates.publicKey;
        if (updates.identityKey !== undefined) dbUpdates.identity_key = updates.identityKey;
        if (updates.online !== undefined) dbUpdates.online = updates.online;
        if (updates.socketId !== undefined) dbUpdates.socket_id = updates.socketId;
        if (updates.deviceId !== undefined) dbUpdates.device_id = updates.deviceId;
        if (updates.profileImage !== undefined) dbUpdates.profile_image = updates.profileImage;
        if (updates.signedPreKeyId !== undefined) dbUpdates.signed_pre_key_id = updates.signedPreKeyId;
        if (updates.signedPreKey !== undefined) dbUpdates.signed_pre_key = updates.signedPreKey;
        if (updates.signedPreKeySignature !== undefined) dbUpdates.signed_pre_key_signature = updates.signedPreKeySignature;
        if (updates.supportsAdvanced !== undefined) dbUpdates.supports_advanced = updates.supportsAdvanced;
        if (updates.encryptedPrivateKey !== undefined) dbUpdates.encrypted_private_key = updates.encryptedPrivateKey;

        if (Object.keys(dbUpdates).length === 0) return;

        const { error } = await this.supabase
            .from('users')
            .update(dbUpdates)
            .eq('id', id);
        if (error) throw error;
    }

    async deleteUser(id) {
        // Try both uppercase and original case for backwards compatibility
        let user = await this.getUserById(id);

        // If not found with uppercase, try original case (for legacy lowercase IDs)
        if (!user) {
            const { data, error } = await this.supabase
                .from('users')
                .select('*')
                .eq('id', id)
                .single();
            if (!error && data) {
                user = this.mapUserRow(data);
            }
        }

        if (!user) return false;

        // Use the actual ID from the user record to ensure correct deletion
        const { error } = await this.supabase.from('users').delete().eq('id', user.id);
        if (error) throw error;
        return true;
    }

    async usernameExists(username) {
        const { data } = await this.supabase
            .from('users')
            .select('id')
            .eq('username', username.toLowerCase())
            .single();
        return !!data;
    }

    async getUserCount() {
        const { count, error } = await this.supabase
            .from('users')
            .select('*', { count: 'exact', head: true });
        if (error) return 0;
        return count || 0;
    }

    mapUserRow(row) {
        return {
            id: row.id,
            secureId: row.secure_id,
            publicKey: row.public_key,
            identityKey: row.identity_key,
            username: row.username,
            online: row.online,
            socketId: row.socket_id,
            deviceId: row.device_id,
            loginToken: row.login_token,
            password_hash: row.password_hash,
            profileImage: row.profile_image,
            signedPreKeyId: row.signed_pre_key_id,
            signedPreKey: row.signed_pre_key,
            signedPreKeySignature: row.signed_pre_key_signature,
            supportsAdvanced: row.supports_advanced,
            encryptedPrivateKey: row.encrypted_private_key
        };
    }

    // ==================== CHAT OPERATIONS ====================

    async createChat(chatId, participants) {
        // Insert chat
        const { error: chatError } = await this.supabase
            .from('chats')
            .insert({ id: chatId })
            .select();

        if (chatError && chatError.code !== '23505') throw chatError; // Ignore duplicate

        // Insert participants
        const participantRows = participants.map(userId => ({
            chat_id: chatId,
            user_id: userId
        }));

        const { error: partError } = await this.supabase
            .from('chat_participants')
            .upsert(participantRows, { onConflict: 'chat_id,user_id' });

        if (partError) throw partError;
    }

    async getChatById(chatId) {
        const { data: chat, error } = await this.supabase
            .from('chats')
            .select('*')
            .eq('id', chatId)
            .single();

        if (error && error.code !== 'PGRST116') throw error;
        if (!chat) return null;

        const { data: participants } = await this.supabase
            .from('chat_participants')
            .select('user_id')
            .eq('chat_id', chatId);

        return {
            id: chat.id,
            participants: (participants || []).map(p => p.user_id)
        };
    }

    async findChatBetweenUsers(userId1, userId2) {
        const { data, error } = await this.supabase.rpc('get_or_create_chat', {
            p_user1: userId1,
            p_user2: userId2
        });
        // Just check if exists, don't create
        const { data: existing } = await this.supabase
            .from('chat_participants')
            .select('chat_id')
            .eq('user_id', userId1);

        if (!existing) return null;

        for (const row of existing) {
            const { data: other } = await this.supabase
                .from('chat_participants')
                .select('user_id')
                .eq('chat_id', row.chat_id)
                .eq('user_id', userId2)
                .single();
            if (other) return row.chat_id;
        }
        return null;
    }

    async getUserChats(userId) {
        const { data, error } = await this.supabase.rpc('get_user_chats', {
            p_user_id: userId.toUpperCase()
        });

        if (error) {
            console.error('[SUPABASE] getUserChats error:', error);
            return [];
        }

        return (data || []).map(row => ({
            chatId: row.chat_id,
            friendId: row.friend_id,
            friendName: row.friend_name || 'Unknown',
            friendKey: row.friend_key,
            friendIdentityKey: row.friend_identity_key,
            friendImage: row.friend_image,
            muted: row.muted,
            pinned: row.pinned,
            markedUnread: row.marked_unread,
            unreadCount: row.unread_count || 0,
            lastMessage: row.last_message
        }));
    }

    async getChatCount() {
        const { count, error } = await this.supabase
            .from('chats')
            .select('*', { count: 'exact', head: true });
        if (error) return 0;
        return count || 0;
    }

    async deleteChat(chatId) {
        const { error } = await this.supabase.from('chats').delete().eq('id', chatId);
        if (error) throw error;
        return true;
    }

    async setChatMuted(chatId, userId, muted) {
        const { error } = await this.supabase
            .from('chat_participants')
            .update({ muted })
            .eq('chat_id', chatId)
            .eq('user_id', userId);
        if (error) throw error;
    }

    async getChatMuted(chatId, userId) {
        const { data } = await this.supabase
            .from('chat_participants')
            .select('muted')
            .eq('chat_id', chatId)
            .eq('user_id', userId)
            .single();
        return data?.muted || false;
    }

    async setChatPinned(chatId, userId, pinned) {
        const { error } = await this.supabase
            .from('chat_participants')
            .update({ pinned })
            .eq('chat_id', chatId)
            .eq('user_id', userId);
        if (error) throw error;
    }

    async getChatPinned(chatId, userId) {
        const { data } = await this.supabase
            .from('chat_participants')
            .select('pinned')
            .eq('chat_id', chatId)
            .eq('user_id', userId)
            .single();
        return data?.pinned || false;
    }

    async setChatMarkedUnread(chatId, userId, marked) {
        const { error } = await this.supabase
            .from('chat_participants')
            .update({ marked_unread: marked })
            .eq('chat_id', chatId)
            .eq('user_id', userId);
        if (error) throw error;
    }

    async getChatMarkedUnread(chatId, userId) {
        const { data } = await this.supabase
            .from('chat_participants')
            .select('marked_unread')
            .eq('chat_id', chatId)
            .eq('user_id', userId)
            .single();
        return data?.marked_unread || false;
    }

    // ==================== MESSAGE OPERATIONS ====================

    async addMessage({ id, chatId, fromId, encryptedContent, type, mediaUrl, timestamp, senderPlaintext, status, replyToId }) {
        const { error } = await this.supabase.from('messages').insert({
            id,
            chat_id: chatId,
            from_id: fromId,
            encrypted_content: encryptedContent,
            type: type || 'text',
            media_url: mediaUrl,
            timestamp: timestamp || Date.now(),
            status: status || 'sent',
            reply_to_id: replyToId
        });
        if (error) throw error;
    }

    async getChatMessages(chatId) {
        const { data: messages, error } = await this.supabase
            .from('messages')
            .select('*, message_reads(reader_id)')
            .eq('chat_id', chatId)
            .order('timestamp', { ascending: true });

        if (error) throw error;

        return (messages || []).map(row => ({
            id: row.id,
            fromId: row.from_id,
            encryptedContent: row.encrypted_content,
            type: row.type,
            mediaUrl: row.media_url,
            timestamp: row.timestamp,
            status: row.status,
            replyToId: row.reply_to_id,
            readBy: (row.message_reads || []).map(r => r.reader_id)
        }));
    }

    async getLastMessage(chatId) {
        const { data, error } = await this.supabase
            .from('messages')
            .select('*, message_reads(reader_id)')
            .eq('chat_id', chatId)
            .order('timestamp', { ascending: false })
            .limit(1)
            .single();

        if (error && error.code !== 'PGRST116') throw error;
        if (!data) return null;

        return {
            id: data.id,
            fromId: data.from_id,
            encryptedContent: data.encrypted_content,
            type: data.type,
            mediaUrl: data.media_url,
            timestamp: data.timestamp,
            status: data.status,
            replyToId: data.reply_to_id,
            readBy: (data.message_reads || []).map(r => r.reader_id)
        };
    }

    async markMessageRead(messageId, readerId) {
        const { error } = await this.supabase
            .from('message_reads')
            .upsert({ message_id: messageId, reader_id: readerId }, { onConflict: 'message_id,reader_id' });
        return !error;
    }

    async getMessageReaders(messageId) {
        const { data } = await this.supabase
            .from('message_reads')
            .select('reader_id')
            .eq('message_id', messageId);
        return (data || []).map(r => r.reader_id);
    }

    async updateMessage(id, encryptedContent) {
        const { error } = await this.supabase
            .from('messages')
            .update({ encrypted_content: encryptedContent })
            .eq('id', id);
        if (error) throw error;
    }

    async updateMessageStatus(id, status) {
        const { error } = await this.supabase
            .from('messages')
            .update({ status: status })
            .eq('id', id);
        if (error) throw error;
    }

    async deleteMessage(id) {
        const { error } = await this.supabase.from('messages').delete().eq('id', id);
        if (error) throw error;
    }

    async clearChatMessages(chatId) {
        const { error } = await this.supabase.from('messages').delete().eq('chat_id', chatId);
        if (error) throw error;
    }

    // ==================== SUBSCRIPTION OPERATIONS ====================

    async addSubscription(userId, subscription) {
        const { error } = await this.supabase.from('subscriptions').upsert({
            user_id: userId,
            endpoint: subscription.endpoint,
            keys_p256dh: subscription.keys?.p256dh,
            keys_auth: subscription.keys?.auth
        }, { onConflict: 'endpoint' });
        if (error) throw error;
    }

    async getSubscriptions(userId) {
        const { data } = await this.supabase
            .from('subscriptions')
            .select('*')
            .eq('user_id', userId);

        return (data || []).map(row => ({
            endpoint: row.endpoint,
            keys: {
                p256dh: row.keys_p256dh,
                auth: row.keys_auth
            }
        }));
    }

    async removeSubscription(endpoint) {
        const { error } = await this.supabase.from('subscriptions').delete().eq('endpoint', endpoint);
        if (error) throw error;
    }

    // ==================== REAL-TIME ====================

    subscribeToMessages(chatId, callback) {
        return this.supabase
            .channel(`messages:${chatId}`)
            .on('postgres_changes', {
                event: 'INSERT',
                schema: 'public',
                table: 'messages',
                filter: `chat_id=eq.${chatId}`
            }, payload => callback(payload.new))
            .subscribe();
    }

    subscribeToUserChats(userId, callback) {
        return this.supabase
            .channel(`user_chats:${userId}`)
            .on('postgres_changes', {
                event: '*',
                schema: 'public',
                table: 'chat_participants',
                filter: `user_id=eq.${userId}`
            }, payload => callback(payload))
            .subscribe();
    }
}

module.exports = new SupabaseDatabase();
