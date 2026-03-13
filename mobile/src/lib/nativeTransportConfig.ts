import ProxyManager from './ProxyManager';
import { getBlackoutTransportSnapshot } from './transport/BlackoutState';
import {
  asBoolean,
  asRecord,
  asString,
  buildBridgeBaseUrl,
  coerceBridgeBundle,
} from './transport/bridgeBundle';
import type {
  BlackoutCapabilities as NativeBlackoutCapabilities,
  BridgeBundle as NativeBridgeBundle,
  BridgeDescriptor as NativeBridgeDescriptor,
  NativeTransportSnapshot as NativeTransportConfig,
  TransportMode as NativeTransportMode,
} from './transport/types';

export type {
  NativeBlackoutCapabilities,
  NativeBridgeBundle,
  NativeBridgeDescriptor,
  NativeTransportConfig,
  NativeTransportMode,
};

const DEFAULT_BLACKOUT_CAPABILITIES: NativeBlackoutCapabilities = {
  text: true,
  homeSnapshot: true,
  history: true,
  media: false,
  calls: false,
  search: false,
  avatars: false,
};

const normalizeTransportMode = (value: unknown): NativeTransportMode => {
  const normalized = asString(value)?.toLowerCase();
  if (normalized === 'bridge_text' || normalized === 'offline') return normalized;
  return 'direct';
};

export const resolveNativeTransportConfig = (): NativeTransportConfig => {
  const proxyManager = ProxyManager.getInstance();
  const currentEndpoint = proxyManager.getCurrentEndpoint();
  const endpointConfig = asRecord(currentEndpoint?.config);
  const globalOverride = asRecord((globalThis as Record<string, unknown>).__VIBE_NATIVE_TRANSPORT_CONFIG__);
  const blackoutOverride = getBlackoutTransportSnapshot();

  const source = {
    ...(endpointConfig || {}),
    ...(globalOverride || {}),
    ...(blackoutOverride || {}),
  };

  const endpointBridgeBundle = coerceBridgeBundle(endpointConfig?.bridgeBundle);
  const bridgeBundle =
    blackoutOverride.bridgeBundle
    || coerceBridgeBundle(globalOverride?.bridgeBundle)
    || endpointBridgeBundle;
  const activeBridgeId =
    asString(blackoutOverride.activeBridgeId)
    || asString(globalOverride?.activeBridgeId)
    || asString(endpointConfig?.activeBridgeId);
  const explicitBridgeBaseUrl =
    asString(blackoutOverride.bridgeBaseUrl)
    || asString(globalOverride?.bridgeBaseUrl)
    || asString(endpointConfig?.bridgeBaseUrl);

  let transportMode = normalizeTransportMode(source.transportMode);
  if (transportMode === 'direct' && blackoutOverride.transportMode !== 'direct') {
    transportMode = blackoutOverride.transportMode;
  }

  const bridgeBaseUrl = buildBridgeBaseUrl(explicitBridgeBaseUrl, bridgeBundle, activeBridgeId);
  const blackoutCapabilities: NativeBlackoutCapabilities =
    transportMode === 'bridge_text' || transportMode === 'offline'
      ? {
          ...DEFAULT_BLACKOUT_CAPABILITIES,
          ...(((asRecord(source.blackoutCapabilities) as Partial<NativeBlackoutCapabilities> | null) || {})),
        }
      : { text: true, media: true, calls: true, search: true, avatars: true };

  const disableMedia =
    asBoolean(source.disableMedia)
    ?? (transportMode !== 'direct' ? blackoutCapabilities.media === false : false);
  const disableCalls =
    asBoolean(source.disableCalls)
    ?? (transportMode !== 'direct' ? blackoutCapabilities.calls === false : false);
  const disableRealtime =
    asBoolean(source.disableRealtime) ?? transportMode === 'offline';
  const disableRemoteAvatars =
    asBoolean(source.disableRemoteAvatars)
    ?? (transportMode !== 'direct' ? blackoutCapabilities.avatars === false : false);

  return {
    transportMode: transportMode === 'bridge_text' && !bridgeBaseUrl ? 'offline' : transportMode,
    bridgeBundle,
    activeBridgeId,
    bridgeBaseUrl,
    blackoutCapabilities,
    disableRealtime,
    disableMedia,
    disableCalls,
    disableRemoteAvatars,
  };
};
