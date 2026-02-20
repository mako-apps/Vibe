/**
 * VibeNet Protocol — Custom censorship-resistant protocol inspired by MTProto
 *
 * Architecture:
 * 1. TRANSPORT LAYER: Traffic obfuscation (makes data look like HTTPS/WebRTC/random noise)
 * 2. CRYPTO LAYER: AES-256-CTR encryption with per-session keys
 * 3. FRAMING LAYER: Binary message framing with length prefixes
 * 4. APPLICATION LAYER: JSON payloads (HTTP requests, WebSocket frames)
 *
 * Traffic Obfuscation Methods:
 * - TLS Mimicry: Wraps data in TLS-like records so DPI sees "HTTPS traffic"
 * - Padding: Random-length padding to defeat traffic analysis
 * - Timing jitter: Random delays to prevent timing correlation
 */

import forge from 'node-forge';
import { Buffer } from 'buffer';

// ─── Protocol Constants ───────────────────────────────────────────
const PROTOCOL_VERSION = 1;
const MAGIC_BYTES = Buffer.from([0x56, 0x49, 0x42, 0x45]); // "VIBE"
const MAX_FRAME_SIZE = 65535;
const MIN_PADDING = 16;
const MAX_PADDING = 256;

// TLS 1.3 record header mimicry
const TLS_CONTENT_TYPE_APP_DATA = 0x17;
const TLS_VERSION_MAJOR = 0x03;
const TLS_VERSION_MINOR = 0x03; // TLS 1.2 record layer (used by TLS 1.3)

// Message types
export enum MessageType {
    HANDSHAKE = 0x01,
    DATA = 0x02,
    RELAY_REQUEST = 0x03,
    RELAY_RESPONSE = 0x04,
    KEEPALIVE = 0x05,
    CLOSE = 0x06,
    RELAY_ANNOUNCE = 0x07,
    RELAY_DISCOVER = 0x08,
}

export interface SessionKeys {
    encryptKey: Buffer;    // AES-256 key for encryption
    decryptKey: Buffer;    // AES-256 key for decryption
    encryptIV: Buffer;     // CTR mode IV for encryption
    decryptIV: Buffer;     // CTR mode IV for decryption
    sessionId: string;     // Unique session identifier
}

export interface VibeNetFrame {
    type: MessageType;
    payload: Buffer;
    sessionId: string;
    sequence: number;
}

// ─── Crypto Helpers ───────────────────────────────────────────────

// RN's Buffer polyfill has a broken .toString('binary') — manually convert byte-by-byte
const bufToForgeBin = (buf: Buffer): string => {
    let str = '';
    for (let i = 0; i < buf.length; i++) {
        str += String.fromCharCode(buf[i]);
    }
    return str;
};

const forgeBinToBuf = (bin: string): Buffer => {
    const arr = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) {
        arr[i] = bin.charCodeAt(i);
    }
    return Buffer.from(arr);
};

let QuickCrypto: any = null;
try {
    const { default: Constants, ExecutionEnvironment } = require('expo-constants');
    if (Constants.executionEnvironment !== ExecutionEnvironment.StoreClient) {
        QuickCrypto = require('react-native-quick-crypto');
        if (QuickCrypto && QuickCrypto.default) QuickCrypto = QuickCrypto.default;
    }
} catch (e) {
    // Fallback to forge
}

// Use native only for randomBytes (no cross-side consistency needed).
// Deterministic ops (sha256, hmac, aes) must use forge-only to avoid mismatches
// when QuickCrypto partially fails on one side but not the other.
const USE_NATIVE_RANDOM = !!QuickCrypto && !!QuickCrypto.randomBytes;
const USE_NATIVE = false;

const randomBytes = (len: number): Buffer => {
    if (USE_NATIVE_RANDOM) {
        try {
            return Buffer.from(QuickCrypto.randomBytes(len));
        } catch (e) {
            // Fallback to forge
        }
    }
    return forgeBinToBuf(forge.random.getBytesSync(len));
};

const sha256 = (data: Buffer): Buffer => {
    if (USE_NATIVE && QuickCrypto.createHash) {
        try {
            const hash = QuickCrypto.createHash('sha256');
            hash.update(data);
            return Buffer.from(hash.digest());
        } catch (e) {
            // Fallback to forge
        }
    }
    const md = forge.md.sha256.create();
    md.update(bufToForgeBin(data));
    return forgeBinToBuf(md.digest().getBytes());
};

const hmacSha256 = (key: Buffer, data: Buffer): Buffer => {
    if (USE_NATIVE && QuickCrypto.createHmac) {
        try {
            const hmac = QuickCrypto.createHmac('sha256', key);
            hmac.update(data);
            return Buffer.from(hmac.digest());
        } catch (e) {
            // Fallback to forge
        }
    }
    const hmac = forge.hmac.create();
    hmac.start('sha256', bufToForgeBin(key));
    hmac.update(bufToForgeBin(data));
    return forgeBinToBuf(hmac.digest().getBytes());
};

// ─── Key Derivation (HKDF-SHA256) ────────────────────────────────

const hkdfExpand = (prk: Buffer, info: Buffer, length: number): Buffer => {
    const hashLen = 32; // SHA-256
    const n = Math.ceil(length / hashLen);
    let okm = Buffer.alloc(0);
    let prev = Buffer.alloc(0);

    for (let i = 1; i <= n; i++) {
        const input = Buffer.concat([prev, info, Buffer.from([i])]);
        prev = hmacSha256(prk, input) as Buffer;
        okm = Buffer.concat([okm, prev]);
    }

    return okm.subarray(0, length);
};

const hkdfExtract = (salt: Buffer, ikm: Buffer): Buffer => {
    return hmacSha256(salt, ikm);
};

// ─── Session Key Generation ──────────────────────────────────────

/**
 * Derive session keys from a shared secret (from ECDH or pre-shared key)
 */
export const deriveSessionKeys = (sharedSecret: Buffer, isInitiator: boolean): SessionKeys => {
    const salt = sha256(Buffer.from('VibeNet-v1-salt'));
    const prk = hkdfExtract(salt, sharedSecret);

    // Derive 4 keys: initiator-encrypt, initiator-decrypt, responder-encrypt, responder-decrypt
    const keyMaterial = hkdfExpand(prk, Buffer.from('VibeNet-session-keys'), 128);

    const initiatorEncKey = keyMaterial.subarray(0, 32);
    const initiatorEncIV = keyMaterial.subarray(32, 48);
    const responderEncKey = keyMaterial.subarray(48, 80);
    const responderEncIV = keyMaterial.subarray(80, 96);
    const sessionIdBytes = keyMaterial.subarray(96, 128);

    return {
        encryptKey: isInitiator ? initiatorEncKey : responderEncKey,
        decryptKey: isInitiator ? responderEncKey : initiatorEncKey,
        encryptIV: isInitiator ? initiatorEncIV : responderEncIV,
        decryptIV: isInitiator ? responderEncIV : initiatorEncIV,
        sessionId: sessionIdBytes.toString('hex').substring(0, 16),
    };
};

/**
 * Generate a fresh pre-shared key for relay invitation
 */
export const generateRelayKey = (): string => {
    // base64url: replace +/ with -_ and strip trailing =
    return randomBytes(32).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

/**
 * Generate a human-readable invite code from a relay key
 * Format: VIBE-XXXX-XXXX
 */
export const generateInviteCode = (): { code: string; key: string } => {
    const key = generateRelayKey();
    const hash = sha256(Buffer.from(key));
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // No ambiguous chars
    let code = 'VIBE-';
    for (let i = 0; i < 8; i++) {
        if (i === 4) code += '-';
        code += chars[hash[i] % chars.length];
    }
    return { code, key };
};

// ─── Frame Encoding / Decoding ───────────────────────────────────

/**
 * Encode a VibeNet frame into binary
 *
 * Frame format:
 * [1 byte: version] [1 byte: type] [2 bytes: payload length] [16 bytes: session ID]
 * [4 bytes: sequence] [N bytes: payload] [P bytes: random padding] [32 bytes: HMAC]
 */
export const encodeFrame = (frame: VibeNetFrame, keys: SessionKeys): Buffer => {
    const paddingLen = MIN_PADDING + Math.floor(Math.random() * (MAX_PADDING - MIN_PADDING));
    const padding = randomBytes(paddingLen);

    // Build header
    const header = Buffer.alloc(24);
    header[0] = PROTOCOL_VERSION;
    header[1] = frame.type;
    header.writeUInt16BE(frame.payload.length, 2);
    Buffer.from(frame.sessionId.padEnd(16, '0').substring(0, 16)).copy(header, 4);
    header.writeUInt32BE(frame.sequence, 20);

    // Combine header + payload + padding length (1 byte) + padding
    const plaintext = Buffer.concat([
        header,
        frame.payload,
        Buffer.from([paddingLen]),
        padding,
    ]);

    // Encrypt with AES-256-CTR
    const encrypted = aes256CtrEncrypt(plaintext, keys.encryptKey, keys.encryptIV);

    // Calculate HMAC over encrypted data
    const mac = hmacSha256(keys.encryptKey, encrypted);

    return Buffer.concat([encrypted, mac]);
};

/**
 * Decode a VibeNet frame from binary
 */
export const decodeFrame = (data: Buffer, keys: SessionKeys): VibeNetFrame | null => {
    try {
        if (data.length < 56) return null; // Min: 24 header + 1 padding len + 16 min padding + 32 HMAC - but encrypted

        // Split encrypted data and HMAC
        const encrypted = data.subarray(0, data.length - 32);
        const receivedMac = data.subarray(data.length - 32);

        // Verify HMAC
        const expectedMac = hmacSha256(keys.decryptKey, encrypted);
        if (receivedMac.length !== expectedMac.length || !receivedMac.every((b: number, i: number) => b === expectedMac[i])) {
            console.warn('[VibeNet] HMAC verification failed — possible tampering');
            return null;
        }

        // Decrypt
        const plaintext = aes256CtrDecrypt(encrypted, keys.decryptKey, keys.decryptIV);

        // Parse header
        const version = plaintext[0];
        if (version !== PROTOCOL_VERSION) return null;

        const type = plaintext[1] as MessageType;
        const payloadLength = plaintext.readUInt16BE(2);
        const sessionId = plaintext.subarray(4, 20).toString().replace(/\0+$/, '');
        const sequence = plaintext.readUInt32BE(20);

        // Extract payload (skip header, read payloadLength bytes)
        const payload = plaintext.subarray(24, 24 + payloadLength);

        return { type, payload, sessionId, sequence };
    } catch (e) {
        console.error('[VibeNet] Frame decode error:', e);
        return null;
    }
};

// ─── AES-256-CTR ─────────────────────────────────────────────────

const aes256CtrEncrypt = (data: Buffer, key: Buffer, iv: Buffer): Buffer => {
    if (USE_NATIVE && QuickCrypto.createCipheriv) {
        try {
            const cipher = QuickCrypto.createCipheriv('aes-256-ctr', key, iv);
            const updated = Buffer.from(cipher.update(data));
            const final = Buffer.from(cipher.final());
            return Buffer.concat([updated, final]);
        } catch (e) {
            // Fallback to forge on native crypto error
        }
    }
    // Forge fallback
    const keyBin = bufToForgeBin(key);
    const cipher = forge.cipher.createCipher('AES-CTR', keyBin);
    cipher.start({ iv: bufToForgeBin(iv) });
    cipher.update(forge.util.createBuffer(bufToForgeBin(data)));
    cipher.finish();
    return forgeBinToBuf(cipher.output.getBytes());
};

const aes256CtrDecrypt = (data: Buffer, key: Buffer, iv: Buffer): Buffer => {
    if (USE_NATIVE && QuickCrypto.createDecipheriv) {
        try {
            const decipher = QuickCrypto.createDecipheriv('aes-256-ctr', key, iv);
            const updated = Buffer.from(decipher.update(data));
            const final = Buffer.from(decipher.final());
            return Buffer.concat([updated, final]);
        } catch (e) {
            // Fallback to forge on native crypto error
        }
    }
    // Forge fallback
    const keyBin = bufToForgeBin(key);
    const decipher = forge.cipher.createDecipher('AES-CTR', keyBin);
    decipher.start({ iv: bufToForgeBin(iv) });
    decipher.update(forge.util.createBuffer(bufToForgeBin(data)));
    decipher.finish();
    return forgeBinToBuf(decipher.output.getBytes());
};

// ─── TLS Mimicry (Traffic Obfuscation) ───────────────────────────

/**
 * Wrap encrypted data in TLS Application Data records
 * Makes traffic look like normal HTTPS to DPI systems
 */
export const wrapTLS = (data: Buffer): Buffer => {
    const chunks: Buffer[] = [];
    let offset = 0;

    while (offset < data.length) {
        const chunkSize = Math.min(data.length - offset, 16384); // TLS max record: 16KB
        const header = Buffer.alloc(5);
        header[0] = TLS_CONTENT_TYPE_APP_DATA;
        header[1] = TLS_VERSION_MAJOR;
        header[2] = TLS_VERSION_MINOR;
        header.writeUInt16BE(chunkSize, 3);

        chunks.push(header, data.subarray(offset, offset + chunkSize));
        offset += chunkSize;
    }

    return Buffer.concat(chunks);
};

/**
 * Unwrap TLS Application Data records
 */
export const unwrapTLS = (data: Buffer): Buffer | null => {
    try {
        const payloads: Buffer[] = [];
        let offset = 0;

        while (offset < data.length) {
            if (offset + 5 > data.length) break;

            const contentType = data[offset];
            if (contentType !== TLS_CONTENT_TYPE_APP_DATA) return null;

            const recordLength = data.readUInt16BE(offset + 3);
            if (offset + 5 + recordLength > data.length) break;

            payloads.push(data.subarray(offset + 5, offset + 5 + recordLength));
            offset += 5 + recordLength;
        }

        return Buffer.concat(payloads);
    } catch (e) {
        return null;
    }
};

// ─── Application Data Encoding ───────────────────────────────────

/**
 * Encode an HTTP request into a VibeNet frame payload
 */
export const encodeHTTPRequest = (method: string, path: string, headers: Record<string, string>, body?: string): Buffer => {
    const request = {
        m: method,
        p: path,
        h: headers,
        b: body || null,
        t: Date.now(),
    };
    return Buffer.from(JSON.stringify(request), 'utf-8');
};

/**
 * Decode an HTTP request from a VibeNet frame payload
 */
export const decodeHTTPRequest = (payload: Buffer): { method: string; path: string; headers: Record<string, string>; body?: string } | null => {
    try {
        const data = JSON.parse(payload.toString('utf-8'));
        return {
            method: data.m,
            path: data.p,
            headers: data.h || {},
            body: data.b || undefined,
        };
    } catch {
        return null;
    }
};

/**
 * Encode an HTTP response into a VibeNet frame payload
 */
export const encodeHTTPResponse = (status: number, headers: Record<string, string>, body: string): Buffer => {
    const response = {
        s: status,
        h: headers,
        b: body,
        t: Date.now(),
    };
    return Buffer.from(JSON.stringify(response), 'utf-8');
};

/**
 * Decode an HTTP response from a VibeNet frame payload
 */
export const decodeHTTPResponse = (payload: Buffer): { status: number; headers: Record<string, string>; body: string } | null => {
    try {
        const data = JSON.parse(payload.toString('utf-8'));
        return {
            status: data.s,
            headers: data.h || {},
            body: data.b || '',
        };
    } catch {
        return null;
    }
};

/**
 * Encode a WebSocket frame into a VibeNet frame payload
 */
export const encodeWSFrame = (topic: string, event: string, payload: any, ref?: string): Buffer => {
    const wsFrame = { t: topic, e: event, p: payload, r: ref };
    return Buffer.from(JSON.stringify(wsFrame), 'utf-8');
};

/**
 * Decode a WebSocket frame from a VibeNet frame payload
 */
export const decodeWSFrame = (data: Buffer): { topic: string; event: string; payload: any; ref?: string } | null => {
    try {
        const parsed = JSON.parse(data.toString('utf-8'));
        return { topic: parsed.t, event: parsed.e, payload: parsed.p, ref: parsed.r };
    } catch {
        return null;
    }
};
