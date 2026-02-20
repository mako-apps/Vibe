

export const getDisplayableFingerprint = async (key: CryptoKey): Promise<string> => {
    try {
        const jwk = await crypto.subtle.exportKey('jwk', key);
        const n = jwk.n || '';
        const fp = n.substring(0, 16);
        return `${fp.substring(0, 4)}-${fp.substring(4, 8)}-${fp.substring(8, 12)}-${fp.substring(12, 16)}`;
    } catch {
        return 'UNKNOWN';
    }
};

export const generateKeyPair = async (): Promise<CryptoKeyPair> => {
    return await crypto.subtle.generateKey(
        { name: 'RSA-OAEP', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
        true,
        ['encrypt', 'decrypt']
    );
};

// Start: Safe Base64 Helpers
const toBase64 = (buffer: ArrayBuffer): string => {
    const bytes = new Uint8Array(buffer);
    let binary = '';
    for (let i = 0; i < bytes.byteLength; i++) {
        binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
};

const fromBase64 = (base64: string): Uint8Array => {
    // Robust cleanup: remove whitespace, handle URL-safe chars
    const clean = base64.replace(/\s/g, '').replace(/-/g, '+').replace(/_/g, '/');
    const binary = atob(clean);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
};
// End: Safe Base64 Helpers

// --- KEY DERIVATION & ACCOUNT RECOVERY ---

export const deriveKeyFromPassphrase = async (passphrase: string, salt: string): Promise<CryptoKey> => {
    const enc = new TextEncoder();
    const keyMaterial = await crypto.subtle.importKey(
        "raw",
        enc.encode(passphrase),
        { name: "PBKDF2" },
        false,
        ["deriveKey"]
    );
    return crypto.subtle.deriveKey(
        {
            name: "PBKDF2",
            salt: enc.encode(salt),
            iterations: 600000,  // SECURITY: OWASP 2023 recommends 600,000+ iterations
            hash: "SHA-256"
        },
        keyMaterial,
        { name: "AES-GCM", length: 256 },
        true,
        ["encrypt", "decrypt"]
    );
};

export const encryptPrivateKey = async (privateKey: CryptoKey, key: CryptoKey): Promise<string> => {
    // 1. Export private key to PKCS8
    const keyData = await crypto.subtle.exportKey("pkcs8", privateKey);
    // 2. Encrypt with derived key
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const encrypted = await crypto.subtle.encrypt(
        { name: "AES-GCM", iv },
        key,
        keyData
    );
    // 3. Return IV + Ciphertext
    const combined = new Uint8Array(iv.length + encrypted.byteLength);
    combined.set(iv);
    combined.set(new Uint8Array(encrypted), iv.length);
    return toBase64(combined.buffer);
};

export const decryptPrivateKey = async (encryptedBase64: string, key: CryptoKey): Promise<CryptoKey> => {
    try {
        const combined = fromBase64(encryptedBase64);
        // Extract IV (12 bytes)
        const iv = combined.slice(0, 12);
        const data = combined.slice(12);

        const decryptedBuffer = await crypto.subtle.decrypt(
            { name: "AES-GCM", iv },
            key,
            data
        );

        // The decrypted data might be a PEM string (Server/Mobile behavior) or raw binary
        const decryptedStr = new TextDecoder().decode(decryptedBuffer);
        let keyBytes: Uint8Array;
        let isPkcs1 = false;

        if (decryptedStr.includes('-----BEGIN')) {
            console.log("Decrypt Private Key: Detected PEM format");
            isPkcs1 = decryptedStr.includes('RSA PRIVATE KEY');
            const base64Body = decryptedStr
                .replace(/-----BEGIN.*?-----/g, '')
                .replace(/-----END.*?-----/g, '')
                .replace(/\s/g, '');
            // Reuse fromBase64 for consistency
            keyBytes = fromBase64(base64Body);
        } else {
            console.log("Decrypt Private Key: Detected RAW binary");
            keyBytes = new Uint8Array(decryptedBuffer);
        }

        try {
            if (isPkcs1) throw new Error("Detected PKCS#1 PEM, skipping direct PKCS#8 import");

            return await crypto.subtle.importKey(
                "pkcs8",
                keyBytes.buffer as any,
                { name: "RSA-OAEP", hash: "SHA-256" },
                true,
                ["decrypt"]
            );
        } catch (pkcs8Error) {
            console.log("PKCS#8 import failed, trying simple PKCS#1 wrap...");

            // WRAP PKCS#1 -> PKCS#8
            // OID rsaEncryption: 1.2.840.113549.1.1.1
            const algId = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00];
            const keyBody = keyBytes;

            const encodeLen = (len: number): number[] => {
                if (len < 128) return [len];
                const s = len.toString(16);
                const bytes = s.length % 2 === 1 ? '0' + s : s;
                const arr = [];
                for (let i = 0; i < bytes.length; i += 2) arr.push(parseInt(bytes.substr(i, 2), 16));
                return [0x80 | arr.length, ...arr];
            };

            const octetStringHeader = [0x04, ...encodeLen(keyBody.length)];
            const version = [0x02, 0x01, 0x00];

            const totalLen = version.length + algId.length + octetStringHeader.length + keyBody.length;
            const seqHeader = [0x30, ...encodeLen(totalLen)];

            const pkcs8Bytes = new Uint8Array(seqHeader.length + totalLen);
            let offset = 0;

            [seqHeader, version, algId, octetStringHeader].forEach(arr => {
                pkcs8Bytes.set(arr, offset);
                offset += arr.length;
            });
            pkcs8Bytes.set(keyBody, offset);

            return await crypto.subtle.importKey(
                "pkcs8",
                pkcs8Bytes,
                { name: "RSA-OAEP", hash: "SHA-256" },
                true,
                ["decrypt"]
            );
        }
    } catch (e: any) {
        console.error("Decrypt Private Key Failed:", e.name, e.message);
        throw e;
    }
};

// --- END KEY DERIVATION ---

export const exportPublicKey = async (key: CryptoKey): Promise<string> => {
    const exported = await crypto.subtle.exportKey('spki', key);
    return toBase64(exported);
};

export const importPublicKey = async (pem: string): Promise<CryptoKey> => {
    try {
        let clean = pem.replace(/-----BEGIN.*?-----/g, '').replace(/-----END.*?-----/g, '');
        clean = clean.replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
        const binary = fromBase64(clean);
        return await crypto.subtle.importKey(
            'spki', binary, { name: 'RSA-OAEP', hash: 'SHA-256' }, true, ['encrypt']
        );
    } catch (e: any) {
        throw new Error(`Import Public Key Failed: ${e.message}`);
    }
};

export interface HybridPayload {
    v: number; iv: string; c: string; k: string; s?: string;
}

export const encryptMessage = async (recipientPublicKey: CryptoKey, message: string, myPublicKey?: CryptoKey): Promise<string> => {
    try {
        const aesKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const encodedMsg = new TextEncoder().encode(message);
        const encryptedContent = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, aesKey, encodedMsg);

        const rawAesKey = await crypto.subtle.exportKey('raw', aesKey);
        const recipientEncKeyBuffer = await crypto.subtle.encrypt({ name: 'RSA-OAEP' }, recipientPublicKey, rawAesKey);

        let senderEncKeyBuffer;
        if (myPublicKey) {
            senderEncKeyBuffer = await crypto.subtle.encrypt({ name: 'RSA-OAEP' }, myPublicKey, rawAesKey);
        }

        const payload: HybridPayload = {
            v: 1,
            iv: toBase64(iv.buffer),
            c: toBase64(encryptedContent),
            k: toBase64(recipientEncKeyBuffer),
            s: senderEncKeyBuffer ? toBase64(senderEncKeyBuffer) : undefined
        };
        return JSON.stringify(payload);
    } catch (e: any) {
        throw new Error(`Encryption failed: ${e.message}`);
    }
};

export const decryptMessage = async (privateKey: CryptoKey, ciphertext: string, isMyMessage: boolean = false): Promise<string> => {
    try {
        if (!ciphertext) return "";
        const trimmedCiphertext = ciphertext.trim();

        if (!trimmedCiphertext.startsWith('{')) {
            try {
                let clean = trimmedCiphertext.replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
                const data = fromBase64(clean);
                const decrypted = await crypto.subtle.decrypt({ name: 'RSA-OAEP' }, privateKey, data as BufferSource);
                return new TextDecoder().decode(decrypted);
            } catch (e) {
                return "[Decryption Failed]";
            }
        }

        const payload: HybridPayload = JSON.parse(trimmedCiphertext);
        const keysToTry: { id: string, key: string }[] = [];

        if (isMyMessage) {
            if (payload.s) keysToTry.push({ id: 's', key: payload.s });
            if (payload.k) keysToTry.push({ id: 'k', key: payload.k });
        } else {
            if (payload.k) keysToTry.push({ id: 'k', key: payload.k });
            if (payload.s) keysToTry.push({ id: 's', key: payload.s });
        }

        let rawAesKey: ArrayBuffer | null = null;
        for (const { key } of keysToTry) {
            try {
                const encKeyData = fromBase64(key);
                rawAesKey = await crypto.subtle.decrypt({ name: 'RSA-OAEP' }, privateKey, encKeyData as BufferSource);
                if (rawAesKey) break;
            } catch (e) { }
        }

        if (!rawAesKey) throw new Error("Key mismatch");

        const aesKey = await crypto.subtle.importKey('raw', rawAesKey, { name: 'AES-GCM' }, true, ['decrypt']);
        const iv = fromBase64(payload.iv);
        const contentData = fromBase64(payload.c);

        const decryptedBuffer = await crypto.subtle.decrypt(
            { name: 'AES-GCM', iv: iv as BufferSource },
            aesKey,
            contentData as BufferSource
        );
        return new TextDecoder().decode(decryptedBuffer);

    } catch (e: any) {
        console.warn("Decrypt failed:", e.message);
        return "[Decryption Failed]";
    }
};

export const generateAESKey = async (): Promise<CryptoKey> => crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
export const exportAESKey = async (key: CryptoKey): Promise<string> => toBase64(await crypto.subtle.exportKey('raw', key));
export const importAESKey = async (keyStr: string): Promise<CryptoKey> => {
    let clean = keyStr.replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
    const binary = fromBase64(clean);
    return await crypto.subtle.importKey('raw', binary as BufferSource, { name: 'AES-GCM' }, true, ['encrypt', 'decrypt']);
};

export const encryptFile = async (key: CryptoKey, data: ArrayBuffer): Promise<{ encrypted: ArrayBuffer; iv: Uint8Array }> => {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv as BufferSource }, key, data);
    return { encrypted, iv };
};

export const decryptFile = async (key: CryptoKey, encrypted: ArrayBuffer, iv: Uint8Array): Promise<ArrayBuffer> => {
    return await crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv as BufferSource }, key, encrypted);
};

export const importKeyPair = async (session: { privateKeyJwk?: JsonWebKey, publicKeyJwk?: JsonWebKey }): Promise<CryptoKeyPair> => {
    if (!session.privateKeyJwk || !session.publicKeyJwk) throw new Error("Missing JWK data");
    const privateKey = await crypto.subtle.importKey('jwk', session.privateKeyJwk, { name: 'RSA-OAEP', hash: 'SHA-256' }, true, ['decrypt']);
    const publicKey = await crypto.subtle.importKey('jwk', session.publicKeyJwk, { name: 'RSA-OAEP', hash: 'SHA-256' }, true, ['encrypt']);
    return { privateKey, publicKey };
};
