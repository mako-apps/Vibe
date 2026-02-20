require('dotenv').config();
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const { v4: uuidv4 } = require('uuid');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const webPush = require('web-push');
const crypto = require('crypto');

// Use Supabase if configured, otherwise fall back to SQLite
const useSupabase = process.env.SUPABASE_URL && (process.env.SUPABASE_SERVICE_KEY || process.env.SUPABASE_ANON_KEY);
const db = useSupabase ? require('./supabase') : require('./db');
console.log(`[DB] Using ${useSupabase ? 'Supabase' : 'SQLite'} database`);

const hashPassword = (password) => {
    const salt = crypto.randomBytes(16).toString('hex');
    const hash = crypto.pbkdf2Sync(password, salt, 1000, 64, 'sha512').toString('hex');
    return `${salt}:${hash}`;
};

const verifyPassword = (password, storedHash) => {
    if (!storedHash) return false;
    const [salt, hash] = storedHash.split(':');
    const verifyHash = crypto.pbkdf2Sync(password, salt, 1000, 64, 'sha512').toString('hex');
    return hash === verifyHash;
};

const vapidKeys = {
    publicKey: 'BB0eh6wI6NDRst_62zl95yqYiRZKbn5DNv01ZgsCuD4_ekMovep6POg_tp0r_iHxPK8ReM82BpjmeKS2gvCA1ZY',
    privateKey: 'hS9A2YAVH4RmtmlgvXlB9zZU58xYiHBDWLNEUpa7pBw'
};

webPush.setVapidDetails(
    'mailto:admin@securechat.com',
    vapidKeys.publicKey,
    vapidKeys.privateKey
);

const app = express();
const server = http.createServer(app);

const io = new Server(server, {
    cors: {
        origin: [
            "https://vibe-io-nine.vercel.app",
            "http://localhost:5173",
            "http://localhost:3000",
            true // Keep reflection for other scenarios (ngrok etc)
        ],
        methods: ['GET', 'POST'],
        credentials: true
    },
    maxHttpBufferSize: 50 * 1024 * 1024,
    perMessageDeflate: false,
    httpCompression: false
});

const { ExpressPeerServer } = require('peer');
// Import Agent Orchestrator
const agentOrchestrator = require('./src/agent');

const peerServer = ExpressPeerServer(server, {
    debug: true,
    path: '/peerjs',
    allow_discovery: true,
    proxied: true
});
app.use(peerServer);

// API: Agent Chat
app.post('/api/agent/chat', (req, res) => agentOrchestrator.handleMessage(req, res));


peerServer.on('connection', (client) => {
    console.log(`[PEER] Client connected: ${client.getId()}`);
});

peerServer.on('disconnect', (client) => {
    console.log(`[PEER] Client disconnected: ${client.getId()}`);
});

app.use(cors({
    origin: function (origin, callback) {
        // Allow all origins (for tunnels/p2p)
        callback(null, true);
    },
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'ngrok-skip-browser-warning'],
    credentials: true
}));
// Actually, with origin: '*', credentials must be false. socket.io does its own thing. 
// Just use simple * for API.
// Manual CORS override removed to allow credentialed requests via 'cors' middleware
app.use(express.json({ limit: '50mb' }));

// ========== HEALTH CHECK (For deployment platforms) ==========
let connectionCount = 0;
const serverStartTime = Date.now();

app.get('/api/health', (req, res) => {
    res.json({
        status: 'ok',
        timestamp: new Date().toISOString(),
        uptime: Math.floor((Date.now() - serverStartTime) / 1000),
        connections: connectionCount,
        database: useSupabase ? 'supabase' : 'sqlite',
        version: '1.0.0'
    });
});

// Simple ping for latency testing
app.get('/api/ping', (req, res) => {
    res.json({ pong: Date.now() });
});

// ========== SERVER INFO (For client bootstrap) ==========
app.get('/api/info', (req, res) => {
    res.json({
        name: 'Vibe Server',
        version: '1.0.0',
        features: ['e2ee', 'p2p', 'push', 'media'],
        maxFileSize: 50 * 1024 * 1024,
        regions: ['global']
    });
});

// SECURITY: Strict Input Validation Middleware
app.use((req, res, next) => {
    if (req.body) {
        for (const key in req.body) {
            const val = req.body[key];
            if (typeof val === 'string') {
                // strict limit for basic fields
                if (key === 'username' && val.length > 30) req.body[key] = val.substring(0, 30);
                if (key === 'password' && val.length > 100) req.body[key] = val.substring(0, 100);

                // Remove null bytes (common attack vector)
                if (val.includes('\u0000')) req.body[key] = val.replace(/\u0000/g, '');
            }
        }
    }
    next();
});

// ========== OBFUSCATION LAYER (DPI Bypass) ==========
const generateNoise = (len = 32) => {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let result = '';
    for (let i = 0; i < len; i++) result += chars.charAt(Math.floor(Math.random() * chars.length));
    return result;
};

const obfuscatePayload = (data) => {
    return {
        _t: Date.now(),
        _n: generateNoise(16 + Math.floor(Math.random() * 48)),
        _v: '1.0',
        d: Buffer.from(JSON.stringify(data)).toString('base64')
    };
};

const deobfuscatePayload = (wrapped) => {
    try {
        if (wrapped && wrapped.d) {
            return JSON.parse(Buffer.from(wrapped.d, 'base64').toString('utf8'));
        }
    } catch (e) {
        console.error('[DEOBFUSCATE] Failed:', e);
    }
    return wrapped;
};
// =====================================================

// In-memory cache for online users (socket connections)
const onlineUsers = new Map(); // userId -> { socketId, online: true }

// Uploads directory
const uploadsDir = path.join(__dirname, 'uploads');
if (!fs.existsSync(uploadsDir)) fs.mkdirSync(uploadsDir);

const isSupabase = !!db.supabase;

const storage = isSupabase
    ? multer.memoryStorage()
    : multer.diskStorage({
        destination: (req, file, cb) => cb(null, uploadsDir),
        filename: (req, file, cb) => cb(null, `${uuidv4()}.enc`)
    });

const upload = multer({ storage, limits: { fileSize: 50 * 1024 * 1024 } });

// Serve client
app.use(express.static(path.join(__dirname, '../client/dist')));
app.use('/uploads', express.static(uploadsDir));

// Helper: Generate random username suggestion
const generateUsernameSuggestion = (base) => {
    const suffixes = ['_x', '_pro', '_user', '_one', '_app'];
    return base + suffixes[Math.floor(Math.random() * suffixes.length)];
};

// API: Check username availability
app.get('/api/username/check/:name', async (req, res) => {
    try {
        const name = req.params.name.toLowerCase().trim();

        if (/\d/.test(name)) {
            return res.json({ available: false, error: 'Username cannot contain numbers' });
        }

        if (name.length < 3) {
            return res.json({ available: false, error: 'Username too short (min 3 chars)' });
        }

        const available = !(await db.usernameExists(name));
        let suggestions = [];

        if (!available) {
            const potentialSuggestions = [
                generateUsernameSuggestion(name),
                generateUsernameSuggestion(name),
                generateUsernameSuggestion(name)
            ];
            for (const s of potentialSuggestions) {
                if (!(await db.usernameExists(s))) {
                    suggestions.push(s);
                }
            }
        }

        res.json({ available, suggestions });
    } catch (e) {
        console.error('[API] Username check error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Register User
app.post('/api/register', async (req, res) => {
    try {
        const { username, password, publicKey, encryptedPrivateKey, deviceId, identityKey } = req.body;

        if (!username || !password || !publicKey || !deviceId) {
            return res.status(400).json({ error: 'Missing fields' });
        }

        const cleanUsername = username.toLowerCase().trim();

        if (/\d/.test(cleanUsername)) {
            return res.status(400).json({ error: 'Username cannot contain numbers' });
        }

        // Check if username exists
        if (await db.usernameExists(cleanUsername)) {
            return res.status(409).json({ error: 'Username taken' });
        }

        const id = uuidv4();
        const uppercaseId = id.toUpperCase(); // Ensure uppercase for consistency
        // Use SHA256 of the Secret Key (password) as secureId for deterministic lookup
        const secureId = crypto.createHash('sha256').update(password).digest('hex').toUpperCase();

        const passwordHash = hashPassword(password);
        const loginToken = uuidv4();

        await db.createUser({
            id: uppercaseId,
            secureId,
            publicKey,
            identityKey: identityKey || 'v1',
            encryptedPrivateKey,
            username: cleanUsername,
            passwordHash,
            deviceId,
            loginToken
        });

        console.log(`[REGISTER] New user: ${cleanUsername} (${uppercaseId})`);

        res.json({
            userId: uppercaseId,
            username: cleanUsername,
            secureId,
            loginToken,
            publicKey // Echo back (or could be omitted)
        });
    } catch (e) {
        console.error('[REGISTER] Error:', e);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// LOGIN
app.post('/api/login', async (req, res) => {
    try {
        const { secureId, deviceId, publicKey, loginToken } = req.body; // Legacy args

        let user = null;

        // Auth by Token (Persistent session)
        if (loginToken) {
            user = await db.getUserByToken(loginToken);
        }
        // Auth by Secure ID / Username + Password
        else if (req.body.credential && req.body.password) {
            const cred = req.body.credential.trim();

            // 1. Try generic lookup (username or direct secure_id)
            user = await db.getUserByCredential(cred);

            // 2. If not found, try lookup by Hashed Credential (Login via Secret Key)
            if (!user) {
                const hashedCred = crypto.createHash('sha256').update(cred).digest('hex').toUpperCase();
                user = await db.getUserBySecureId(hashedCred);
            }

            if (user) {
                // Verify password
                if (!verifyPassword(req.body.password, user.password_hash)) {
                    console.log(`[LOGIN FAILED] Bad password for ${user.username}`);
                    return res.status(401).json({ error: 'Invalid Password' });
                }
            }
        }

        if (!user) {
            console.log(`[LOGIN FAILED] Invalid creds`);
            return res.status(404).json({ error: 'Invalid Login Credential or Password' });
        }

        // Verify device matches (security)
        if (user.deviceId !== deviceId) {
            console.log(`[LOGIN WARN] Device changed for ${user.id}. Updating binding.`);
            await db.updateUser(user.id, { deviceId });
        }

        // Update public key / identity key if provided
        const updates = {};
        if (publicKey) updates.publicKey = publicKey;
        if (req.body.identityKey) updates.identityKey = req.body.identityKey;
        if (Object.keys(updates).length > 0) {
            await db.updateUser(user.id, updates);
        }

        console.log(`[LOGIN] ${user.username} -> ${user.id}`);
        res.json({
            userId: user.id,
            secureId: user.secureId,
            username: user.username,
            loginToken: user.loginToken,
            profileImage: user.profileImage,
            encryptedPrivateKey: user.encryptedPrivateKey,
            publicKey: user.publicKey // key fix
        });
    } catch (e) {
        console.error('[API] Login error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Get user public key (by ID)
app.get('/api/user/:id', async (req, res) => {
    try {
        const user = await db.getUserById(req.params.id); // Case sensitive fix
        if (!user) return res.status(404).json({ error: 'User not found' });

        // Respect online privacy - only show online status if user allows it
        const userStatus = onlineUsers.get(user.id);
        const isOnline = userStatus && userStatus.showOnline !== false;
        res.json({
            userId: user.id,
            publicKey: user.publicKey,
            identityKey: user.identityKey,
            username: user.username,
            profileImage: user.profileImage,
            online: isOnline
        });
    } catch (e) {
        console.error('[API] Get user error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Lookup user by username
app.get('/api/user/name/:username', async (req, res) => {
    try {
        const cleanUsername = req.params.username.toLowerCase().trim();
        const user = await db.getUserByUsername(cleanUsername);

        if (!user) return res.status(404).json({ error: 'User not found' });

        // Respect online privacy - only show online status if user allows it
        const userStatus = onlineUsers.get(user.id);
        const isOnline = userStatus && userStatus.showOnline !== false;
        res.json({
            userId: user.id,
            publicKey: user.publicKey,
            identityKey: user.identityKey,
            username: user.username,
            profileImage: user.profileImage,
            online: isOnline
        });
    } catch (e) {
        console.error('[API] Get user by name error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Upload PreKey Bundle (for advanced encryption)
app.post('/api/user/prekey-bundle', async (req, res) => {
    try {
        const { userId, identityKey, signedPreKeyId, signedPreKey, signedPreKeySignature, supportsAdvanced } = req.body;

        if (!userId || !identityKey || !signedPreKeyId || !signedPreKey || !signedPreKeySignature) {
            return res.status(400).json({ error: 'Missing prekey bundle fields' });
        }

        // Store in database
        await db.updateUser(userId, {
            identityKey,
            signedPreKeyId,
            signedPreKey,
            signedPreKeySignature,
            supportsAdvanced: supportsAdvanced !== false
        });

        console.log(`[PREKEY] Updated bundle for ${userId}`);
        res.json({ success: true });
    } catch (e) {
        console.error('[API] PreKey bundle upload error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Get PreKey Bundle (for initiating advanced encryption session)
app.get('/api/user/:id/prekey-bundle', async (req, res) => {
    try {
        const user = await db.getUserById(req.params.id.toUpperCase());
        if (!user) return res.status(404).json({ error: 'User not found' });

        if (!user.supportsAdvanced) {
            return res.status(404).json({ error: 'User does not support advanced encryption' });
        }

        res.json({
            identityKey: user.identityKey,
            signedPreKeyId: user.signedPreKeyId,
            signedPreKey: user.signedPreKey,
            signedPreKeySignature: user.signedPreKeySignature
        });
    } catch (e) {
        console.error('[API] Get prekey bundle error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Check if user supports advanced encryption
app.get('/api/user/:id/supports-advanced', async (req, res) => {
    try {
        const user = await db.getUserById(req.params.id.toUpperCase());
        if (!user) return res.status(404).json({ error: 'User not found' });

        res.json({ supportsAdvanced: !!user.supportsAdvanced });
    } catch (e) {
        console.error('[API] Check advanced support error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Subscribe for Push
app.post('/api/subscribe', async (req, res) => {
    try {
        const { userId, subscription } = req.body;
        if (!userId || !subscription) return res.status(400).json({ error: 'Missing data' });

        await db.addSubscription(userId, subscription);
        console.log(`[PUSH] Subscribed: ${userId}`);
        res.json({ success: true });
    } catch (e) {
        console.error('[API] Subscribe error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// Access VAPID Public Key
app.get('/api/vapid-key', (req, res) => {
    res.json({ key: vapidKeys.publicKey });
});

// Server Discovery Endpoint - Returns current active server URLs
// This helps clients discover working servers when URLs change
app.get('/api/servers', (req, res) => {
    try {
        // Read the dynamic servers list
        const serversPath = path.join(__dirname, 'servers.json');
        let servers = [];

        if (fs.existsSync(serversPath)) {
            servers = JSON.parse(fs.readFileSync(serversPath, 'utf8'));
        }

        // Add "self" as the current server
        const selfUrl = req.get('host') ? `${req.protocol}://${req.get('host')}` : null;
        if (selfUrl && !servers.some(s => s.url === selfUrl)) {
            servers.unshift({
                url: selfUrl,
                name: 'Current Server',
                type: 'primary',
                addedAt: Date.now()
            });
        }

        res.json({
            version: 1,
            servers: servers,
            emergency: {
                enabled: false,
                p2pOnly: false,
                message: ''
            }
        });
    } catch (e) {
        console.error('[API] Servers endpoint error:', e);
        res.json({ version: 1, servers: [] });
    }
});

// Update servers list (called by tunnel script)
app.post('/api/servers/update', express.json(), (req, res) => {
    try {
        const { servers, secret } = req.body;

        // Simple security check (should use proper auth in production)
        const expectedSecret = process.env.SERVER_UPDATE_SECRET || 'securechat-update-2024';
        if (secret !== expectedSecret) {
            return res.status(403).json({ error: 'Unauthorized' });
        }

        const serversPath = path.join(__dirname, 'servers.json');
        fs.writeFileSync(serversPath, JSON.stringify(servers, null, 2));

        console.log('[SERVERS] Updated server list:', servers.length, 'entries');
        res.json({ success: true });
    } catch (e) {
        console.error('[API] Update servers error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Delete User
app.delete('/api/user/:userId', async (req, res) => {
    try {
        const userId = req.params.userId.toUpperCase();
        const deleted = await db.deleteUser(userId);

        if (!deleted) return res.status(404).json({ error: 'User not found' });

        console.log(`[DELETE] User ${userId} deleted account.`);
        res.json({ success: true });
    } catch (e) {
        console.error('[API] Delete user error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Start/Get Chat
app.post('/api/chat', async (req, res) => {
    try {
        const { myId, friendId } = req.body;

        const me = await db.getUserById(myId);
        const friend = await db.getUserById(friendId);

        if (!me || !friend) {
            return res.status(404).json({ error: 'User not found' });
        }

        // Check if chat already exists
        const existingChatId = await db.findChatBetweenUsers(myId, friendId);
        if (existingChatId) {
            const messages = await db.getChatMessages(existingChatId);
            return res.json({ chatId: existingChatId, messages });
        }

        // Create new chat
        const chatId = uuidv4().slice(0, 12);
        await db.createChat(chatId, [myId, friendId]);

        console.log(`[CHAT] Created ${chatId} between ${myId} and ${friendId}`);
        res.json({ chatId, messages: [] });
    } catch (e) {
        console.error('[API] Create chat error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Get chat messages
app.get('/api/chat/:chatId/messages', async (req, res) => {
    try {
        const chat = await db.getChatById(req.params.chatId);
        if (!chat) return res.status(404).json({ error: 'Chat not found' });

        const messages = await db.getChatMessages(req.params.chatId);
        res.json(messages);
    } catch (e) {
        console.error('[API] Get messages error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Get my chats
app.get('/api/chats/:userId', async (req, res) => {
    try {
        const userId = req.params.userId.toUpperCase();

        // Validate userId format
        if (!userId || userId.length < 4) {
            console.warn('[API] Invalid userId format:', userId);
            return res.status(400).json({ error: 'Invalid user ID format' });
        }

        const chats = await db.getUserChats(userId);

        // Return empty array if no chats (not an error)
        res.json(chats || []);
    } catch (e) {
        console.error('[API] Get chats error for user:', req.params.userId);
        console.error('[API] Error details:', e.message, e.stack);
        res.status(500).json({ error: 'Server error', message: e.message });
    }
});

// API: Delete chat
app.delete('/api/chat/:chatId', async (req, res) => {
    try {
        const chatId = req.params.chatId;
        const { userId } = req.body;

        // Verify user is participant
        const chat = await db.getChatById(chatId);
        if (!chat) return res.status(404).json({ error: 'Chat not found' });

        if (!chat.participants.includes(userId?.toUpperCase())) {
            return res.status(403).json({ error: 'Not authorized' });
        }

        await db.deleteChat(chatId);
        console.log(`[DELETE] Chat ${chatId} deleted by ${userId}`);
        res.json({ success: true });
    } catch (e) {
        console.error('[API] Delete chat error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Clear chat messages (Keep chat, remove history)
app.delete('/api/chat/:chatId/messages', async (req, res) => {
    try {
        const chatId = req.params.chatId;
        const userId = req.body.userId || req.query.userId;

        const chat = await db.getChatById(chatId);
        if (!chat) return res.status(404).json({ error: 'Chat not found' });

        if (!chat.participants.includes(userId?.toUpperCase())) {
            return res.status(403).json({ error: 'Not authorized' });
        }

        await db.clearChatMessages(chatId);
        console.log(`[CLEAR] Chat ${chatId} messages cleared by ${userId}`);
        res.json({ success: true });
    } catch (e) {
        console.error('[API] Clear messages error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Upload encrypted media
app.post('/api/upload', upload.single('file'), async (req, res) => {
    if (!req.file) return res.status(400).json({ error: 'No file' });

    try {
        if (db.supabase) {
            // Supabase Storage
            const fileName = `${uuidv4()}.enc`;
            const { error: uploadError } = await db.supabase
                .storage
                .from('secure-uploads')
                .upload(fileName, req.file.buffer, {
                    contentType: 'application/octet-stream',
                    upsert: false
                });

            if (uploadError) {
                console.error('[UPLOAD] Supabase error:', uploadError);
                return res.status(500).json({ error: 'Upload failed' });
            }

            const { data } = db.supabase
                .storage
                .from('secure-uploads')
                .getPublicUrl(fileName);

            res.json({ fileId: fileName, url: data.publicUrl });
        } else {
            // Local Disk Storage
            res.json({ fileId: req.file.filename, url: `/uploads/${req.file.filename}` });
        }
    } catch (e) {
        console.error('[UPLOAD] Error:', e);
        res.status(500).json({ error: 'Upload error' });
    }
});

// API: Set chat mute status
app.post('/api/chat/:chatId/mute', async (req, res) => {
    try {
        const { chatId } = req.params;
        const { userId, muted } = req.body;

        if (!userId) return res.status(400).json({ error: 'Missing userId' });

        const chat = await db.getChatById(chatId);
        if (!chat) return res.status(404).json({ error: 'Chat not found' });

        if (!chat.participants.includes(userId.toUpperCase())) {
            return res.status(403).json({ error: 'Not authorized' });
        }

        await db.setChatMuted(chatId, userId.toUpperCase(), muted);
        console.log(`[MUTE] ${userId} ${muted ? 'muted' : 'unmuted'} chat ${chatId}`);
        res.json({ success: true, muted: !!muted });
    } catch (e) {
        console.error('[API] Set mute error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Get chat mute status
app.get('/api/chat/:chatId/mute/:userId', async (req, res) => {
    try {
        const { chatId, userId } = req.params;

        const muted = await db.getChatMuted(chatId, userId.toUpperCase());
        res.json({ muted });
    } catch (e) {
        console.error('[API] Get mute error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Set chat pin status
app.post('/api/chat/:chatId/pin', async (req, res) => {
    try {
        const { chatId } = req.params;
        const { userId, pinned } = req.body;

        if (!userId) return res.status(400).json({ error: 'Missing userId' });

        const chat = await db.getChatById(chatId);
        if (!chat) return res.status(404).json({ error: 'Chat not found' });

        if (!chat.participants.includes(userId.toUpperCase())) {
            return res.status(403).json({ error: 'Not authorized' });
        }

        await db.setChatPinned(chatId, userId.toUpperCase(), pinned);
        console.log(`[PIN] ${userId} ${pinned ? 'pinned' : 'unpinned'} chat ${chatId}`);
        res.json({ success: true, pinned: !!pinned });
    } catch (e) {
        console.error('[API] Set pin error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Set chat marked unread status
app.post('/api/chat/:chatId/mark-unread', async (req, res) => {
    try {
        const { chatId } = req.params;
        const { userId, marked } = req.body;

        if (!userId) return res.status(400).json({ error: 'Missing userId' });

        const chat = await db.getChatById(chatId);
        if (!chat) return res.status(404).json({ error: 'Chat not found' });

        if (!chat.participants.includes(userId.toUpperCase())) {
            return res.status(403).json({ error: 'Not authorized' });
        }

        await db.setChatMarkedUnread(chatId, userId.toUpperCase(), marked);
        console.log(`[UNREAD] ${userId} marked chat ${chatId} as ${marked ? 'unread' : 'read'}`);
        res.json({ success: true, marked: !!marked });
    } catch (e) {
        console.error('[API] Set mark unread error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// API: Update Profile
app.post('/api/user/profile', async (req, res) => {
    try {
        const { userId, profileImage } = req.body;
        if (!userId) return res.status(400).json({ error: 'Missing userId' });

        await db.updateUser(userId.toUpperCase(), { profileImage });
        res.json({ success: true, profileImage });
    } catch (e) {
        console.error('[API] Update profile error:', e);
        res.status(500).json({ error: 'Server error' });
    }
});

// Send push notification helper
const sendPushNotification = async (userId, payload) => {
    try {
        const subs = await db.getSubscriptions(userId);
        for (const sub of subs) {
            try {
                await webPush.sendNotification(sub, JSON.stringify(payload));
            } catch (err) {
                if (err.statusCode === 410) {
                    console.log(`[PUSH] Removing expired sub for ${userId}`);
                    await db.removeSubscription(sub.endpoint);
                } else {
                    console.error('[PUSH ERROR]', err);
                }
            }
        }
    } catch (e) {
        console.error('[PUSH] Error:', e);
    }
};

// Socket.io
// Helper for conditional logging (only in development)
const isDev = process.env.NODE_ENV !== 'production';
const devLog = (...args) => isDev && console.log(...args);

io.on('connection', (socket) => {
    connectionCount++;
    devLog(`[SOCKET] Connected: ${socket.id} (total: ${connectionCount})`);

    socket.on('auth', async (userId, options = {}) => {
        const upperId = userId?.toUpperCase?.() || userId;

        // Cleanup previous user on this socket to prevent routing conflicts
        if (socket.userId && socket.userId !== upperId) {
            devLog(`[AUTH] Re-auth on socket ${socket.id}: ${socket.userId} -> ${upperId}`);
            onlineUsers.delete(socket.userId);
            socket.leave(socket.userId);
        }

        const user = await db.getUserById(upperId);
        if (!user) return;

        // Privacy: Only broadcast online status if user allows it
        const showOnline = options.showOnline !== false;

        await db.updateUser(upperId, { online: true, socketId: socket.id });
        onlineUsers.set(upperId, { socketId: socket.id, showOnline });
        socket.userId = upperId;
        socket.showOnline = showOnline; // Store for disconnect
        socket.join(upperId);

        // Join all chat rooms & Presence
        const chats = await db.getUserChats(upperId);

        // 1. Notify friends I am online (only if privacy allows)
        chats.forEach(chat => {
            socket.join(chat.chatId);
            if (showOnline) {
                socket.to(chat.chatId).emit('user-status', { userId: upperId, online: true });
            }
        });

        // 2. Get initial status of my friends (only those who allow it)
        const onlineFriendIds = [];
        for (const chat of chats) {
            const friendStatus = onlineUsers.get(chat.friendId);
            if (friendStatus && friendStatus.showOnline !== false) {
                onlineFriendIds.push(chat.friendId);
            }
        }
        socket.emit('initial-presence', onlineFriendIds);

        devLog(`[AUTH] ${upperId} online (visible: ${showOnline})`);
    });

    socket.on('message', async (wrappedData, callback) => {
        try {
            const data = deobfuscatePayload(wrappedData);
            if (!data) {
                if (typeof callback === 'function') callback({ error: 'Decryption failed' });
                return;
            }

            devLog('[SOCKET] Received message payload:', JSON.stringify(data, null, 2));

            const { chatId, encryptedContent, type, mediaUrl, fromId, plaintext, id, replyToId } = data;
            let chat = await db.getChatById(chatId);

            // Auto-create chat if it doesn't exist (for new conversations)
            if (!chat) {
                // Extract participants from chatId (format: USERID1-USERID2)
                const participants = chatId.split('-');
                if (participants.length === 2 && participants.includes(fromId?.toUpperCase())) {
                    try {
                        await db.createChat(chatId, participants.map(p => p.toUpperCase()));
                        chat = await db.getChatById(chatId);
                        console.log(`[CHAT] Auto-created chat ${chatId} for participants: ${participants.join(', ')}`);

                        // IMPORTANT: Join online participants to this new room immediately
                        // otherwise they won't receive the first message
                        participants.forEach(p => {
                            const upperP = p.toUpperCase();
                            const pUser = onlineUsers.get(upperP);
                            if (pUser && pUser.socketId) {
                                const pSocket = io.sockets.sockets.get(pUser.socketId);
                                if (pSocket) {
                                    pSocket.join(chatId);
                                    console.log(`[SOCKET] Auto-joined ${upperP} to new room ${chatId}`);
                                }
                            }
                        });
                    } catch (createErr) {
                        console.error('[CHAT] Failed to auto-create chat:', createErr);
                    }
                }

                if (!chat) {
                    if (typeof callback === 'function') callback({ error: 'Chat not found' });
                    return;
                }
            }

            const msgId = id || uuidv4();
            const timestamp = Date.now();

            // PRIVACY: Don't store plaintext on server - only encrypted content
            // The sender's plaintext is stored client-side only
            await db.addMessage({
                id: msgId,
                chatId,
                fromId,
                encryptedContent,
                type: type || 'text',
                mediaUrl: mediaUrl || null,
                timestamp,
                senderPlaintext: null, // Never store plaintext on server
                status: 'sent',
                replyToId: replyToId || null
            });

            const msg = {
                id: msgId,
                fromId,
                encryptedContent,
                type: type || 'text',
                mediaUrl: mediaUrl || null,
                timestamp,
                // Note: _senderPlaintext only sent back to sender for their local cache
                // It is NOT stored in database
                _senderPlaintext: plaintext || null,
                status: 'sent',
                replyToId: replyToId || null,
                readBy: []
            };

            const outPayload = obfuscatePayload({ chatId, message: msg });

            // Emit immediately - socket.join() is synchronous so no delay needed
            io.to(chatId).emit('message', outPayload);

            if (typeof callback === 'function') callback({ success: true, id: msgId });

            devLog(`[MSG] ${fromId} -> chat:${chatId} (${type})`);

            // Send Push to Recipient(s) - fire and forget (don't block message delivery)
            const recipientId = chat.participants.find(p => p !== fromId);
            if (recipientId) {
                // Run async without awaiting to not block the message flow
                (async () => {
                    try {
                        const sender = await db.getUserById(fromId);
                        const senderName = sender ? sender.username : 'Someone';
                        sendPushNotification(recipientId, {
                            title: senderName,
                            body: type === 'image' ? 'Sent a photo' : 'Sent a message',
                            tag: `msg-${chatId}`
                        });
                    } catch (e) {
                        // Silently fail - push is best effort
                    }
                })();
            }
        } catch (e) {
            console.error('[SOCKET] Message error:', e);
            if (typeof callback === 'function') callback({ error: `Server error: ${e.message}` });
        }
    });

    socket.on('typing', ({ chatId, userId }) => {
        socket.to(chatId).emit('typing', { chatId, userId });
    });

    socket.on('edit-message', async ({ chatId, messageId, encryptedContent }) => {
        try {
            await db.updateMessage(messageId, encryptedContent);
            io.to(chatId).emit('message-edited', { chatId, messageId, encryptedContent });
        } catch (e) {
            console.error('[SOCKET] Edit message error:', e);
        }
    });

    socket.on('delete-message', async ({ chatId, messageId }) => {
        try {
            await db.deleteMessage(messageId);
            io.to(chatId).emit('message-deleted', { chatId, messageId });
        } catch (e) {
            console.error('[SOCKET] Delete message error:', e);
        }
    });

    socket.on('stop-typing', ({ chatId, userId }) => {
        socket.to(chatId).emit('stop-typing', { chatId, userId });
    });

    // Heartbeat ping/pong with strict auth check
    socket.on('ping', () => {
        socket.emit('pong');

        // Critical Fix: If socket is connected but not authenticated (e.g. after server restart),
        // we must tell the client to re-authenticate. Passing 'pong' represents network is alive,
        // but 'auth-required' ensures application logic is restored.
        if (!socket.userId || !onlineUsers.has(socket.userId)) {
            socket.emit('auth-required');
        }
    });

    socket.on('read-receipt', async ({ chatId, messageId, readerId }) => {
        try {
            await db.markMessageRead(messageId, readerId);
            io.to(chatId).emit('message-read', { chatId, messageId, readerId });
            // Also update status to read for backward compatibility
            await db.updateMessageStatus(messageId, 'read');
        } catch (e) {
            console.error('[SOCKET] Read receipt error:', e);
        }
    });

    socket.on('delivery-receipt', async ({ chatId, messageId, deliveredToId }) => {
        try {
            await db.updateMessageStatus(messageId, 'delivered');
            io.to(chatId).emit('message-delivered', { chatId, messageId, deliveredToId });
        } catch (e) {
            console.error('[SOCKET] Delivery receipt error:', e);
        }
    });

    // WebRTC Signaling
    socket.on('call-offer', async (data) => {
        const { toUserId, offer, fromUserId } = data;
        const upperTo = toUserId?.toUpperCase?.() || toUserId;
        const onlineTarget = onlineUsers.get(upperTo);

        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('call-offer', { offer, fromUserId });
            console.log(`[CALL] Offer from ${fromUserId} to ${toUserId}`);
        }

        // Send Push
        try {
            const caller = await db.getUserById(fromUserId);
            const callerName = caller ? caller.username : 'Someone';
            sendPushNotification(upperTo, {
                title: 'Incoming Call',
                body: `${callerName} is calling you...`,
                tag: 'secure-chat-call', // Ensure calls replace each other or group
                renotify: true
            });
        } catch (e) { console.error("Call Push Error", e); }
    });

    socket.on('call-answer', async (data) => {
        const { toUserId, answer } = data;
        const onlineTarget = onlineUsers.get(toUserId?.toUpperCase?.() || toUserId);
        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('call-answer', { answer });
        }
    });

    socket.on('ice-candidate', async (data) => {
        const { toUserId, candidate } = data;
        const onlineTarget = onlineUsers.get(toUserId?.toUpperCase?.() || toUserId);
        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('ice-candidate', { candidate });
        }
    });

    socket.on('call-end', async (data) => {
        const { toUserId } = data;
        const onlineTarget = onlineUsers.get(toUserId?.toUpperCase?.() || toUserId);
        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('call-end');
        }
    });

    // Direct Call Signaling (Bypassing P2P Signaling if needed)
    socket.on('call-start', async (data) => {
        const { toUserId, isVideo } = data;
        const upperTo = toUserId?.toUpperCase?.() || toUserId;
        const onlineTarget = onlineUsers.get(upperTo);

        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('call-start', {
                fromUserId: socket.userId,
                isVideo: isVideo
            });
            devLog(`[CALL] Start signal from ${socket.userId} to ${toUserId}`);
        } else {
            devLog(`[CALL] Target ${upperTo} offline. Sending PUSH...`);

            // Send Push Notification to wake them up
            try {
                const caller = await db.getUserById(socket.userId);
                const callerName = caller ? caller.username : 'Someone';

                await sendPushNotification(upperTo, {
                    title: 'Incoming Call',
                    body: `${callerName} is calling you...`,
                    tag: 'secure-chat-call',
                    renotify: true,
                    data: {
                        type: 'call',
                        fromId: socket.userId,
                        isVideo: isVideo,
                        timestamp: Date.now()
                    }
                });

                // Tell the caller we are ringing (via push)
                socket.emit('call-status', { status: 'ringing_push', message: 'User offline, ringing...' });
            } catch (e) {
                console.error(`[CALL] Failed to send push to ${upperTo}`, e);
                // Only error if we really can't reach them
                socket.emit('call-error', { message: 'User unreachable' });
            }
        }
    });

    socket.on('call-accepted', (data) => {
        const { toUserId } = data;
        const upperTo = toUserId?.toUpperCase?.() || toUserId;
        const onlineTarget = onlineUsers.get(upperTo);

        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('call-accepted', {
                fromUserId: socket.userId
            });
            devLog(`[CALL] Accepted signal from ${socket.userId} to ${toUserId}`);
        }
    });

    // Join Call Request - someone wants to join an ongoing call
    socket.on('call-join-request', async (data) => {
        const { toUserId, fromUserId, fromName, fromImage, isVideo } = data;
        const upperTo = toUserId?.toUpperCase?.() || toUserId;
        const onlineTarget = onlineUsers.get(upperTo);

        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('call-join-request', {
                fromId: fromUserId,
                fromName: fromName || 'Someone',
                fromImage,
                isVideo: isVideo || false
            });
            devLog(`[CALL] Join request from ${fromUserId} to ${toUserId}`);
        }
    });

    // Accept Join Request - allow someone to join the call
    socket.on('call-join-accept', async (data) => {
        const { toUserId, fromUserId } = data;
        const upperTo = toUserId?.toUpperCase?.() || toUserId;
        const onlineTarget = onlineUsers.get(upperTo);

        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('call-join-accepted', {
                fromId: fromUserId
            });
            devLog(`[CALL] Join accepted: ${toUserId} can join ${fromUserId}'s call`);
        }
    });

    // Reject Join Request
    socket.on('call-join-reject', async (data) => {
        const { toUserId, fromUserId } = data;
        const upperTo = toUserId?.toUpperCase?.() || toUserId;
        const onlineTarget = onlineUsers.get(upperTo);

        if (onlineTarget?.socketId) {
            io.to(onlineTarget.socketId).emit('call-join-rejected', {
                fromId: fromUserId
            });
            devLog(`[CALL] Join rejected: ${toUserId} denied by ${fromUserId}`);
        }
    });

    // Call Stream Relay (Fallback for P2P)
    socket.on('voice-stream', (data) => {
        // data: { to: userId, chunk: ArrayBuffer/Blob }
        // console.log(`[Stream] Relaying ${data.chunk ? data.chunk.byteLength : 0} bytes from ${socket.userId} to ${data.to}`);
        const targetUser = onlineUsers.get(data.to?.toUpperCase?.() || data.to);
        if (targetUser?.socketId) {
            io.to(targetUser.socketId).emit('voice-stream', { from: socket.userId, chunk: data.chunk });
        }
    });

    socket.on('disconnect', async () => {
        connectionCount = Math.max(0, connectionCount - 1);
        devLog(`[SOCKET] Disconnected: ${socket.id} (total: ${connectionCount})`);

        if (socket.userId) {
            const currentUser = onlineUsers.get(socket.userId);
            // ONLY remove if the disconnecting socket is the one currently registered
            // This prevents a race condition where a new socket connects (updating the map)
            // before the old one disconnects, which would otherwise wipe the new session.
            if (currentUser && currentUser.socketId === socket.id) {
                await db.updateUser(socket.userId, { online: false, socketId: null });
                onlineUsers.delete(socket.userId);

                // Notify friends I'm offline (only if user allowed online status)
                if (socket.showOnline !== false) {
                    try {
                        const chats = await db.getUserChats(socket.userId);
                        chats.forEach(c => {
                            socket.to(c.chatId).emit('user-status', { userId: socket.userId, online: false });
                        });
                    } catch (e) { /* Silently fail */ }
                }

                devLog(`[OFFLINE] ${socket.userId}`);
            } else {
                devLog(`[SOCKET] Stale disconnect ignored for ${socket.userId}`);
            }
        }
    });
});

// Fallback to client
app.get(/.*/, (req, res) => {
    res.sendFile(path.join(__dirname, '../client/dist/index.html'));
});



// Initialize database and start server
const PORT = process.env.PORT || 3000;

async function start() {
    try {
        await db.initialize();

        // Migrate from JSON if exists and supported
        const jsonPath = path.join(__dirname, 'db.json');
        if (typeof db.migrateFromJson === 'function') {
            await db.migrateFromJson(jsonPath);
        }

        const userCount = await db.getUserCount();
        const chatCount = await db.getChatCount();
        console.log(`[DB] Ready - ${userCount} users, ${chatCount} chats`);

        server.listen(PORT, () => console.log(`Server running on port ${PORT}`));
    } catch (e) {
        console.error('[FATAL] Failed to start server:', e);
        process.exit(1);
    }
}

// Global Error Handlers to prevent crash
process.on('uncaughtException', (err) => {
    console.error('[FATAL] Uncaught Exception:', err);
    // Do not exit, keep running
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('[FATAL] Unhandled Rejection at:', promise, 'reason:', reason);
});

start();
