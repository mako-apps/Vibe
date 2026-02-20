import { useState, useRef } from 'react';
import {
    ArrowLeft, MoreVertical, Phone, Video,
    Bell, BellOff, Search,
    Trash2, Ban
} from 'lucide-react';
import { Chat } from '../types';
import '../ContactInfo.css';

interface ContactInfoProps {
    activeChat: Chat;
    setView: (view: string) => void;
    typingUsers: Set<string>;
    startCall: (video: boolean) => void;
    isMuted: boolean;
    toggleMute: () => void;
    blockContact: () => void;
    clearChat: (id: string) => void;
    deleteChat: (id: string) => void;
    onSearch: () => void;
    setToast: (msg: string | null) => void;
}

export default function ContactInfo({
    activeChat, setView, typingUsers, startCall,
    isMuted, toggleMute, blockContact, clearChat, deleteChat,
    onSearch, setToast
}: ContactInfoProps) {
    const scrollRef = useRef<HTMLDivElement>(null);
    const [isAvatarMode, setIsAvatarMode] = useState(false);
    const [showMenu, setShowMenu] = useState(false);
    const [isCopied, setIsCopied] = useState(false);

    const handleScroll = () => {
        if (!scrollRef.current) return;
        const top = scrollRef.current.scrollTop;
        const threshold = 50; // Pixel threshold to switch modes
        if (top > threshold && !isAvatarMode) {
            setIsAvatarMode(true);
        } else if (top <= threshold && isAvatarMode) {
            setIsAvatarMode(false);
        }
    };

    const friendImage = activeChat.friendImage;
    const initialLetter = activeChat.friendName ? activeChat.friendName[0].toUpperCase() : '?';

    return (
        <div className="ci-container">
            {/* Fixed Header (Glass) */}
            <header className={`ci-header ${isAvatarMode ? 'scrolled' : ''}`}>
                <div className="ci-header-bg" />
                <button className="ci-icon-btn" onClick={() => setView('chat')}>
                    <ArrowLeft size={20} />
                </button>
                <div style={{ flex: 1 }} />
                <button className="ci-icon-btn" onClick={() => setShowMenu(!showMenu)}>
                    <MoreVertical size={20} />
                </button>
            </header>

            {/* Scroll View */}
            <div className="ci-scroll-view" ref={scrollRef} onScroll={handleScroll}>

                {/* 40vh Wrapper - One Image */}
                <div className={`ci-banner-wrapper ${isAvatarMode ? 'avatar-mode' : ''}`}>
                    {/* Background Blur (Only visible in avatar mode) */}
                    {friendImage && (
                        <div
                            className="ci-banner-bg"
                            style={{ backgroundImage: `url(${friendImage})` }}
                        />
                    )}

                    {/* Main Image (Transitions from Full to Avatar) */}
                    {friendImage ? (
                        <img
                            src={friendImage}
                            className="ci-main-image"
                            alt="Contact"
                        />
                    ) : (
                        <div className="ci-main-image" style={{ background: '#333', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                            <span style={{ fontSize: 80, fontWeight: 700, color: 'rgba(255,255,255,0.1)' }}>
                                {initialLetter}
                            </span>
                        </div>
                    )}

                    {/* Gradient Overlay (Only visible in full mode) */}
                    <div className="ci-gradient-overlay" />
                </div>

                {/* Content */}
                <div className="ci-content">
                    <div className="ci-name-header">
                        <h2 className="ci-name">{activeChat.friendName}</h2>
                        <span className="ci-status">
                            {activeChat.friendId && typingUsers.has(activeChat.friendId.toUpperCase()) ? "typing..." : "Last seen recently"}
                        </span>
                    </div>

                    {/* Actions Grid */}
                    <div className="ci-actions-grid">
                        <button className="ci-action-btn" onClick={() => startCall && startCall(false)}>
                            <div className="ci-action-icon"><Phone size={22} /></div>
                            <span className="ci-action-label">Audio</span>
                        </button>
                        <button className="ci-action-btn" onClick={() => startCall && startCall(true)}>
                            <div className="ci-action-icon"><Video size={22} /></div>
                            <span className="ci-action-label">Video</span>
                        </button>
                        <button className={`ci-action-btn ${isMuted ? 'active' : ''}`} onClick={toggleMute}>
                            <div className="ci-action-icon">
                                {isMuted ? <BellOff size={22} /> : <Bell size={22} />}
                            </div>
                            <span className="ci-action-label">{isMuted ? 'Unmute' : 'Mute'}</span>
                        </button>
                        <button className="ci-action-btn" onClick={onSearch}>
                            <div className="ci-action-icon"><Search size={22} /></div>
                            <span className="ci-action-label">Search</span>
                        </button>
                    </div>

                    {/* Privacy & Actions List */}
                    <div className="ci-section-title" >Privacy & Actions</div>
                    <div className="ci-card">
                        <div className="ci-row" style={{ cursor: 'pointer', justifyContent: 'space-between', alignItems: 'center' }} onClick={async () => {
                            try {
                                await navigator.clipboard.writeText(`@${activeChat.friendName}`);
                                setIsCopied(true);
                                setTimeout(() => setIsCopied(false), 2000);
                            } catch (e) {
                                console.error('Copy failed', e);
                                setToast('Copy failed');
                            }
                        }}>
                            <span className="ci-label">Username</span>
                            <span className="ci-value" style={{ fontFamily: 'monospace', color: isCopied ? '#34d399' : 'var(--bubble-me)', fontSize: 16, fontWeight: 500, transition: 'all 0.2s' }}>
                                {isCopied ? 'Copied' : `@${activeChat.friendName}`}
                            </span>
                        </div>
                        <div className="ci-row" style={{ cursor: 'default' }}>
                            <span className="ci-label">Session Status</span>
                            <span className="ci-value" style={{ color: '#34d399', fontWeight: 600 }}>VERIFIED</span>
                        </div>
                        <div className="ci-row danger" onClick={blockContact}>
                            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', width: '100%' }}>
                                <span className="ci-label">Block Contact</span>
                                <Ban size={18} />
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            {/* Menu */}
            {showMenu && (
                <div className="ci-menu-overlay">
                    <div className="ci-menu-backdrop" onClick={() => setShowMenu(false)} />
                    <div className="ci-menu">
                        <button className="ci-menu-item danger" onClick={() => {
                            clearChat(activeChat.chatId);
                            setToast('Chat cleared');
                            setShowMenu(false);
                        }}>
                            <Trash2 size={16} /> Clear Chat
                        </button>
                        <button className="ci-menu-item danger" onClick={() => {
                            if (confirm('Delete contact?')) {
                                deleteChat(activeChat.chatId);
                                setView('chats');
                            }
                            setShowMenu(false);
                        }}>
                            <Ban size={16} /> Delete Contact
                        </button>
                    </div>
                </div>
            )}
        </div>
    );
}
