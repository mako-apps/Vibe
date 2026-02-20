import 'react-native-get-random-values';
import { Buffer } from 'buffer';

global.Buffer = global.Buffer || Buffer;


// Define a minimal global crypto object to prevent crashes on import
// The actual implementation will be handled by our custom node-forge wrapper in mobile/src/lib/crypto.ts
// or via react-native-webview-crypto if we go that route.
// For now, this just stops "cannot read property subtle of undefined".

if (typeof window !== 'undefined' && !window.crypto) {
    // @ts-ignore
    window.crypto = {
        getRandomValues: (array: any) => {
            // @ts-ignore
            return global.crypto.getRandomValues(array);
        },
        subtle: {
            generateKey: () => Promise.reject("Not implemented directly") as any,
            exportKey: () => Promise.reject("Not implemented directly") as any,
            importKey: () => Promise.reject("Not implemented directly") as any,
            encrypt: () => Promise.reject("Not implemented directly") as any,
            decrypt: () => Promise.reject("Not implemented directly") as any,
            digest: () => Promise.reject("Not implemented directly") as any,
            sign: () => Promise.reject("Not implemented directly") as any,
            verify: () => Promise.reject("Not implemented directly") as any,
            deriveKey: () => Promise.reject("Not implemented directly") as any,
            deriveBits: () => Promise.reject("Not implemented directly") as any,
            wrapKey: () => Promise.reject("Not implemented directly") as any,
            unwrapKey: () => Promise.reject("Not implemented directly") as any,
        }
    };
} else if (typeof window !== 'undefined' && window.crypto && !window.crypto.subtle) {
    // @ts-ignore
    window.crypto.subtle = {
        generateKey: () => Promise.reject("Not implemented directly") as any,
        exportKey: () => Promise.reject("Not implemented directly") as any,
        importKey: () => Promise.reject("Not implemented directly") as any,
        encrypt: () => Promise.reject("Not implemented directly") as any,
        decrypt: () => Promise.reject("Not implemented directly") as any,
        digest: () => Promise.reject("Not implemented directly") as any,
        sign: () => Promise.reject("Not implemented directly") as any,
        verify: () => Promise.reject("Not implemented directly") as any,
        deriveKey: () => Promise.reject("Not implemented directly") as any,
        deriveBits: () => Promise.reject("Not implemented directly") as any,
        wrapKey: () => Promise.reject("Not implemented directly") as any,
        unwrapKey: () => Promise.reject("Not implemented directly") as any,
    };
}
