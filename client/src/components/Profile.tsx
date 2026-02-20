import React, { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { ChevronLeft, Copy, Globe, RefreshCw, Pencil, Shield, Key, Eye, EyeOff, MessageCircle, Check, LogOut, Trash2 } from 'lucide-react';
import { getApiUrl } from '../utils';
import { keyStore } from '../localKeyStore';
import { privacySettings, PrivacySettings } from '../privacySettings';


interface ProfileProps {
    setView: (view: string) => void;
    username: string;
    userId: string;
    connectionStatus: string;
    currentServerName: string;
    isRefreshing: boolean;
    handleRefresh: () => void;
    requestNotificationPermission: () => void;
    logout: () => void;
    deleteAccount: () => void;
    setLightboxImage?: (img: string | null) => void;
}

const Profile: React.FC<ProfileProps> = ({
    setView, username, userId, connectionStatus, currentServerName,
    isRefreshing, handleRefresh, requestNotificationPermission, logout, deleteAccount, setLightboxImage
}) => {
    const [profileImage, setProfileImage] = useState<string | null>(null);
    const [isLoadingImage, setIsLoadingImage] = useState(true);
    const [isKeyRevealed, setIsKeyRevealed] = useState(false);
    const [copyToast, setCopyToast] = useState(false);

    // Privacy settings state
    const [privacy, setPrivacy] = useState<PrivacySettings>(privacySettings.get());
    const [secretKey, setSecretKey] = useState<string>('');

    // Subscribe to privacy setting changes
    useEffect(() => {
        return privacySettings.subscribe(setPrivacy);
    }, []);

    useEffect(() => {
        const loadKey = async () => {
            const session = await keyStore.loadSession();
            if (session?.secretKey) {
                setSecretKey(session.secretKey);
            }
        };
        loadKey();
    }, []);

    // Fetch profile image from API on mount
    useEffect(() => {
        const fetchProfile = async () => {
            try {
                const res = await fetch(`${getApiUrl()}/api/user/${userId}`, {
                    headers: { 'ngrok-skip-browser-warning': 'true' }
                });
                if (res.ok) {
                    const data = await res.json();
                    if (data.profileImage) {
                        setProfileImage(data.profileImage);
                    }
                }
            } catch (e) {
                console.error('Failed to fetch profile:', e);
            } finally {
                setIsLoadingImage(false);
            }
        };
        if (userId) fetchProfile();
    }, [userId]);

    const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (file) {
            setIsLoadingImage(true);
            const reader = new FileReader();
            reader.onload = async (ev) => {
                const base64 = ev.target?.result as string;
                setProfileImage(base64); // Optimistic update
                try {
                    await fetch(`${getApiUrl()}/api/user/profile`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
                        body: JSON.stringify({ userId, profileImage: base64 })
                    });
                } catch (err) {
                    console.error('Failed to update profile', err);
                } finally {
                    setIsLoadingImage(false);
                }
            };
            reader.readAsDataURL(file);
        }
    };

    const copyUsername = () => {
        navigator.clipboard.writeText(`@${username}`);
        setCopyToast(true);
        setTimeout(() => setCopyToast(false), 2000);
    };

    return (
        <motion.div
            key="profile-content"
            className="view-chats"
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -20 }}
            transition={{ duration: 0.25 }}
            style={{ background: 'var(--bg-primary)' }}
        >
            <div className="header-mask-container">
                <header className="main-header" style={{ justifyContent: 'center' }}>
                    <button className="icon-btn" onClick={() => setView('chats')} style={{ position: 'absolute', left: 16 }}>
                        <ChevronLeft size={18} />
                    </button>
                    <h2 style={{ fontSize: 17, fontWeight: 600 }}>Settings</h2>
                </header>
            </div>

            <div className="settings-container">
                {/* Avatar Section */}
                <div className="settings-avatar-section">
                    <div
                        className="settings-avatar"
                        onClick={() => profileImage && setLightboxImage ? setLightboxImage(profileImage) : null}
                    >
                        {isLoadingImage ? (
                            <div className="shine-wrapper">
                                <div className="shine-inner"></div>
                            </div>
                        ) : profileImage ? (
                            <img src={profileImage} alt="Profile" />
                        ) : (
                            username[0]?.toUpperCase()
                        )}

                        {/* Edit Button Overlay - Inside avatar */}
                        <label htmlFor="avatar-upload" className="settings-edit-btn" onClick={(e) => e.stopPropagation()}>
                            <Pencil size={14} color="white" />
                        </label>
                        <input
                            id="avatar-upload"
                            type="file"
                            accept="image/*"
                            style={{ display: 'none' }}
                            onChange={handleFileChange}
                            onClick={(e) => e.stopPropagation()}
                        />
                    </div>

                    <h2 className="settings-name">{username}</h2>
                    <p style={{ textAlign: 'center', color: 'var(--text-secondary)', fontSize: 13 }}>
                        {isLoadingImage ? 'Loading...' : 'Tap to edit'}
                    </p>
                </div>

                {/* Account Info */}
                <div className="profile-section-group">
                    <div className="profile-section-label">Account</div>
                    <div className="profile-card">
                        <div className="profile-row" onClick={copyUsername}>
                            <span className="row-label">Username</span>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                                <span className="row-value">@{username}</span>
                                <Copy size={14} color="var(--text-secondary)" />
                            </div>
                        </div>
                    </div>
                </div>

                {/* Security - Secret Key Only */}
                <div className="profile-section-group">
                    <div className="profile-section-label">Security</div>
                    <div className="profile-card">
                        <div className="profile-row" onClick={() => { }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <Key size={16} color="var(--accent)" />
                                <span className="row-label">Secret Key</span>
                            </div>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <span className="row-value" style={{
                                    fontSize: isKeyRevealed ? 12 : 16,
                                    color: 'var(--text-secondary)',
                                    letterSpacing: isKeyRevealed ? 0 : 2,
                                    filter: isKeyRevealed ? 'none' : 'blur(4px)',
                                    fontFamily: 'monospace'
                                }}>
                                    {isKeyRevealed ? (secretKey || 'UNKNOWN') : '••••••••'}
                                </span>
                                <button
                                    onClick={(e) => { e.stopPropagation(); setIsKeyRevealed(!isKeyRevealed); }}
                                    style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 4 }}
                                >
                                    {isKeyRevealed ? <EyeOff size={16} color="var(--text-secondary)" /> : <Eye size={16} color="var(--text-secondary)" />}
                                </button>
                                <button
                                    onClick={(e) => {
                                        e.stopPropagation();
                                        if (secretKey) {
                                            navigator.clipboard.writeText(secretKey);
                                            setCopyToast(true);
                                            setTimeout(() => setCopyToast(false), 2000);
                                        }
                                    }}
                                    style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 4 }}
                                >
                                    <Copy size={16} color="var(--text-secondary)" />
                                </button>
                            </div>
                        </div>

                        <div className="profile-row" style={{ cursor: 'default' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <Shield size={16} color="#10b981" />
                                <span className="row-label">Encryption</span>
                            </div>
                            <span className="row-value" style={{ color: '#10b981', fontWeight: 600 }}>Active</span>
                        </div>
                    </div>
                </div>

                {/* Connection Stats */}
                <div className="profile-section-group">
                    <div className="profile-section-label">Connection</div>
                    <div className="profile-card">
                        <div className="profile-row">
                            <span className="row-label">Status</span>
                            <span className="row-value" style={{
                                color: connectionStatus === 'connected' ? '#10b981' : '#fbbf24',
                                fontWeight: 600
                            }}>
                                {connectionStatus.toUpperCase()}
                            </span>
                        </div>
                        <div className="profile-row">
                            <span className="row-label">Server</span>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                                <Globe size={14} color="var(--text-secondary)" />
                                <span className="row-value">{currentServerName || 'Unknown'}</span>
                            </div>
                        </div>
                        <div className="profile-row" onClick={handleRefresh}>
                            <span className="row-label">Sync Data</span>
                            <RefreshCw size={16} color="var(--accent)" className={isRefreshing ? 'spin' : ''} />
                        </div>
                    </div>
                </div>

                {/* Preferences */}
                <div className="profile-section-group">
                    <div className="profile-section-label">Preferences</div>
                    <div className="profile-card">
                        <div className="profile-row" style={{ cursor: 'default' }}>
                            <span className="row-label">Notifications</span>
                            <label className="toggle-switch">
                                <input
                                    type="checkbox"
                                    checked={Notification.permission === 'granted'}
                                    onChange={requestNotificationPermission}
                                />
                                <span className="slider"></span>
                            </label>
                        </div>
                    </div>
                </div>

                {/* Privacy */}
                <div className="profile-section-group">
                    <div className="profile-section-label">Privacy</div>
                    <div className="profile-card">
                        <div className="profile-row" style={{ cursor: 'default' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <Eye size={16} color="var(--text-secondary)" />
                                <span className="row-label">Show Online Status</span>
                            </div>
                            <label className="toggle-switch">
                                <input
                                    type="checkbox"
                                    checked={privacy.showOnlineStatus}
                                    onChange={(e) => privacySettings.update({ showOnlineStatus: e.target.checked })}
                                />
                                <span className="slider"></span>
                            </label>
                        </div>
                        <div className="profile-row" style={{ cursor: 'default' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <Check size={16} color="var(--text-secondary)" />
                                <span className="row-label">Send Read Receipts</span>
                            </div>
                            <label className="toggle-switch">
                                <input
                                    type="checkbox"
                                    checked={privacy.sendReadReceipts}
                                    onChange={(e) => privacySettings.update({ sendReadReceipts: e.target.checked })}
                                />
                                <span className="slider"></span>
                            </label>
                        </div>
                        <div className="profile-row" style={{ cursor: 'default' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <MessageCircle size={16} color="var(--text-secondary)" />
                                <span className="row-label">Show Typing Indicator</span>
                            </div>
                            <label className="toggle-switch">
                                <input
                                    type="checkbox"
                                    checked={privacy.showTypingIndicator}
                                    onChange={(e) => privacySettings.update({ showTypingIndicator: e.target.checked })}
                                />
                                <span className="slider"></span>
                            </label>
                        </div>
                    </div>
                </div>

                {/* Session */}
                <div className="profile-section-group">
                    <div className="profile-section-label">Session</div>
                    <div className="profile-card">
                        <div className="profile-row" onClick={logout} style={{ color: '#ef4444' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <LogOut size={16} />
                                <span className="row-label" style={{ color: '#ef4444' }}>Log Out</span>
                            </div>
                        </div>
                        <div className="profile-row" onClick={() => {
                            if (confirm('Clear all local data and reload? This will fix stale session issues.')) {
                                localStorage.clear();
                                window.location.reload();
                            }
                        }} style={{ color: '#ef4444' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <RefreshCw size={16} />
                                <span className="row-label" style={{ color: '#ef4444' }}>Reset App Data</span>
                            </div>
                        </div>
                        <div className="profile-row" onClick={deleteAccount} style={{ color: '#ef4444' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                <Trash2 size={16} />
                                <span className="row-label" style={{ color: '#ef4444' }}>Delete Account</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <AnimatePresence>
                {copyToast && (
                    <motion.div
                        initial={{ opacity: 0, y: 10 }}
                        animate={{ opacity: 1, y: 0 }}
                        exit={{ opacity: 0 }}
                        style={{
                            position: 'fixed', bottom: 40, left: '50%', translateX: '-50%',
                            background: '#333', color: 'white', padding: '8px 16px', borderRadius: 20,
                            fontSize: 13, fontWeight: 500, zIndex: 9999
                        }}
                    >
                        Copied to clipboard
                    </motion.div>
                )}
            </AnimatePresence>
        </motion.div>
    );
};

export default Profile;
