import type { BridgeBundle, BridgeDescriptor } from './types';

type LooseRecord = Record<string, unknown>;

export const asRecord = (value: unknown): LooseRecord | null => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as LooseRecord;
};

export const asString = (value: unknown): string | undefined => {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
};

export const asNumber = (value: unknown): number | undefined => {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
};

export const asBoolean = (value: unknown): boolean | undefined => {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
    if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  }
  return undefined;
};

export const coerceBridgeDescriptor = (value: unknown): BridgeDescriptor | null => {
  const record = asRecord(value);
  if (!record) return null;
  const id = asString(record.id) || asString(record.host) || asString(record.baseUrl);
  if (!id) return null;
  return {
    id,
    host: asString(record.host),
    port: asNumber(record.port),
    pathPrefix: asString(record.pathPrefix),
    transport: asString(record.transport),
    spkiPins: Array.isArray(record.spkiPins)
      ? record.spkiPins.map((entry) => asString(entry)).filter((entry): entry is string => !!entry)
      : undefined,
    priority: asNumber(record.priority),
    weight: asNumber(record.weight),
    expiresAt: asNumber(record.expiresAt),
    origin: asString(record.origin),
    baseUrl: asString(record.baseUrl),
  };
};

export const coerceBridgeBundle = (value: unknown): BridgeBundle | undefined => {
  const record = asRecord(value);
  if (!record) return undefined;
  const descriptorsSource = Array.isArray(record.descriptors) ? record.descriptors : [];
  const descriptors = descriptorsSource
    .map(coerceBridgeDescriptor)
    .filter((entry): entry is BridgeDescriptor => !!entry);
  if (descriptors.length === 0) return undefined;
  return {
    version: asNumber(record.version),
    generatedAt: asNumber(record.generatedAt),
    expiresAt: asNumber(record.expiresAt),
    descriptors,
    signature: asString(record.signature),
  };
};

export const buildBridgeBaseUrl = (
  bridgeBaseUrl: string | undefined,
  bridgeBundle: BridgeBundle | undefined,
  activeBridgeId: string | undefined,
): string | undefined => {
  if (bridgeBaseUrl) return bridgeBaseUrl;
  const descriptors = bridgeBundle?.descriptors ?? [];
  const preferred =
    descriptors.find((entry) => entry.id === activeBridgeId)
    || descriptors
      .slice()
      .sort((left, right) => (left.priority ?? 999) - (right.priority ?? 999))[0];
  if (!preferred) return undefined;
  if (preferred.baseUrl) return preferred.baseUrl;
  if (!preferred.host) return undefined;
  const protocol = preferred.transport === 'http' ? 'http' : 'https';
  const port = preferred.port ? `:${preferred.port}` : '';
  return `${protocol}://${preferred.host}${port}`;
};

const stableSortKeys = (value: unknown): unknown => {
  if (Array.isArray(value)) {
    return value.map(stableSortKeys);
  }
  if (!value || typeof value !== 'object') {
    return value;
  }
  const record = value as LooseRecord;
  return Object.keys(record)
    .sort()
    .reduce<LooseRecord>((acc, key) => {
      acc[key] = stableSortKeys(record[key]);
      return acc;
    }, {});
};

export const canonicalizeBridgeBundlePayload = (bundle: BridgeBundle): string => {
  const payload: LooseRecord = {
    version: bundle.version,
    generatedAt: bundle.generatedAt,
    expiresAt: bundle.expiresAt,
    descriptors: bundle.descriptors.map((descriptor) => ({
      id: descriptor.id,
      host: descriptor.host,
      port: descriptor.port,
      pathPrefix: descriptor.pathPrefix,
      transport: descriptor.transport,
      spkiPins: descriptor.spkiPins ?? [],
      priority: descriptor.priority,
      weight: descriptor.weight,
      expiresAt: descriptor.expiresAt,
      origin: descriptor.origin,
      baseUrl: descriptor.baseUrl,
    })),
  };
  return JSON.stringify(stableSortKeys(payload));
};
