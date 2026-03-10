import fs from 'fs';
import path from 'path';

import type { ExpoConfig } from 'expo/config';

const appJson = require('./app.json') as { expo: ExpoConfig };

const parseEnvFile = (filePath: string): Record<string, string> => {
  if (!fs.existsSync(filePath)) return {};

  const raw = fs.readFileSync(filePath, 'utf8');
  const entries: Record<string, string> = {};

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const separatorIndex = trimmed.indexOf('=');
    if (separatorIndex <= 0) continue;

    const key = trimmed.slice(0, separatorIndex).trim();
    if (!key) continue;

    let value = trimmed.slice(separatorIndex + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"'))
      || (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    entries[key] = value;
  }

  return entries;
};

const resolveGiphyApiKey = (): string => {
  const mobileEnv = parseEnvFile(path.resolve(__dirname, '.env'));
  const rootEnv = parseEnvFile(path.resolve(__dirname, '..', '.env'));

  return (
    process.env.EXPO_PUBLIC_GIPHY_API_KEY
    || mobileEnv.EXPO_PUBLIC_GIPHY_API_KEY
    || rootEnv.EXPO_PUBLIC_GIPHY_API_KEY
    || process.env.GIPHY_API_KEY
    || mobileEnv.GIPHY_API_KEY
    || rootEnv.GIPHY_API_KEY
    || ''
  ).trim();
};

export default (): ExpoConfig => {
  const baseConfig = appJson.expo;
  const giphyApiKey = resolveGiphyApiKey();

  return {
    ...baseConfig,
    extra: {
      ...(baseConfig.extra ?? {}),
      ...(giphyApiKey ? { giphyApiKey } : {}),
    },
  };
};
