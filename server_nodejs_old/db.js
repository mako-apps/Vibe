const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const fs = require('fs');

// Use data directory for database (works better with Docker volumes)
const DATA_DIR = path.join(__dirname, 'data');
if (!fs.existsSync(DATA_DIR)) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
}
const DB_PATH = path.join(DATA_DIR, 'securechat.db');

class Database {
    constructor() {
        this.db = null;
    }

    async initialize() {
        return new Promise((resolve, reject) => {
            this.db = new sqlite3.Database(DB_PATH, (err) => {
                if (err) {
                    console.error('[DB] Failed to connect:', err);
                    reject(err);
                    return;
                }
                console.log('[DB] Connected to SQLite database');
                this.createTables().then(resolve).catch(reject);
            });
        });
    }

    async createTables() {
        const queries = [
            `CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                secure_id TEXT UNIQUE NOT NULL,
                public_key TEXT NOT NULL,
                identity_key TEXT,
                username TEXT UNIQUE NOT NULL,
                profile_image TEXT,
                online INTEGER DEFAULT 0,
                socket_id TEXT,
                device_id TEXT,
                login_token TEXT,
                password_hash TEXT,
                created_at INTEGER DEFAULT (strftime('%s', 'now'))
            )`,
            `CREATE TABLE IF NOT EXISTS chats (
                id TEXT PRIMARY KEY,
                created_at INTEGER DEFAULT (strftime('%s', 'now'))
            )`,
            `CREATE TABLE IF NOT EXISTS chat_participants (
                chat_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                muted INTEGER DEFAULT 0,
                PRIMARY KEY (chat_id, user_id),
                FOREIGN KEY (chat_id) REFERENCES chats(id),
                FOREIGN KEY (user_id) REFERENCES users(id)
            )`,
            `CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                chat_id TEXT NOT NULL,
                from_id TEXT NOT NULL,
                encrypted_content TEXT,
                type TEXT DEFAULT 'text',
                media_url TEXT,
                timestamp INTEGER,
                sender_plaintext TEXT,
                status TEXT DEFAULT 'sent',
                FOREIGN KEY (chat_id) REFERENCES chats(id),
                FOREIGN KEY (from_id) REFERENCES users(id)
            )`,
            `CREATE TABLE IF NOT EXISTS message_reads (
                message_id TEXT NOT NULL,
                reader_id TEXT NOT NULL,
                read_at INTEGER DEFAULT (strftime('%s', 'now')),
                PRIMARY KEY (message_id, reader_id),
                FOREIGN KEY (message_id) REFERENCES messages(id),
                FOREIGN KEY (reader_id) REFERENCES users(id)
            )`,
            `CREATE TABLE IF NOT EXISTS subscriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                endpoint TEXT UNIQUE NOT NULL,
                keys_p256dh TEXT,
                keys_auth TEXT,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                FOREIGN KEY (user_id) REFERENCES users(id)
            )`,
            `CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id)`,
            `CREATE INDEX IF NOT EXISTS idx_chat_participants_user ON chat_participants(user_id)`,
            `CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)`,
            `CREATE INDEX IF NOT EXISTS idx_users_device ON users(device_id)`,
            `CREATE INDEX IF NOT EXISTS idx_users_secure_id ON users(secure_id)`,
            `CREATE INDEX IF NOT EXISTS idx_users_token ON users(login_token)`
        ];

        for (const query of queries) {
            await this.run(query);
        }
        // Migration: Add password_hash if missing
        try {
            await this.run("ALTER TABLE users ADD COLUMN password_hash TEXT");
        } catch (e) { /* Column likely exists */ }

        // Migration: Add muted column to chat_participants if missing
        try {
            await this.run("ALTER TABLE chat_participants ADD COLUMN muted INTEGER DEFAULT 0");
        } catch (e) { /* Column likely exists */ }

        // Migration: Add pinned column to chat_participants if missing
        try {
            await this.run("ALTER TABLE chat_participants ADD COLUMN pinned INTEGER DEFAULT 0");
        } catch (e) { /* Column likely exists */ }

        // Migration: Add reply_to_id column to messages if missing
        try {
            await this.run("ALTER TABLE messages ADD COLUMN reply_to_id TEXT");
        } catch (e) { /* Column likely exists */ }

        // Migration: Add profile_image column to users if missing
        try {
            await this.run("ALTER TABLE users ADD COLUMN profile_image TEXT");
        } catch (e) { /* Column likely exists */ }

        // Migration: Add advanced encryption fields
        try {
            await this.run("ALTER TABLE users ADD COLUMN signed_pre_key_id INTEGER");
        } catch (e) { /* Column likely exists */ }

        try {
            await this.run("ALTER TABLE users ADD COLUMN signed_pre_key TEXT");
        } catch (e) { /* Column likely exists */ }

        try {
            await this.run("ALTER TABLE users ADD COLUMN signed_pre_key_signature TEXT");
        } catch (e) { /* Column likely exists */ }

        try {
            await this.run("ALTER TABLE users ADD COLUMN supports_advanced INTEGER DEFAULT 0");
        } catch (e) { /* Column likely exists */ }

        try {
            await this.run("ALTER TABLE users ADD COLUMN encrypted_private_key TEXT");
        } catch (e) { /* Column likely exists */ }

        // Migration: Add media_url to messages if missing (Fixes sendMedia error)
        try {
            await this.run("ALTER TABLE messages ADD COLUMN media_url TEXT");
        } catch (e) { /* Column likely exists */ }

        // Migration: Add sender_plaintext to messages if missing
        try {
            await this.run("ALTER TABLE messages ADD COLUMN sender_plaintext TEXT");
        } catch (e) { /* Column likely exists */ }

        // Migration: Add marked_unread column to chat_participants if missing
        try {
            await this.run("ALTER TABLE chat_participants ADD COLUMN marked_unread INTEGER DEFAULT 0");
        } catch (e) { /* Column likely exists */ }

        console.log('[DB] Tables created/verified');
    }

    // Helper: Run query with promise
    run(sql, params = []) {
        return new Promise((resolve, reject) => {
            this.db.run(sql, params, function (err) {
                if (err) reject(err);
                else resolve({ lastID: this.lastID, changes: this.changes });
            });
        });
    }

    // Helper: Get single row
    get(sql, params = []) {
        return new Promise((resolve, reject) => {
            this.db.get(sql, params, (err, row) => {
                if (err) reject(err);
                else resolve(row);
            });
        });
    }

    // Helper: Get all rows
    all(sql, params = []) {
        return new Promise((resolve, reject) => {
            this.db.all(sql, params, (err, rows) => {
                if (err) reject(err);
                else resolve(rows || []);
            });
        });
    }

    // ==================== USER OPERATIONS ====================

    async createUser({ id, secureId, publicKey, identityKey, encryptedPrivateKey, username, passwordHash, deviceId, loginToken }) {
        await this.run(
            `INSERT INTO users (id, secure_id, public_key, identity_key, encrypted_private_key, username, password_hash, device_id, login_token) 
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            [id, secureId, publicKey, identityKey, encryptedPrivateKey, username, passwordHash, deviceId, loginToken]
        );
    }

    async getUserById(id) {
        const row = await this.get('SELECT * FROM users WHERE id = ?', [id]);
        return row ? this.mapUserRow(row) : null;
    }

    async getUserByUsername(username) {
        const row = await this.get('SELECT * FROM users WHERE username = ?', [username.toLowerCase()]);
        return row ? this.mapUserRow(row) : null;
    }

    async getUserByDeviceId(deviceId) {
        const row = await this.get('SELECT * FROM users WHERE device_id = ?', [deviceId]);
        return row ? this.mapUserRow(row) : null;
    }

    async getUserBySecureId(secureId) {
        const row = await this.get('SELECT * FROM users WHERE secure_id = ?', [secureId]);
        return row ? this.mapUserRow(row) : null;
    }

    async getUserByToken(token) {
        const row = await this.get('SELECT * FROM users WHERE login_token = ?', [token]);
        return row ? this.mapUserRow(row) : null;
    }

    async getUserByCredential(cred) {
        // Can be username or secure_id
        const row = await this.get('SELECT * FROM users WHERE lower(username) = ? OR secure_id = ?', [cred.toLowerCase(), cred.toUpperCase()]);
        return row ? this.mapUserRow(row) : null;
    }

    async updateUser(id, updates) {
        const fields = [];
        const values = [];

        if (updates.publicKey !== undefined) { fields.push('public_key = ?'); values.push(updates.publicKey); }
        if (updates.identityKey !== undefined) { fields.push('identity_key = ?'); values.push(updates.identityKey); }
        if (updates.online !== undefined) { fields.push('online = ?'); values.push(updates.online ? 1 : 0); }
        if (updates.socketId !== undefined) { fields.push('socket_id = ?'); values.push(updates.socketId); }
        if (updates.deviceId !== undefined) { fields.push('device_id = ?'); values.push(updates.deviceId); }
        if (updates.profileImage !== undefined) { fields.push('profile_image = ?'); values.push(updates.profileImage); }
        if (updates.signedPreKeyId !== undefined) { fields.push('signed_pre_key_id = ?'); values.push(updates.signedPreKeyId); }
        if (updates.signedPreKey !== undefined) { fields.push('signed_pre_key = ?'); values.push(updates.signedPreKey); }
        if (updates.signedPreKeySignature !== undefined) { fields.push('signed_pre_key_signature = ?'); values.push(updates.signedPreKeySignature); }
        if (updates.supportsAdvanced !== undefined) { fields.push('supports_advanced = ?'); values.push(updates.supportsAdvanced ? 1 : 0); }
        if (updates.encryptedPrivateKey !== undefined) { fields.push('encrypted_private_key = ?'); values.push(updates.encryptedPrivateKey); }

        if (fields.length === 0) return;

        values.push(id);
        await this.run(`UPDATE users SET ${fields.join(', ')} WHERE id = ?`, values);
    }

    async deleteUser(id) {
        const user = await this.getUserById(id);
        if (!user) return false;

        await this.run('DELETE FROM subscriptions WHERE user_id = ?', [id]);
        await this.run('DELETE FROM message_reads WHERE reader_id = ?', [id]);
        await this.run('DELETE FROM chat_participants WHERE user_id = ?', [id]);
        await this.run('DELETE FROM users WHERE id = ?', [id]);
        return true;
    }

    async usernameExists(username) {
        const row = await this.get('SELECT 1 FROM users WHERE username = ?', [username.toLowerCase()]);
        return !!row;
    }

    async getUserCount() {
        const row = await this.get('SELECT COUNT(*) as count FROM users');
        return row?.count || 0;
    }

    mapUserRow(row) {
        return {
            id: row.id,
            secureId: row.secure_id,
            publicKey: row.public_key,
            identityKey: row.identity_key,
            username: row.username,
            online: !!row.online,
            socketId: row.socket_id,
            deviceId: row.device_id,
            loginToken: row.login_token,
            password_hash: row.password_hash,
            profileImage: row.profile_image,
            signedPreKeyId: row.signed_pre_key_id,
            signedPreKey: row.signed_pre_key,
            signedPreKeySignature: row.signed_pre_key_signature,
            supportsAdvanced: !!row.supports_advanced,
            encryptedPrivateKey: row.encrypted_private_key
        };
    }

    // ==================== CHAT OPERATIONS ====================

    async createChat(chatId, participants) {
        await this.run('INSERT INTO chats (id) VALUES (?)', [chatId]);
        for (const participantId of participants) {
            await this.run(
                'INSERT INTO chat_participants (chat_id, user_id) VALUES (?, ?)',
                [chatId, participantId]
            );
        }
    }

    async getChatById(chatId) {
        const chat = await this.get('SELECT * FROM chats WHERE id = ?', [chatId]);
        if (!chat) return null;

        const participants = await this.all(
            'SELECT user_id FROM chat_participants WHERE chat_id = ?',
            [chatId]
        );

        return {
            id: chat.id,
            participants: participants.map(p => p.user_id)
        };
    }

    async findChatBetweenUsers(userId1, userId2) {
        const row = await this.get(`
            SELECT cp1.chat_id 
            FROM chat_participants cp1
            JOIN chat_participants cp2 ON cp1.chat_id = cp2.chat_id
            WHERE cp1.user_id = ? AND cp2.user_id = ?
        `, [userId1, userId2]);

        return row ? row.chat_id : null;
    }

    async getUserChats(userId) {
        const rows = await this.all(`
            SELECT c.id as chat_id, cp2.user_id as friend_id, u.username as friend_name, u.public_key, u.identity_key as friend_identity_key, u.profile_image, cp1.muted, cp1.pinned, cp1.marked_unread
            FROM chats c
            JOIN chat_participants cp1 ON c.id = cp1.chat_id AND cp1.user_id = ?
            JOIN chat_participants cp2 ON c.id = cp2.chat_id AND cp2.user_id != ?
            LEFT JOIN users u ON cp2.user_id = u.id
        `, [userId, userId]);

        const result = [];
        for (const row of rows) {
            const lastMessage = await this.getLastMessage(row.chat_id);

            // Calculate unread count (messages in this chat, FROM other people, NOT read by me)
            const unreadCountRow = await this.get(`
                SELECT COUNT(*) as count 
                FROM messages m
                LEFT JOIN message_reads mr ON m.id = mr.message_id AND mr.reader_id = ?
                WHERE m.chat_id = ? AND m.from_id != ? AND mr.read_at IS NULL
            `, [userId, row.chat_id, userId]);

            result.push({
                chatId: row.chat_id,
                friendId: row.friend_id,
                friendName: row.friend_name || 'Unknown',
                friendKey: row.public_key,
                friendIdentityKey: row.friend_identity_key,
                friendImage: row.friend_image || null,
                muted: !!row.muted,
                pinned: !!row.pinned,
                markedUnread: !!row.marked_unread,
                unreadCount: unreadCountRow ? unreadCountRow.count : 0,
                lastMessage
            });
        }

        // Server-side sort (optional, but good for initial load)
        result.sort((a, b) => {
            // Pinned chats first
            if (a.pinned && !b.pinned) return -1;
            if (!a.pinned && b.pinned) return 1;

            const tA = a.lastMessage?.timestamp || 0;
            const tB = b.lastMessage?.timestamp || 0;
            return tB - tA;
        });

        return result;
    }

    async getChatCount() {
        const row = await this.get('SELECT COUNT(*) as count FROM chats');
        return row?.count || 0;
    }

    async deleteChat(chatId) {
        // Delete all messages in the chat
        await this.run('DELETE FROM messages WHERE chat_id = ?', [chatId]);
        // Delete message reads
        await this.run('DELETE FROM message_reads WHERE message_id IN (SELECT id FROM messages WHERE chat_id = ?)', [chatId]);
        // Delete participants
        await this.run('DELETE FROM chat_participants WHERE chat_id = ?', [chatId]);
        // Delete chat
        const result = await this.run('DELETE FROM chats WHERE id = ?', [chatId]);
        return result.changes > 0;
    }

    async setChatMuted(chatId, userId, muted) {
        await this.run(
            'UPDATE chat_participants SET muted = ? WHERE chat_id = ? AND user_id = ?',
            [muted ? 1 : 0, chatId, userId]
        );
    }

    async getChatMuted(chatId, userId) {
        const row = await this.get(
            'SELECT muted FROM chat_participants WHERE chat_id = ? AND user_id = ?',
            [chatId, userId]
        );
        return row ? !!row.muted : false;
    }

    async setChatPinned(chatId, userId, pinned) {
        await this.run(
            'UPDATE chat_participants SET pinned = ? WHERE chat_id = ? AND user_id = ?',
            [pinned ? 1 : 0, chatId, userId]
        );
    }

    async getChatPinned(chatId, userId) {
        const row = await this.get(
            'SELECT pinned FROM chat_participants WHERE chat_id = ? AND user_id = ?',
            [chatId, userId]
        );
        return row ? !!row.pinned : false;
    }

    async setChatMarkedUnread(chatId, userId, marked) {
        await this.run(
            'UPDATE chat_participants SET marked_unread = ? WHERE chat_id = ? AND user_id = ?',
            [marked ? 1 : 0, chatId, userId]
        );
    }

    async getChatMarkedUnread(chatId, userId) {
        const row = await this.get(
            'SELECT marked_unread FROM chat_participants WHERE chat_id = ? AND user_id = ?',
            [chatId, userId]
        );
        return row ? !!row.marked_unread : false;
    }

    // ==================== MESSAGE OPERATIONS ====================

    async addMessage({ id, chatId, fromId, encryptedContent, type, mediaUrl, timestamp, senderPlaintext, status, replyToId }) {
        await this.run(
            `INSERT INTO messages (id, chat_id, from_id, encrypted_content, type, media_url, timestamp, sender_plaintext, status, reply_to_id)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            [id, chatId, fromId, encryptedContent, type || 'text', mediaUrl, timestamp, senderPlaintext, status || 'sent', replyToId || null]
        );
    }

    async getChatMessages(chatId) {
        const rows = await this.all(
            `SELECT m.*, GROUP_CONCAT(mr.reader_id) as read_by
             FROM messages m
             LEFT JOIN message_reads mr ON m.id = mr.message_id
             WHERE m.chat_id = ?
             GROUP BY m.id
             ORDER BY m.timestamp ASC`,
            [chatId]
        );

        return rows.map(row => ({
            id: row.id,
            fromId: row.from_id,
            encryptedContent: row.encrypted_content,
            type: row.type,
            mediaUrl: row.media_url,
            timestamp: row.timestamp,
            _senderPlaintext: row.sender_plaintext,
            status: row.status,
            replyToId: row.reply_to_id || null,
            readBy: row.read_by ? row.read_by.split(',') : []
        }));
    }

    async getLastMessage(chatId) {
        const row = await this.get(
            `SELECT m.*, GROUP_CONCAT(mr.reader_id) as read_by
             FROM messages m
             LEFT JOIN message_reads mr ON m.id = mr.message_id
             WHERE m.chat_id = ?
             GROUP BY m.id
             ORDER BY m.timestamp DESC
             LIMIT 1`,
            [chatId]
        );

        if (!row) return null;

        return {
            id: row.id,
            fromId: row.from_id,
            encryptedContent: row.encrypted_content,
            type: row.type,
            mediaUrl: row.media_url,
            timestamp: row.timestamp,
            _senderPlaintext: row.sender_plaintext,
            status: row.status,
            replyToId: row.reply_to_id || null,
            readBy: row.read_by ? row.read_by.split(',') : []
        };
    }

    async markMessageRead(messageId, readerId) {
        try {
            await this.run(
                'INSERT OR IGNORE INTO message_reads (message_id, reader_id) VALUES (?, ?)',
                [messageId, readerId]
            );
            return true;
        } catch (e) {
            return false;
        }
    }

    async getMessageReaders(messageId) {
        const rows = await this.all(
            'SELECT reader_id FROM message_reads WHERE message_id = ?',
            [messageId]
        );
        return rows.map(r => r.reader_id);
    }

    async updateMessage(id, encryptedContent) {
        await this.run(
            'UPDATE messages SET encrypted_content = ? WHERE id = ?',
            [encryptedContent, id]
        );
    }

    async deleteMessage(id) {
        // Also delete reads for this message
        await this.run('DELETE FROM message_reads WHERE message_id = ?', [id]);
        await this.run('DELETE FROM messages WHERE id = ?', [id]);
    }

    async clearChatMessages(chatId) {
        await this.run('DELETE FROM message_reads WHERE message_id IN (SELECT id FROM messages WHERE chat_id = ?)', [chatId]);
        await this.run('DELETE FROM messages WHERE chat_id = ?', [chatId]);
    }

    // ==================== SUBSCRIPTION OPERATIONS ====================

    async addSubscription(userId, subscription) {
        await this.run(
            `INSERT OR REPLACE INTO subscriptions (user_id, endpoint, keys_p256dh, keys_auth)
             VALUES (?, ?, ?, ?)`,
            [userId, subscription.endpoint, subscription.keys?.p256dh, subscription.keys?.auth]
        );
    }

    async getSubscriptions(userId) {
        const rows = await this.all(
            'SELECT * FROM subscriptions WHERE user_id = ?',
            [userId]
        );

        return rows.map(row => ({
            endpoint: row.endpoint,
            keys: {
                p256dh: row.keys_p256dh,
                auth: row.keys_auth
            }
        }));
    }

    async removeSubscription(endpoint) {
        await this.run('DELETE FROM subscriptions WHERE endpoint = ?', [endpoint]);
    }

    // ==================== MIGRATION ====================

    async migrateFromJson(jsonPath) {
        const fs = require('fs');
        if (!fs.existsSync(jsonPath)) {
            console.log('[MIGRATION] No JSON file to migrate');
            return;
        }

        try {
            const data = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
            console.log('[MIGRATION] Starting migration from JSON...');

            // Migrate users
            const users = new Map(data.users || []);
            for (const [id, user] of users) {
                try {
                    await this.createUser({
                        id,
                        publicKey: user.publicKey,
                        identityKey: user.identityKey,
                        username: user.username,
                        deviceId: user.deviceId,
                        loginToken: user.loginToken
                    });
                    console.log(`[MIGRATION] User: ${user.username}`);
                } catch (e) {
                    // User might already exist
                }
            }

            // Migrate chats
            const chats = new Map(data.chats || []);
            for (const [chatId, chat] of chats) {
                try {
                    await this.createChat(chatId, chat.participants);

                    // Migrate messages
                    for (const msg of (chat.messages || [])) {
                        await this.addMessage({
                            id: msg.id,
                            chatId,
                            fromId: msg.fromId,
                            encryptedContent: msg.encryptedContent,
                            type: msg.type,
                            mediaUrl: msg.mediaUrl,
                            timestamp: msg.timestamp,
                            senderPlaintext: msg._senderPlaintext,
                            status: msg.status
                        });

                        // Migrate read receipts
                        for (const readerId of (msg.readBy || [])) {
                            await this.markMessageRead(msg.id, readerId);
                        }
                    }
                    console.log(`[MIGRATION] Chat: ${chatId} (${chat.messages?.length || 0} messages)`);
                } catch (e) {
                    // Chat might already exist
                }
            }

            // Migrate subscriptions
            const subscriptions = new Map(data.subscriptions || []);
            for (const [userId, subs] of subscriptions) {
                for (const sub of subs) {
                    try {
                        await this.addSubscription(userId, sub);
                    } catch (e) {
                        // Subscription might already exist
                    }
                }
            }

            // Rename old file as backup
            const backupPath = jsonPath.replace('.json', '.json.backup');
            fs.renameSync(jsonPath, backupPath);
            console.log(`[MIGRATION] Complete! Old file backed up to: ${backupPath}`);

        } catch (e) {
            console.error('[MIGRATION] Failed:', e);
        }
    }
}

module.exports = new Database();
