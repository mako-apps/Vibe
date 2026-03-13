export type TransportMode = 'direct' | 'bridge_text' | 'offline';

export type BlackoutPhase =
  | 'normal'
  | 'suspect_blackout'
  | 'bridge_bootstrap'
  | 'bridge_active'
  | 'direct_reprobe'
  | 'offline';

export interface BridgeDescriptor {
  id: string;
  host?: string;
  port?: number;
  pathPrefix?: string;
  transport?: string;
  spkiPins?: string[];
  priority?: number;
  weight?: number;
  expiresAt?: number;
  origin?: 'official' | 'community' | 'imported' | string;
  baseUrl?: string;
}

export interface BridgeBundle {
  version?: number;
  generatedAt?: number;
  expiresAt?: number;
  descriptors: BridgeDescriptor[];
  signature?: string;
}

export interface BlackoutCapabilities {
  text?: boolean;
  homeSnapshot?: boolean;
  history?: boolean;
  media?: boolean;
  calls?: boolean;
  search?: boolean;
  avatars?: boolean;
}

export interface NativeTransportSnapshot {
  transportMode: TransportMode;
  bridgeBundle?: BridgeBundle;
  activeBridgeId?: string;
  bridgeBaseUrl?: string;
  blackoutCapabilities?: BlackoutCapabilities;
  disableRealtime?: boolean;
  disableMedia?: boolean;
  disableCalls?: boolean;
  disableRemoteAvatars?: boolean;
}

export interface BootstrapSnapshot {
  ready: boolean;
  bundle?: BridgeBundle;
  activeBridgeId?: string;
  bridgeBaseUrl?: string;
  source?: 'baked_in' | 'stored' | 'imported' | 'remote';
  verified: boolean;
  lastUpdatedAt?: number;
  lastError?: string;
}

export interface BlackoutStateSnapshot {
  ready: boolean;
  phase: BlackoutPhase;
  transportMode: TransportMode;
  directFailureTimestamps: number[];
  directSuccessStreak: number;
  bridgeFailureCount: number;
  activeBridgeId?: string;
  lastError?: string;
  updatedAt: number;
  lastBridgeConnectedAt?: number;
  lastDirectSuccessAt?: number;
}
