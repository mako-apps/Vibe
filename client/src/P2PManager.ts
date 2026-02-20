import Peer, { MediaConnection } from 'peerjs';

type CallCallback = (call: MediaConnection) => void;

class P2PManager {
    private static instance: P2PManager;
    private peer: Peer | null = null;
    private callListeners: CallCallback[] = [];
    private userId: string | null = null;

    private reconnectAttempts: number = 0;
    private maxReconnectAttempts: number = 3;
    private reconnectTimeout: any = null;

    // P2P is OPTIONAL - Video Calls Only
    private _isAvailable: boolean = false;
    private _disabled: boolean = false;

    private constructor() { }

    public static getInstance(): P2PManager {
        if (!P2PManager.instance) {
            P2PManager.instance = new P2PManager();
        }
        return P2PManager.instance;
    }

    // Check if P2P is available (connected and working)
    public get isAvailable(): boolean {
        return this._isAvailable && !this._disabled && this.peer !== null;
    }

    // Disable P2P entirely
    public disable(): void {
        this._disabled = true;
        this._isAvailable = false;
        if (this.peer) {
            try { this.peer.destroy(); } catch { }
            this.peer = null;
        }
        console.debug('[P2P] Disabled');
    }

    public init(userId: string) {
        if (this._disabled) return;
        const upperId = userId.toUpperCase();
        if (this.peer && this.userId === upperId) return;

        this.userId = upperId;
        this.connectToPeerServer();
    }

    private connectToPeerServer() {
        if (!this.userId) return;

        // Clear any pending reconnect
        if (this.reconnectTimeout) {
            clearTimeout(this.reconnectTimeout);
            this.reconnectTimeout = null;
        }

        // Use public TURN/STUN servers
        const config = {
            debug: 1,
            config: {
                iceServers: [
                    { urls: 'stun:stun.l.google.com:19302' },
                    { urls: 'stun:global.stun.twilio.com:3478' },
                    {
                        urls: 'turn:openrelay.metered.ca:80',
                        username: 'openrelayproject',
                        credential: 'openrelayproject'
                    },
                    {
                        urls: 'turn:openrelay.metered.ca:443',
                        username: 'openrelayproject',
                        credential: 'openrelayproject'
                    },
                    {
                        urls: 'turn:openrelay.metered.ca:443?transport=tcp',
                        username: 'openrelayproject',
                        credential: 'openrelayproject'
                    }
                ],
                iceTransportPolicy: 'all' as any
            }
        };

        // Destroy existing peer if present
        if (this.peer) {
            try {
                this.peer.destroy();
            } catch (e) { /* ignore */ }
        }

        const peerId = `SC_V1_${this.userId}`;
        console.debug(`[P2P] Init PeerJS for Calls. ID: ${peerId}`);

        try {
            this.peer = new Peer(peerId, config);
            this.setupPeerEvents();
        } catch (e) {
            console.error('[P2P] Failed to create Peer', e);
        }
    }

    private setupPeerEvents() {
        if (!this.peer) return;

        this.peer.on('open', (id) => {
            console.debug(`[P2P] Ready for calls. ID: ${id}`);
            this._isAvailable = true;
            this.reconnectAttempts = 0;
        });

        this.peer.on('call', (call) => {
            console.debug(`[P2P] Incoming Call from ${call.peer}`);
            this.notifyCallListeners(call);
        });

        this.peer.on('error', (err) => {
            const errType = (err as any).type;
            const errMessage = (err as any).message || '';

            if (errType === 'peer-unavailable') return; // Normal if user offline

            if (errType === 'unavailable-id' || errMessage.includes('is taken')) {
                console.debug('[P2P] Peer ID is taken (another tab active). Calls disabled in this tab.');
                this.disable();
                return;
            }

            if (['network', 'server-error', 'socket-error', 'webrtc'].includes(errType)) {
                this.scheduleReconnect();
            }
        });

        this.peer.on('disconnected', () => {
            console.debug('[P2P] Disconnected from signaling server');
            this._isAvailable = false;
            this.scheduleReconnect();
        });

        // Add visibility change listener
        if (typeof document !== 'undefined') {
            document.removeEventListener('visibilitychange', this.handleVisibilityChange);
            document.addEventListener('visibilitychange', this.handleVisibilityChange);
        }
    }

    private handleVisibilityChange = () => {
        if (document.visibilityState === 'visible') {
            if (!this.peer || this.peer.destroyed) {
                this.reconnectAttempts = 0;
                this.connectToPeerServer();
                return;
            }
            if (this.peer.disconnected && !this.peer.open) {
                try { this.peer.reconnect(); } catch { this.connectToPeerServer(); }
            }
        }
    };

    private scheduleReconnect() {
        if (this._disabled) return;
        if (this.reconnectAttempts >= this.maxReconnectAttempts) return;

        const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts), 30000);
        this.reconnectAttempts++;

        this.reconnectTimeout = setTimeout(() => {
            if (this.peer && !this.peer.destroyed && this.peer.disconnected) {
                try { this.peer.reconnect(); } catch { this.connectToPeerServer(); }
            } else if (!this.peer || this.peer.destroyed) {
                this.connectToPeerServer();
            }
        }, delay);
    }

    public getStatus() {
        return {
            ready: !!(this.peer && this.peer.open),
            id: this.peer?.id
        };
    }

    public call(friendId: string, stream: MediaStream, isVideo: boolean = false) {
        if (!this.peer || !this.peer.open) return null;
        const targetPeerId = `SC_V1_${friendId.toUpperCase()}`;
        console.debug(`[P2P] Calling ${targetPeerId} (video: ${isVideo})...`);
        return this.peer.call(targetPeerId, stream, { metadata: { isVideo } });
    }

    public onCall(cb: CallCallback) {
        this.callListeners.push(cb);
        return () => {
            this.callListeners = this.callListeners.filter(c => c !== cb);
        };
    }

    private notifyCallListeners(call: MediaConnection) {
        this.callListeners.forEach(cb => cb(call));
    }
}

export default P2PManager;
