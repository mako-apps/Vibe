
import * as SecureStore from 'expo-secure-store';
import * as ExpoCrypto from 'expo-crypto';
import { generateKeyPair, importKeyPairFromPem, exportPrivateKeyPem, exportPublicKeyPem, NativeKeyPair } from './crypto';

interface Session {
    userId: string;
    secureId: string;
    keyPair: NativeKeyPair;
    secretKey?: string; // stored for recovery display
    loginToken?: string;
}

class AuthManager {
    private static instance: AuthManager;
    private session: Session | null = null;

    private constructor() { }

    static getInstance() {
        if (!AuthManager.instance) {
            AuthManager.instance = new AuthManager();
        }
        return AuthManager.instance;
    }

    async init(): Promise<Session | null> {
        try {
            const stored = await SecureStore.getItemAsync('user_session_v2');
            if (stored) {
                const data = JSON.parse(stored);
                // Updated: Keys are already PEM strings, no complex import needed
                if (data.privateKeyPem && data.publicKeyPem) {
                    this.session = {
                        userId: data.userId,
                        secureId: data.secureId,
                        keyPair: {
                            publicKey: data.publicKeyPem,
                            privateKey: data.privateKeyPem
                        },
                        secretKey: data.secretKey,
                        loginToken: data.loginToken // Restore the login token for socket auth
                    };
                    return this.session;
                }
            }
        } catch (e) {
            console.error('Session Load Error', e);
        }
        return null;
    }

    async createSession(userId: string, secretKey?: string): Promise<Session> {
        const secureId = "SEC_" + userId.slice(0, 8);

        // Generates { publicKey: string, privateKey: string }
        const keyPair = await generateKeyPair();

        // Already PEM strings
        const privateKeyPem = keyPair.privateKey;
        const publicKeyPem = keyPair.publicKey;

        const sessionData = {
            userId,
            secureId,
            privateKeyPem,
            publicKeyPem,
            secretKey
        };

        // Use a new key to avoid conflicts with old JWK data formats
        await SecureStore.setItemAsync('user_session_v2', JSON.stringify(sessionData));
        this.session = { userId, secureId, keyPair, secretKey };
        return this.session;
    }

    async createAccount(username: string): Promise<Session> {
        // Generate UUID using expo-crypto
        const userId = ExpoCrypto.randomUUID().toUpperCase();
        return this.createSession(userId);
    }

    getSession() {
        return this.session;
    }

    // Directly set session (bypasses SecureStore read, useful after signup)
    setSession(session: Session) {
        this.session = session;
        // console.log('[AuthManager] Session set directly. Token:', session.loginToken?.substring(0, 8) + '...');
    }

    async logout() {
        await SecureStore.deleteItemAsync('user_session_v2');
        this.session = null;
    }
}

export default AuthManager;
