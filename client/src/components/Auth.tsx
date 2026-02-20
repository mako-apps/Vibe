import React, { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { User, Key, Loader2 } from 'lucide-react';
import {
    deriveKeyFromPassphrase, decryptPrivateKey, importPublicKey
} from '../crypto';
import { getApiUrl } from '../utils';
import { keyStore } from '../localKeyStore';
import './Auth.css';

// Centralize session management
const saveSession = (session: any) => keyStore.saveSession(session);

interface AuthProps {
    onSuccess: (data: { userId: string, username: string, secureId: string, loginToken: string, keys: CryptoKeyPair }) => void;
    setView: (view: any) => void;
}

const Auth: React.FC<AuthProps> = ({ onSuccess }) => {
    const [username, setUsername] = useState('');
    const [secretKey, setSecretKey] = useState(''); // For login
    const [error, setError] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [formType, setFormType] = useState<'login' | 'register'>('register');

    // Helper: Generate a high-entropy secret key (Hex format for robustness)
    const generateSecretKey = () => {
        const array = new Uint8Array(32); // 32 bytes = 256 bits
        crypto.getRandomValues(array);
        const hex = Array.from(array).map(b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
        // Format as blocks of 4 for readability
        const chunks = [];
        for (let i = 0; i < hex.length; i += 4) {
            chunks.push(hex.slice(i, i + 4));
        }
        return chunks.join('-');
    };

    const handleRegister = async () => {
        if (!username.trim()) return;
        setIsLoading(true);
        setError('');

        try {
            console.log('[Auth] Starting registration (Server-side Crypto)...');

            // 1. Generate Secret Key (Keep dashes to match Mobile)
            const rawSecret = generateSecretKey();
            // Mobile uses the raw secret with dashes for both password and key derivation
            console.log('[Auth] Generated secret key');

            // 2. Register on server (Server generates keys)
            const apiUrl = getApiUrl();
            console.log(`[Auth] calling register API at: ${apiUrl}/api/register`);

            const res = await fetch(`${apiUrl}/api/register`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
                body: JSON.stringify({
                    username,
                    password: rawSecret, // Send raw secret (dashed)
                    deviceId: crypto.randomUUID(),
                    identityKey: 'v1'
                })
            });

            const data = await res.json();
            console.log('[Auth] Server response:', res.status, data.userId);
            if (!res.ok) throw new Error(data.error || 'Registration failed');

            // 3. Decrypt the server-provided Private Key
            console.log('[Auth] Decrypting server-provided keys...');
            // Derive key using the same dashed secret
            const decryptionKey = await deriveKeyFromPassphrase(rawSecret, username.toLowerCase().trim());
            const privateKey = await decryptPrivateKey(data.encryptedPrivateKey, decryptionKey);

            // 4. Import the Public Key
            // Mobile uses exportPublicKeyPem (SPKI base64). Web crypto.subtle needs to import it.
            // 4. Import the Public Key
            // Mobile uses exportPublicKeyPem (SPKI base64). Web crypto.subtle needs to import it.
            const publicKey = await importPublicKey(data.publicKey);

            // 5. Save locally
            try {
                const privJwk = await crypto.subtle.exportKey('jwk', privateKey);
                const pubJwk = await crypto.subtle.exportKey('jwk', publicKey);

                await saveSession({
                    userId: data.userId, username: data.username,
                    secureId: data.secureId, loginToken: data.token || data.loginToken,
                    privateKeyJwk: privJwk, publicKeyJwk: pubJwk,
                    secretKey: rawSecret
                });
                console.log('[Auth] Session saved successfully');
            } catch (saveError) {
                console.warn('[Auth] Session save failed:', saveError);
            }

            // 6. Success
            console.log('[Auth] Registration complete');
            onSuccess({
                userId: data.userId, username: data.username, secureId: data.secureId,
                loginToken: data.token || data.loginToken, keys: { privateKey, publicKey }
            });

        } catch (e: any) {
            console.error('[Auth] Registration error:', e);
            setError(e.message || 'Registration failed');
        } finally {
            setIsLoading(false);
        }
    };

    const handleLogin = async () => {
        if (!secretKey.trim()) return;
        setIsLoading(true);
        setError('');

        try {
            // Sanitize input: uppercase, keep dashes, remove spaces/invalid chars
            // Allow 0-9, A-F, and -
            const cleanSecret = secretKey.trim().toUpperCase().replace(/[^A-F0-9-]/g, '');
            console.log('[Auth] Attempting login with credential length:', cleanSecret.length);

            const res = await fetch(`${getApiUrl()}/api/login`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
                body: JSON.stringify({
                    credential: cleanSecret,
                    password: cleanSecret,
                    deviceId: crypto.randomUUID()
                })
            });

            const data = await res.json();
            if (!res.ok) throw new Error(data.error || 'Login failed');
            if (!data.encryptedPrivateKey) throw new Error('Account does not support key sync. Please reset.');

            // 2. Derive Key & Decrypt
            const decryptionKey = await deriveKeyFromPassphrase(cleanSecret, data.username.toLowerCase());
            const privateKey = await decryptPrivateKey(data.encryptedPrivateKey, decryptionKey);

            // 3. Import Public Key
            let pubKeyStr = data.publicKey;
            if (!pubKeyStr) {
                try {
                    const userRes = await fetch(`${getApiUrl()}/api/user/${data.userId}`);
                    if (userRes.ok) {
                        const userData = await userRes.json();
                        pubKeyStr = userData.publicKey;
                    }
                } catch (e) { console.warn('Failed fallback key fetch', e); }
            }

            if (!pubKeyStr) throw new Error('Could not retrieve public encryption key.');

            const publicKey = await importPublicKey(pubKeyStr);

            const privJwk = await crypto.subtle.exportKey('jwk', privateKey);
            const pubJwk = await crypto.subtle.exportKey('jwk', publicKey);

            await saveSession({
                userId: data.userId, username: data.username,
                secureId: data.secureId, loginToken: data.token || data.loginToken,
                privateKeyJwk: privJwk, publicKeyJwk: pubJwk,
                secretKey: cleanSecret
            });

            onSuccess({
                userId: data.userId, username: data.username, secureId: data.secureId,
                loginToken: data.token || data.loginToken, keys: { privateKey, publicKey }
            });

        } catch (e: any) {
            console.error('[Auth] Login Error:', e);
            setError(e.message || 'Login failed. Check your Secret Key.');
        } finally {
            setIsLoading(false);
        }
    };





    return (
        <div className="auth-container">
            <AnimatePresence mode="wait">
                <motion.div
                    key={formType}
                    initial={{ opacity: 0, x: formType === 'register' ? 20 : -20 }}
                    animate={{ opacity: 1, x: 0 }}
                    exit={{ opacity: 0, x: formType === 'register' ? -20 : 20 }}
                    transition={{ duration: 0.2 }}
                    className="auth-content-wrapper" // Changed class to avoid card styling if needed
                >
                    {formType === 'register' ? (
                        <>
                            <div className="auth-header">
                                <h1 className="auth-title">Create Account</h1>
                                <p className="auth-subtitle">Choose a username. We'll generate a secure key for you.</p>
                            </div>

                            <form onSubmit={(e) => { e.preventDefault(); handleRegister(); }} className="auth-form">
                                <div className="input-group">
                                    <label>Username</label>
                                    <div className="liquid-input-container">
                                        <User size={20} className="input-icon" />
                                        <input
                                            type="text"
                                            placeholder="Choose a username"
                                            value={username}
                                            onChange={e => setUsername(e.target.value)}
                                            disabled={isLoading}
                                        />
                                    </div>
                                </div>

                                <button className="liquid-button primary" disabled={isLoading || !username}>
                                    {isLoading ? <Loader2 className="spinner" /> : 'Sign Up'}
                                </button>
                            </form>

                            <div className="switch-auth-container">
                                <span>Already have an account? </span>
                                <button className="switch-link" onClick={() => setFormType('login')}>
                                    Sign In
                                </button>
                            </div>
                        </>
                    ) : (
                        <>
                            <div className="auth-header">
                                <h1 className="auth-title">Welcome Back</h1>
                                <p className="auth-subtitle">Enter your Secret Key to sign in</p>
                            </div>

                            <form onSubmit={(e) => { e.preventDefault(); handleLogin(); }} className="auth-form">
                                <div className="input-group">
                                    <label>Secret Key</label>
                                    <div className="liquid-input-container">
                                        <Key size={20} className="input-icon" />
                                        <input
                                            type="password"
                                            value={secretKey}
                                            onChange={e => setSecretKey(e.target.value)}
                                            disabled={isLoading}
                                        />
                                    </div>
                                </div>

                                <button className="liquid-button primary" disabled={isLoading || !secretKey}>
                                    {isLoading ? <Loader2 className="spinner" /> : 'Restore & Sign In'}
                                </button>
                            </form>

                            <div className="switch-auth-container">
                                <span>Don't have an account? </span>
                                <button className="switch-link" onClick={() => setFormType('register')}>
                                    Sign Up
                                </button>
                            </div>
                        </>
                    )}

                    {error && (
                        <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="auth-error">
                            {error}
                        </motion.div>
                    )}
                </motion.div>
            </AnimatePresence>
        </div>
    );
};

export default Auth;
