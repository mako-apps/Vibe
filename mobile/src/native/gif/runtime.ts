import Constants from 'expo-constants';

type NativeGifModule = {
  setApiKey?: (apiKey: string) => void;
  getApiKey?: () => string;
};

const GIF_MODULE_NAME = 'ChatNativeGif';

let cachedGifModule: NativeGifModule | null | undefined;

const loadOptionalNativeModule = <T>(moduleName: string): T | null => {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const core = require('expo-modules-core');

    if (typeof core.requireNativeModule === 'function') {
      try {
        return core.requireNativeModule(moduleName) as T;
      } catch {
        // fall through
      }
    }

    if (typeof core.requireOptionalNativeModule === 'function') {
      const optionalModule = core.requireOptionalNativeModule(moduleName) as T | null;
      if (optionalModule) return optionalModule;
    }

    const nativeModulesProxy = core.NativeModulesProxy as Record<string, T> | undefined;
    if (nativeModulesProxy && nativeModulesProxy[moduleName]) {
      return nativeModulesProxy[moduleName];
    }
  } catch {
    return null;
  }
  return null;
};

export const getNativeGifModule = (): NativeGifModule | null => {
  if (cachedGifModule) return cachedGifModule;
  const resolved = loadOptionalNativeModule<NativeGifModule>(GIF_MODULE_NAME);
  if (resolved || !__DEV__) {
    cachedGifModule = resolved;
  }
  return resolved ?? null;
};

type NativeGifConfigExtra = {
  giphyApiKey?: string;
  giphy?: {
    apiKey?: string;
  };
};

const normalizeString = (value: unknown): string => {
  if (typeof value !== 'string') return '';
  return value.trim();
};

const redactKey = (value: string): string => {
  if (!value) return '(empty)';
  if (value.length <= 8) return `${value.slice(0, 2)}...${value.slice(-2)}`;
  return `${value.slice(0, 4)}...${value.slice(-4)}`;
};

export const resolveNativeGifApiKey = (): string => {
  const envKey = normalizeString(process.env.EXPO_PUBLIC_GIPHY_API_KEY);
  if (envKey) {
    console.log('[NativeGif][JS] resolved key from process.env.EXPO_PUBLIC_GIPHY_API_KEY', {
      length: envKey.length,
      preview: redactKey(envKey),
    });
    return envKey;
  }

  const extra = (Constants.expoConfig?.extra || Constants.manifest2?.extra || {}) as NativeGifConfigExtra;
  const extraKey = normalizeString(extra.giphy?.apiKey ?? extra.giphyApiKey);
  console.log('[NativeGif][JS] resolved key from expo extra', {
    hasKey: !!extraKey,
    length: extraKey.length,
    preview: redactKey(extraKey),
    extraKeys: Object.keys(extra || {}),
  });
  return extraKey;
};

export const configureNativeGifApiKey = (): void => {
  const apiKey = resolveNativeGifApiKey();
  const nativeModule = getNativeGifModule();
  console.log('[NativeGif][JS] configureNativeGifApiKey', {
    hasKey: !!apiKey,
    keyLength: apiKey.length,
    preview: redactKey(apiKey),
    hasNativeModule: !!nativeModule,
  });
  if (!apiKey) return;
  nativeModule?.setApiKey?.(apiKey);
};
