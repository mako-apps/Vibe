import { requireOptionalNativeModule } from 'expo-modules-core';

export type ChatNativeGifModule = {
  isSupported?: () => boolean;
  supportsNativeGifPanel?: () => boolean;
  setApiKey?: (apiKey: string) => void;
  getApiKey?: () => string;
  openPanel?: (keyboardHeight?: number) => Promise<void>;
  closePanel?: () => void;
};

export const ChatNativeGif = requireOptionalNativeModule<ChatNativeGifModule>('ChatNativeGif');

export const isNativeGifPanelAvailable = (): boolean => {
  return !!ChatNativeGif?.isSupported?.() && !!ChatNativeGif?.supportsNativeGifPanel?.();
};
