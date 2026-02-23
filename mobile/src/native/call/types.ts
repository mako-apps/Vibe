export type NativeCallPendingEvent = {
  type: string;
  timestamp?: number;
  payload?: Record<string, unknown>;
};

export type NativeCallPushTokens = {
  platform?: string;
  fcm?: string | null;
  apns?: string | null;
  voip?: string | null;
};

export interface NativeCallModule {
  isSupported?: () => boolean;
  supportsInAppUi?: () => boolean;
  drainPendingEvents?: () => NativeCallPendingEvent[];
  getPushTokens?: () => NativeCallPushTokens | null;
  clearIncomingCallUi?: (payload: Record<string, unknown>) => void;
  setCallUiState?: (payload: Record<string, unknown>) => void;
  hideCallUi?: () => void;
}

export type NativeCallUiEvent = {
  type:
    | 'accept'
    | 'decline'
    | 'end'
    | 'toggleMute'
    | 'toggleSpeaker'
    | 'toggleVideo'
    | 'flipCamera'
    | 'message'
    | 'remind'
    | string;
};
