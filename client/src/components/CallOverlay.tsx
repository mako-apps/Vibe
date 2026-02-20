import { useState, useRef, useEffect } from 'react';
import {
    Mic, MicOff, Video, VideoOff, PhoneOff, Minimize2, SwitchCamera, Phone, UserPlus, X, Check
} from 'lucide-react';
import { motion, AnimatePresence } from 'framer-motion';
import './CallOverlay.css';

export interface JoinRequest {
    odId: string;
    fromName: string;
    fromImage?: string;
    isVideo: boolean;
}

interface CallOverlayProps {
    isActive: boolean;
    isIncoming: boolean;
    friendName: string;
    friendImage?: string;
    isVideo: boolean;
    onEndCall: () => void;
    onAcceptCall: (withVideo: boolean) => void;
    onRejectCall: () => void;
    onToggleMute: () => void;
    onToggleVideo: () => void;
    onToggleCamera?: () => void;
    isMuted: boolean;
    isVideoEnabled: boolean;
    localStream: MediaStream | null;
    remoteStream: MediaStream | null;
    // Join request props
    joinRequests?: JoinRequest[];
    onAcceptJoinRequest?: (fromId: string) => void;
    onRejectJoinRequest?: (fromId: string) => void;
    onSendJoinRequest?: () => void;
    isJoinRequestPending?: boolean;
    onSendVoiceChunk?: (chunk: Blob) => void;
}

export default function CallOverlay({
    isActive, isIncoming, friendName, friendImage, isVideo,
    onEndCall, onAcceptCall, onRejectCall, onToggleMute, onToggleVideo, onToggleCamera,
    isMuted, isVideoEnabled, localStream, remoteStream,
    joinRequests = [], onAcceptJoinRequest, onRejectJoinRequest, onSendJoinRequest, isJoinRequestPending,
    onSendVoiceChunk
}: CallOverlayProps) {
    const [isMinimized, setIsMinimized] = useState(false);
    const localVideoRef = useRef<HTMLVideoElement>(null);
    const remoteVideoRef = useRef<HTMLVideoElement>(null);
    const remoteAudioRef = useRef<HTMLAudioElement>(null);
    const [dragConstraints, setDragConstraints] = useState({ top: 0, bottom: 0, left: 0, right: 0 });
    const [duration, setDuration] = useState(0);

    // Call Timer
    useEffect(() => {
        let interval: any;
        if (isActive && remoteStream) {
            interval = setInterval(() => {
                setDuration(d => d + 1);
            }, 1000);
        } else {
            setDuration(0);
        }
        return () => clearInterval(interval);
    }, [isActive, remoteStream]);

    const formatDuration = (sec: number) => {
        const m = Math.floor(sec / 60);
        const s = sec % 60;
        return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
    };

    useEffect(() => {
        if (localVideoRef.current && localStream) {
            localVideoRef.current.srcObject = localStream;
        }
    }, [localStream, isMinimized, isVideo]);

    useEffect(() => {
        if (remoteVideoRef.current && remoteStream) {
            remoteVideoRef.current.srcObject = remoteStream;
        }
        if (remoteAudioRef.current && remoteStream) {
            remoteAudioRef.current.srcObject = remoteStream;
        }
    }, [remoteStream, isMinimized, isVideo]);

    // Update drag constraints on resize
    useEffect(() => {
        const updateConstraints = () => {
            setDragConstraints({
                top: 0, bottom: window.innerHeight - 180,
                left: 0, right: window.innerWidth - 120
            });
        };
        updateConstraints();
        window.addEventListener('resize', updateConstraints);
        return () => window.removeEventListener('resize', updateConstraints);
    }, []);

    // Socket Audio Relay Streamer
    useEffect(() => {
        if (!localStream || isMuted || !isActive || !onSendVoiceChunk) return;

        let recorder: MediaRecorder | null = null;
        try {
            const audioTrack = localStream.getAudioTracks()[0];
            if (!audioTrack) return;
            const audioStream = new MediaStream([audioTrack]);

            // Try Opus first, then fallback
            const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
                ? 'audio/webm;codecs=opus'
                : 'audio/webm';

            recorder = new MediaRecorder(audioStream, { mimeType });
            recorder.ondataavailable = (e) => {
                if (e.data && e.data.size > 0) {
                    onSendVoiceChunk(e.data);
                }
            };
            recorder.start(250); // 250ms chunks
        } catch (e) {
            console.error("Socket Stream Start Error", e);
        }

        return () => {
            if (recorder && recorder.state !== 'inactive') {
                recorder.stop();
            }
        };
    }, [localStream, isMuted, isActive, onSendVoiceChunk]);


    if (!isActive && !isIncoming) return null;


    // Incoming Call Modal
    if (isIncoming) {
        return (
            <AnimatePresence>
                <div className="active-call-root">
                    <motion.div
                        initial={{ y: 50, opacity: 0 }}
                        animate={{ y: 0, opacity: 1 }}
                        exit={{ y: 50, opacity: 0 }}
                        className="active-viz-layer"
                        style={{ flexDirection: 'column' }}
                    >
                        <div className="center-info-wrapper">
                            {friendImage ? (
                                <img src={friendImage} className="incoming-avatar-large" alt="Caller" />
                            ) : (
                                <div className="incoming-placeholder-large">
                                    {friendName[0]?.toUpperCase()}
                                </div>
                            )}

                            <div className="call-info-center">
                                <div className="incoming-name-title">{friendName}</div>
                                <div className="call-status-label">
                                    {isVideo ? 'Incoming Video Call...' : 'Incoming Voice Call...'}
                                </div>
                            </div>
                        </div>

                        <div className="incoming-actions-row" style={{ marginTop: 60 }}>
                            <button className="glass-btn decline" onClick={onRejectCall}>
                                <PhoneOff size={18} />
                            </button>
                            <button className="glass-btn accept" onClick={() => onAcceptCall(isVideo)}>
                                <Phone size={18} />
                            </button>
                        </div>
                    </motion.div>
                </div>
            </AnimatePresence>
        );
    }

    // Active Call Interface
    return (
        <AnimatePresence mode="wait">
            {!isMinimized ? (
                <motion.div
                    key="fullscreen"
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 1 }}
                    exit={{ opacity: 0 }}
                    className="active-call-root"
                >
                    {/* Minimal Header (Just Minimize) */}
                    <div className="header-overlay header-minimize-only">
                        <button className="minimize-glass-btn" onClick={() => setIsMinimized(true)}>
                            <Minimize2 size={20} />
                        </button>
                    </div>

                    {/* Join Requests Banner */}
                    <AnimatePresence>
                        {joinRequests.length > 0 && (
                            <motion.div
                                initial={{ y: -100, opacity: 0 }}
                                animate={{ y: 0, opacity: 1 }}
                                exit={{ y: -100, opacity: 0 }}
                                className="join-requests-banner"
                            >
                                {joinRequests.map((req) => (
                                    <div key={req.odId} className="join-request-item">
                                        {req.fromImage ? (
                                            <img src={req.fromImage} className="join-request-avatar" alt="" />
                                        ) : (
                                            <div className="join-request-avatar-placeholder">
                                                {req.fromName[0]?.toUpperCase()}
                                            </div>
                                        )}
                                        <div className="join-request-info">
                                            <span className="join-request-name">{req.fromName}</span>
                                            <span className="join-request-label">wants to join</span>
                                        </div>
                                        <div className="join-request-actions">
                                            <button
                                                className="join-action-btn reject"
                                                onClick={() => onRejectJoinRequest?.(req.odId)}
                                            >
                                                <X size={16} />
                                            </button>
                                            <button
                                                className="join-action-btn accept"
                                                onClick={() => onAcceptJoinRequest?.(req.odId)}
                                            >
                                                <Check size={16} />
                                            </button>
                                        </div>
                                    </div>
                                ))}
                            </motion.div>
                        )}
                    </AnimatePresence>

                    {/* Main View Area */}
                    <div className="active-viz-layer">
                        {isVideo && remoteStream ? (
                            <video ref={remoteVideoRef} autoPlay playsInline className="remote-video-feed" />
                        ) : (
                            <div className="center-info-wrapper">
                                {friendImage ? (
                                    <img src={friendImage} className="incoming-avatar-large" alt="" />
                                ) : (
                                    <div className="incoming-placeholder-large">
                                        {friendName[0]?.toUpperCase()}
                                    </div>
                                )}

                                <div className="call-info-center">
                                    <div className="incoming-name-title">{friendName}</div>
                                    <div className="call-status-label">
                                        {remoteStream ? (
                                            <span className="call-timer-large">{formatDuration(duration)}</span>
                                        ) : (
                                            'Ringing...'
                                        )}
                                    </div>
                                </div>
                            </div>
                        )}
                    </div>

                    {/* Local PIP (Draggable) */}
                    {isVideo && localStream && (
                        <motion.div
                            drag
                            dragConstraints={dragConstraints}
                            className="pip-wrapper"
                            initial={{ x: window.innerWidth - 140, y: 100 }}
                            whileTap={{ cursor: 'grabbing' }}
                        >
                            <video ref={localVideoRef} autoPlay playsInline muted className="local-video-feed" />
                        </motion.div>
                    )}

                    {/* Controls Dock */}
                    <div className="controls-dock">
                        <button className={`ctrl-btn ${isMuted ? 'active' : ''}`} onClick={onToggleMute}>
                            {isMuted ? <MicOff size={24} /> : <Mic size={28} />}
                        </button>

                        {isVideo && (
                            <>
                                <button className={`ctrl-btn ${!isVideoEnabled ? 'active' : ''}`} onClick={onToggleVideo}>
                                    {!isVideoEnabled ? <VideoOff size={24} /> : <Video size={28} />}
                                </button>
                                {onToggleCamera && (
                                    <button className="ctrl-btn" onClick={onToggleCamera}>
                                        <SwitchCamera size={26} />
                                    </button>
                                )}
                            </>
                        )}

                        {/* Add User / Join Request Button */}
                        {onSendJoinRequest && (
                            <button
                                className={`ctrl-btn ${isJoinRequestPending ? 'active' : ''}`}
                                onClick={onSendJoinRequest}
                                disabled={isJoinRequestPending}
                            >
                                <UserPlus size={24} />
                            </button>
                        )}

                        <button className="ctrl-btn hangup" onClick={onEndCall}>
                            <PhoneOff size={24} />
                        </button>
                    </div>
                </motion.div>
            ) : (
                // Minimized Bubble
                <motion.div
                    key="minimized"
                    drag
                    dragMomentum={false}
                    className="mini-bubble-root"
                    initial={{ scale: 0.8, opacity: 0 }}
                    animate={{ scale: 1, opacity: 1, x: 20, y: 120 }}
                    exit={{ scale: 0.8, opacity: 0 }}
                    onClick={() => setIsMinimized(false)}
                >
                    {/* Join request indicator on minimized view */}
                    {joinRequests.length > 0 && (
                        <div className="mini-join-badge">{joinRequests.length}</div>
                    )}
                    {isVideo && remoteStream ? (
                        <video ref={remoteVideoRef} autoPlay playsInline className="remote-video-feed" />
                    ) : (
                        <div className="mini-placeholder">
                            {friendName[0]?.toUpperCase()}
                        </div>
                    )}
                </motion.div>
            )}

            {/* Always mount audio for voice calls to ensure sound plays even if video is hidden */}
            {remoteStream && (
                <audio
                    ref={remoteAudioRef}
                    autoPlay
                    style={{ display: 'none' }}
                />
            )}
        </AnimatePresence>
    );
}
