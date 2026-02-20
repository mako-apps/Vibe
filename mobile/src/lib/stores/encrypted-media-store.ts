import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as FileSystem from 'expo-file-system/legacy';
import { decryptFileData } from '../crypto';
import * as Crypto from 'expo-crypto';

interface EncryptedMediaStore {
    // Map remote URL -> Local Decrypted URI
    cache: Record<string, string>;
    // Track in-flight downloads to prevent duplicates
    inFlight: Record<string, Promise<string | null> | undefined>;
    // Track download progress for encrypted media (remote URL -> 0..1)
    downloadProgress: Record<string, number>;

    // Actions
    getDecryptedFile: (url: string, key: string, originalName?: string) => Promise<string | null>;
    manuallyCacheFile: (url: string, localUri: string) => void;
    clearCache: () => Promise<void>;
}

const inferDecryptedExt = (originalName: string | undefined, downloadUrl: string): string => {
    const fallback = 'bin';
    const raw = originalName?.trim();
    const candidate = raw && raw.length > 0 ? raw : (() => {
        try {
            const u = new URL(downloadUrl);
            return u.pathname.split('/').pop() || '';
        } catch {
            return '';
        }
    })();

    if (!candidate) return fallback;
    const safe = candidate.split('?')[0].split('#')[0];
    const withoutEnc = safe.endsWith('.enc') ? safe.slice(0, -4) : safe;
    const ext = withoutEnc.split('.').pop()?.toLowerCase();
    if (!ext || ext.length > 8) return fallback;
    return ext;
};

const normalizeSupabasePublicUrl = (rawUrl: string): string => {
    // Handles legacy/bad URLs like:
    // .../storage/v1/object/public/<bucket>/<bucket>/<path>
    // -> .../storage/v1/object/public/<bucket>/<path>
    try {
        const u = new URL(rawUrl);
        const marker = '/storage/v1/object/public/';
        const idx = u.pathname.indexOf(marker);
        if (idx === -1) return rawUrl;

        const suffix = u.pathname.slice(idx + marker.length);
        const parts = suffix.split('/').filter(Boolean);
        if (parts.length < 2) return rawUrl;

        const bucket = parts[0];
        const rest = parts.slice(1);
        if (rest[0] !== bucket) return rawUrl;

        const fixed = `${marker}${bucket}/${rest.slice(1).join('/')}`;
        u.pathname = u.pathname.slice(0, idx) + fixed;
        return u.toString();
    } catch {
        return rawUrl;
    }
};

export const useEncryptedMediaStore = create<EncryptedMediaStore>()(
    persist(
        (set, get) => ({
            cache: {},
            inFlight: {},
            downloadProgress: {},

            manuallyCacheFile: (url, localUri) => {
                set(s => ({ cache: { ...s.cache, [url]: localUri } }));
            },

            getDecryptedFile: async (url, key, originalName) => {
                const state = get();

                // 1. Check if already cached (fast path - no migration on hot path)
                const cachedUri = state.cache[url];
                if (cachedUri) {
                    // For local file:// URIs (sender's own files), trust the cache
                    if (cachedUri.startsWith('file://') || cachedUri.startsWith('/')) {
                        try {
                            const info = await FileSystem.getInfoAsync(cachedUri);
                            if (info.exists) return cachedUri;
                        } catch { }
                    }
                    // For stable paths in our media dir, trust the cache
                    if (cachedUri.includes('encrypted_media/media_')) {
                        try {
                            const info = await FileSystem.getInfoAsync(cachedUri);
                            if (info.exists) return cachedUri;
                        } catch { }
                    }
                    // Invalid cache entry, remove it
                    const newCache = { ...state.cache };
                    delete newCache[url];
                    set({ cache: newCache });
                }

                // 1.5 Check deterministic on-disk path (survives app restarts even before Zustand rehydrates)
                try {
                    const downloadUrl = normalizeSupabasePublicUrl(url);
                    const ext = inferDecryptedExt(originalName, downloadUrl);

                    const baseDir = FileSystem.documentDirectory || FileSystem.cacheDirectory;
                    if (!baseDir) throw new Error('No file-system base directory available');
                    const mediaDir = `${baseDir}encrypted_media/`;
                    if (!(await FileSystem.getInfoAsync(mediaDir)).exists) {
                        await FileSystem.makeDirectoryAsync(mediaDir, { intermediates: true });
                    }

                    const digest = await Crypto.digestStringAsync(
                        Crypto.CryptoDigestAlgorithm.SHA256,
                        `${downloadUrl}|${key}`
                    );
                    const stablePath = `${mediaDir}media_${digest}.${ext}`;
                    const stableInfo = await FileSystem.getInfoAsync(stablePath);
                    if (stableInfo.exists && (stableInfo as any).size !== 0) {
                        set(s => ({ cache: { ...s.cache, [url]: stablePath } }));
                        return stablePath;
                    }
                } catch {
                    // ignore stable-path failures and continue with normal flow
                }

                // 2. Check if already downloading (deduplication)
                if (state.inFlight[url]) {
                    return state.inFlight[url];
                }

                // 3. Start download & decrypt process
                const downloadPromise = (async () => {
                    try {
                        const downloadUrl = normalizeSupabasePublicUrl(url);
                        set(s => ({ downloadProgress: { ...s.downloadProgress, [url]: 0 } }));

                        // Prepare paths
                        const baseDir = FileSystem.documentDirectory || FileSystem.cacheDirectory;
                        if (!baseDir) throw new Error('No file-system base directory available');
                        const mediaDir = `${baseDir}encrypted_media/`;
                        if (!(await FileSystem.getInfoAsync(mediaDir)).exists) {
                            await FileSystem.makeDirectoryAsync(mediaDir, { intermediates: true });
                        }

                        const ext = inferDecryptedExt(originalName, downloadUrl);
                        const digest = await Crypto.digestStringAsync(
                            Crypto.CryptoDigestAlgorithm.SHA256,
                            `${downloadUrl}|${key}`
                        );

                        const tempEncryptedPath = `${mediaDir}temp_${Crypto.randomUUID()}.enc`;
                        const finalPath = `${mediaDir}media_${digest}.${ext}`;

                        // A. Download Encrypted Blob
                        console.log('[MediaDecrypt] Downloading:', downloadUrl);
                        const resumableFactory = (FileSystem as any).createDownloadResumable;
                        const downloadRes =
                            typeof resumableFactory === 'function'
                                ? await resumableFactory(
                                    downloadUrl,
                                    tempEncryptedPath,
                                    {},
                                    (p: any) => {
                                        const expected = p?.totalBytesExpectedToWrite ?? 0;
                                        const written = p?.totalBytesWritten ?? 0;
                                        const ratio = expected > 0 ? written / expected : 0;
                                        const clamped = Math.max(0, Math.min(1, ratio));
                                        set(s => ({ downloadProgress: { ...s.downloadProgress, [url]: clamped } }));
                                    }
                                ).downloadAsync()
                                : await FileSystem.downloadAsync(downloadUrl, tempEncryptedPath);

                        if ((downloadRes as any)?.status !== 200) {
                            throw new Error(`Download failed with status ${(downloadRes as any)?.status}`);
                        }

                        // B. Read as Base64
                        const encryptedBase64 = await FileSystem.readAsStringAsync(tempEncryptedPath, {
                            encoding: FileSystem.EncodingType.Base64,
                        });

                        // C. Decrypt
                        console.log('[MediaDecrypt] Decrypting...');
                        const decryptedBase64 = await decryptFileData(encryptedBase64, key);

                        // D. Write Decrypted File
                        await FileSystem.writeAsStringAsync(finalPath, decryptedBase64, {
                            encoding: FileSystem.EncodingType.Base64,
                        });

                        // E. Clean up temp
                        await FileSystem.deleteAsync(tempEncryptedPath, { idempotent: true });

                        console.log('[MediaDecrypt] Success:', finalPath);

                        // Update Cache State
                        set(s => {
                            const newCache = { ...s.cache, [url]: finalPath };
                            const newInFlight = { ...s.inFlight };
                            const newProgress = { ...s.downloadProgress };
                            delete newInFlight[url];
                            delete newProgress[url];
                            return { cache: newCache, inFlight: newInFlight, downloadProgress: newProgress };
                        });

                        return finalPath;
                    } catch (e) {
                        console.error('[MediaDecrypt] Failed:', e);
                        set(s => {
                            const newInFlight = { ...s.inFlight };
                            const newProgress = { ...s.downloadProgress };
                            delete newInFlight[url];
                            delete newProgress[url];
                            return { inFlight: newInFlight, downloadProgress: newProgress };
                        });
                        return null;
                    }
                })();

                set(s => ({ inFlight: { ...s.inFlight, [url]: downloadPromise } }));

                return downloadPromise;
            },

            clearCache: async () => {
                try {
                    const docDir = FileSystem.documentDirectory;
                    const cacheDir = FileSystem.cacheDirectory;
                    if (docDir) await FileSystem.deleteAsync(`${docDir}encrypted_media/`, { idempotent: true });
                    if (cacheDir) await FileSystem.deleteAsync(`${cacheDir}encrypted_media/`, { idempotent: true });
                    set({ cache: {}, downloadProgress: {}, inFlight: {} });
                } catch (e) {
                    console.error('Failed to clear encrypted media cache', e);
                }
            }
        }),
        {
            name: 'encrypted-media-cache',
            storage: createJSONStorage(() => AsyncStorage),
            partialize: (state) => ({ cache: state.cache }),
        }
    )
);
