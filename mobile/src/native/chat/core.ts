import { decryptMessage, encryptMessage as encryptMessageJs } from '../../lib/crypto';

import type {
  NativeChatDecryptBatchInput,
  NativeChatDecryptBatchResult,
  NativeChatEncryptInput,
  NativeChatNormalizeBatchInput,
  NativeChatNormalizeBatchResult,
} from './types';
import { getNativeChatCoreModule } from './runtime';

export const decryptMessagesBatch = async (
  input: NativeChatDecryptBatchInput,
): Promise<NativeChatDecryptBatchResult> => {
  const nativeCore = getNativeChatCoreModule();
  if (nativeCore?.supportsCryptoPipeline?.() && nativeCore.decryptMessagesBatch) {
    try {
      return await nativeCore.decryptMessagesBatch(input);
    } catch (error) {
      console.warn('[NativeChatCore] decryptMessagesBatch failed, falling back to JS', error);
    }
  }

  const entries = await Promise.all(
    input.items.map(async (item) => {
      try {
        const decrypted = await decryptMessage(input.privateKey, item.encryptedContent, item.isFromMe);
        return [item.id, decrypted || ''] as const;
      } catch {
        return [item.id, ''] as const;
      }
    }),
  );

  const messages: Record<string, string> = {};
  for (const [id, plaintext] of entries) {
    if (plaintext) {
      messages[id] = plaintext;
    }
  }

  return { messages };
};

export const normalizeRowsBatch = async (
  input: NativeChatNormalizeBatchInput,
): Promise<NativeChatNormalizeBatchResult> => {
  const nativeCore = getNativeChatCoreModule();
  if (nativeCore?.normalizeRowsBatch) {
    try {
      return await nativeCore.normalizeRowsBatch(input);
    } catch (error) {
      console.warn('[NativeChatCore] normalizeRowsBatch failed, falling back to JS', error);
    }
  }

  return {
    rows: input.rows,
    changed: false,
  };
};

export const encryptMessageNativeFirst = async (
  input: NativeChatEncryptInput,
): Promise<string> => {
  const nativeCore = getNativeChatCoreModule();
  if (nativeCore?.supportsCryptoPipeline?.() && nativeCore.encryptMessage) {
    try {
      return await nativeCore.encryptMessage(input);
    } catch (error) {
      console.warn('[NativeChatCore] encryptMessage failed, falling back to JS', error);
    }
  }

  return encryptMessageJs(input.recipientPublicKey, input.message, input.myPublicKey);
};
