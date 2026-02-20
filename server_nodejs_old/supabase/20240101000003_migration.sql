-- Run this in your Supabase SQL Editor to update your database schema
-- This adds missing columns required for media sending, replies, and advanced encryption.

-- USERS TABLE UPDATES
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_image TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS online BOOLEAN DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS socket_id TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS device_id TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS login_token TEXT;

-- Advanced Encryption
ALTER TABLE users ADD COLUMN IF NOT EXISTS signed_pre_key_id INTEGER;
ALTER TABLE users ADD COLUMN IF NOT EXISTS signed_pre_key TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS signed_pre_key_signature TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS supports_advanced BOOLEAN DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS encrypted_private_key TEXT;

-- CHAT PARTICIPANTS UPDATES
ALTER TABLE chat_participants ADD COLUMN IF NOT EXISTS muted BOOLEAN DEFAULT FALSE;
ALTER TABLE chat_participants ADD COLUMN IF NOT EXISTS pinned BOOLEAN DEFAULT FALSE;

-- MESSAGES TABLE UPDATES (Crucial for sendMedia)
ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_url TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS sender_plaintext TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_id TEXT;
