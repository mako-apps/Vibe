import React, { useState } from 'react';
import { motion, AnimatePresence, useMotionValue, useTransform, useAnimation, animate } from 'framer-motion';
import { useDrag } from '@use-gesture/react';
import { Trash2, Pin, VolumeX, Copy, Ghost } from 'lucide-react';
import { Chat } from '../types';
import { timeAgo } from '../utils';
import HomeHeader from './HomeHeader';
import './Home.css';
import Haptics from '../haptics';

interface ChatListProps {
    isEditing: boolean;
    setIsEditing: (is: boolean) => void;
    connectionStatus: string;
    setView: (view: string) => void;
    areChatsLoading: boolean;
    chats: Chat[];
    userId: string;
    openChat: (chat: Chat) => void;
    deleteChat: (chatId: string) => void;
    typingUsers: Set<string>;
    setShowNewChatModal: (show: boolean) => void;
    toast: string | null;
    chatOptionsChat: Chat | null;
    setChatOptionsChat: (chat: Chat | null) => void;
    clearChat: (chatId: string) => void;
    pinChat: (chatId: string) => void;
    toggleMute: (chatId: string) => void;
    username: string;
}

// Swipeable Row Component using @use-gesture/react
const SwipeableChatRow = ({
    chat,
    isEditing,
    userId,
    typingUsers,
    onOpen,
    onDelete,
    onPin,
    onContextMenu
}: {
    chat: Chat;
    isEditing: boolean;
    userId: string;
    typingUsers: Set<string>;
    onOpen: () => void;
    onDelete: () => void;
    onPin: () => void;
    onContextMenu: (e: React.MouseEvent | null, rect?: DOMRect) => void;
}) => {
    const x = useMotionValue(0);
    const controls = useAnimation();
    const lastMsg = chat.messages[chat.messages.length - 1];

    // Background color based on swipe direction - Dead zone around 0 to hide icons on hold/jitter
    const bgInfo = useTransform(x, [-100, -30, 0, 30, 100], [
        'rgba(239, 68, 68, 1)',  // Red at -100
        'rgba(239, 68, 68, 0)',  // Transparent at -30
        'rgba(0,0,0,0)',        // Transparent at 0
        'rgba(59, 130, 246, 0)',  // Transparent at 30
        'rgba(59, 130, 246, 1)'   // Blue at 100
    ]);

    // Icon opacity and scale mapping
    const iconOpacity = useTransform(x, [-60, -20, 0, 20, 60], [1, 0, 0, 0, 1]);
    const iconScale = useTransform(x, [-120, -60, 0, 60, 120], [1.5, 1, 0.5, 1, 1.5]);

    // Integrated Long Press Helpers
    const longPressTimer = React.useRef<any>(null);

    const clearLongPress = () => {
        if (longPressTimer.current) {
            clearTimeout(longPressTimer.current);
            longPressTimer.current = null;
        }
    };

    const bind = useDrag(({ active, first, movement: [mx, my], cancel, event }) => {
        // Normalize event to help TS if needed
        const e = event as unknown as React.PointerEvent;

        // --- Long Press Logic ---
        if (first) {
            clearLongPress();
            // Start Timer
            // We need to capture the target immediately
            const target = e?.currentTarget as HTMLElement;
            if (target) {
                longPressTimer.current = setTimeout(() => {
                    try { Haptics.medium(); } catch (e) { }
                    const rect = target.getBoundingClientRect();
                    onContextMenu(null, rect);
                }, 400);
            }
        }

        // Cancel long press if moved
        if (active && (Math.abs(mx) > 10 || Math.abs(my) > 10)) {
            clearLongPress();
        }

        // --- Swipe Logic ---
        // Suppress vertical
        if (active && Math.abs(my) > Math.abs(mx) * 1.5) {
            cancel();
            clearLongPress();
            return;
        }

        if (active) {
            // Haptic feedback on threshold crossing
            if (mx > 60 && x.get() <= 60) Haptics.medium();
            if (mx < -60 && x.get() >= -60) Haptics.medium();

            // Apply damping/resistance
            const damped = mx;
            x.set(damped);
        } else {
            // console.log('[SwipeableChatRow] Released. Movement:', mx, my);
            clearLongPress();

            // Release logic
            if (Math.abs(mx) < 10 && Math.abs(my) < 10) {
                // console.log('[SwipeableChatRow] Tap Detected. isEditing:', isEditing);
                if (isEditing) onDelete();
                else {
                    // console.log('[SwipeableChatRow] Calling onOpen');
                    onOpen();
                }
            } else if (mx < -60) {
                // Swipe Left -> Delete
                Haptics.error();
                if (window.confirm("Delete this chat?")) onDelete();
                controls.start({ x: 0 });
            } else if (mx > 60) {
                // Swipe Right -> Pin
                Haptics.success();
                onPin();
                controls.start({ x: 0 });
            } else {
                // Snap back
                animate(x, 0, { type: "spring", stiffness: 400, damping: 30 });
            }
        }
    }, {
        axis: 'x',
        filterTaps: true,
        threshold: 5,
        pointer: { touch: true }
    });

    return (
        <motion.div layout className="chat-row-wrapper" style={{ position: 'relative' }}>
            {/* Background Actions */}
            <motion.div className="chat-row-bg-actions" style={{ background: bgInfo }}>
                <motion.div style={{ display: 'flex', alignItems: 'center', color: '#fff', opacity: iconOpacity, scale: iconScale, x: 20 }}>
                    <Pin size={24} fill="white" />
                </motion.div>
                <motion.div style={{ display: 'flex', alignItems: 'center', color: '#fff', opacity: iconOpacity, scale: iconScale, x: -20 }}>
                    <Trash2 size={24} />
                </motion.div>
            </motion.div>

            {/* Foreground Content - Swipeable Layer */}
            <motion.div
                className="chat-row-card"
                style={{ x, touchAction: 'pan-y' }}
                {...(bind() as any)}
                animate={controls}
                whileTap={{ scale: 0.98 }}
                onContextMenu={(e) => {
                    e.preventDefault();
                    onContextMenu(e);
                }}
            >
                {isEditing && (
                    <div style={{ marginRight: 12 }}>
                        <button onClick={(e) => { e.stopPropagation(); onDelete(); }} className="edit-delete-btn">
                            <Trash2 size={14} />
                        </button>
                    </div>
                )}
                <div className="avatar-container">
                    {chat.friendImage ? (
                        <div className="avatar" style={{ overflow: 'hidden' }}>
                            <img src={chat.friendImage} style={{ width: '100%', height: '100%', objectFit: 'cover' }} alt="" />
                        </div>
                    ) : (
                        <div className="avatar">{(chat.friendName || '?')[0]?.toUpperCase()}</div>
                    )}
                    {typingUsers.has(chat.friendId?.toUpperCase()) && <div className="online-badge" />}
                </div>
                <div className="chat-row-content">
                    <span className="chat-name-text">{chat.friendName}</span>
                    <div className="chat-status-text">
                        {typingUsers.has(chat.friendId?.toUpperCase()) ? (
                            <span className="typing-shine">typing...</span>
                        ) : (
                            <span>
                                {lastMsg ? (
                                    (lastMsg.fromId?.toLowerCase() === userId?.toLowerCase()) ?
                                        (lastMsg.status === 'read' ? `Read ${timeAgo(lastMsg.timestamp)}` : `Sent ${timeAgo(lastMsg.timestamp)}`)
                                        : timeAgo(lastMsg.timestamp)
                                ) : <span>No messages</span>}
                            </span>
                        )}
                    </div>
                </div>
                <div className="chat-row-meta-col">
                    {chat.unreadCount ? <div className="unread-badge">{chat.unreadCount}</div> : null}
                    <div className="chat-row-icons">
                        {chat.pinned && <Pin size={14} fill="var(--text-secondary)" color="var(--text-secondary)" style={{ transform: 'rotate(45deg)' }} />}
                        {chat.muted && <VolumeX size={14} color="var(--text-secondary)" />}
                    </div>
                </div>
            </motion.div>
        </motion.div>
    );
};

const Home: React.FC<ChatListProps> = ({
    isEditing, setIsEditing, connectionStatus, setView, areChatsLoading,
    chats, userId, openChat, deleteChat, typingUsers, setShowNewChatModal,
    toast, pinChat, toggleMute
}) => {


    // Context Menu State
    const [contextMenu, setContextMenu] = useState<{
        chatId: string;
        rect: DOMRect;
    } | null>(null);

    const handleContextMenu = (e: React.MouseEvent | React.PointerEvent | null, chatId: string, manualRect?: DOMRect) => {
        if (e) e.preventDefault();
        let rect: DOMRect;
        if (manualRect) {
            rect = manualRect;
        } else if (e) {
            const target = e.currentTarget as HTMLElement;
            rect = target.getBoundingClientRect();
        } else {
            return;
        }
        setContextMenu({ chatId, rect });
        try {
            if (navigator.vibrate) navigator.vibrate(50);
        } catch (e) {
            // Ignore haptics error (user gesture requirement)
        }
    };

    const closeContextMenu = () => setContextMenu(null);

    return (
        <div className="home-view-container" onClick={closeContextMenu}>
            {/* Header - Fixed & Absolute */}
            <div className="home-header-fixed">
                <HomeHeader
                    connectionStatus={connectionStatus}
                    setView={setView}
                    setShowNewChatModal={setShowNewChatModal}
                    isEditing={isEditing}
                    setIsEditing={setIsEditing}
                />
            </div>

            {/* Scrollable List Container */}
            <div className="home-scroll-container">
                {areChatsLoading && chats.length === 0 ? (
                    <div style={{ padding: 20 }}>
                        {[1, 2, 3].map(i => (
                            <div key={i} style={{ display: 'flex', alignItems: 'center', marginBottom: 20, opacity: 0.6 }}>
                                <div style={{ width: 50, height: 50, borderRadius: '50%', background: 'rgba(255,255,255,0.05)', marginRight: 15 }} />
                                <div style={{ flex: 1 }}>
                                    <div style={{ width: '40%', height: 12, borderRadius: 6, background: 'rgba(255,255,255,0.05)', marginBottom: 8 }} />
                                    <div style={{ width: '70%', height: 12, borderRadius: 6, background: 'rgba(255,255,255,0.05)' }} />
                                </div>
                            </div>
                        ))}
                    </div>
                ) : chats.length === 0 ? (
                    <div className="empty-state fade-in" style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', flex: 1, minHeight: '60vh' }}>
                        <motion.div
                            animate={{ y: [0, -10, 0] }}
                            transition={{ repeat: Infinity, duration: 3, ease: "easeInOut" }}
                            style={{ marginBottom: 20, opacity: 0.5 }}
                        >
                            <Ghost size={120} strokeWidth={1} color="var(--text-secondary)" />
                        </motion.div>

                        <p style={{ color: 'var(--text-secondary)', fontSize: 18, fontWeight: 500, margin: '0 0 30px 0' }}>
                            Waiting for a friend?
                        </p>

                        <motion.button
                            whileHover={{ scale: 1.05 }}
                            whileTap={{ scale: 0.95 }}
                            onClick={() => setShowNewChatModal(true)}
                            style={{
                                backgroundColor: 'var(--bubble-me)',
                                color: 'white',
                                padding: '14px 32px',
                                borderRadius: '30px',
                                fontSize: '16px',
                                fontWeight: '600',
                                border: 'none',
                                cursor: 'pointer',

                            }}
                        >
                            Start Vibing
                        </motion.button>
                    </div>
                ) : (
                    <div style={{ paddingBottom: 80 }}>
                        {chats.map(c => (
                            <SwipeableChatRow
                                key={c.chatId}
                                chat={c}
                                isEditing={isEditing}
                                userId={userId}
                                typingUsers={typingUsers}
                                onOpen={() => openChat(c)}
                                onDelete={() => deleteChat(c.chatId)}
                                onPin={() => pinChat(c.chatId)}
                                onContextMenu={(e, rect) => handleContextMenu(e, c.chatId, rect)}
                            />
                        ))}
                    </div>
                )}
            </div>

            {toast && (
                <div style={{ position: 'absolute', bottom: 80, left: '50%', transform: 'translateX(-50%)', zIndex: 100 }}>
                    <div className="toast-notification">{toast}</div>
                </div>
            )}

            {/* Context Menu Overlay */}
            <AnimatePresence>
                {contextMenu && (() => {
                    const activeMenuChat = chats.find(c => c.chatId === contextMenu.chatId);
                    if (!activeMenuChat) return null;

                    return (
                        <motion.div
                            initial={{ opacity: 0 }}
                            animate={{ opacity: 1 }}
                            exit={{ opacity: 0 }}
                            className="context-menu-overlay"
                            onClick={closeContextMenu}
                        >
                            <div className="cloned-bubble-wrapper"
                                style={{ top: 0, left: 0, width: '100%', height: '100%' }}>
                                <motion.div
                                    initial={{
                                        top: contextMenu.rect.top,
                                        left: contextMenu.rect.left,
                                        width: contextMenu.rect.width,
                                        height: contextMenu.rect.height,
                                        scale: 1,
                                    }}
                                    animate={{
                                        scale: 1.02,
                                        borderRadius: 12,
                                        boxShadow: '0 20px 60px rgba(0,0,0,0.5)',
                                        zIndex: 2002
                                    }}
                                    exit={{ scale: 1, opacity: 0 }}
                                    className="cloned-bubble-content"
                                    style={{ position: 'absolute', overflow: 'hidden', userSelect: 'none' }}
                                >
                                    <div className="chat-row-card" style={{ padding: '12px 16px', background: 'var(--bg-primary)' }}>
                                        <div className="avatar-container">
                                            {activeMenuChat.friendImage ? (
                                                <div className="avatar" style={{ overflow: 'hidden' }}>
                                                    <img src={activeMenuChat.friendImage} style={{ width: '100%', height: '100%', objectFit: 'cover' }} alt="" />
                                                </div>
                                            ) : (
                                                <div className="avatar">{(activeMenuChat.friendName || '?')[0]?.toUpperCase()}</div>
                                            )}
                                            {typingUsers.has(activeMenuChat.friendId?.toUpperCase()) && <div className="online-badge" />}
                                        </div>
                                        <div className="chat-row-content">
                                            <span className="chat-name-text">{activeMenuChat.friendName}</span>
                                            <div className="chat-status-text">
                                                <span>
                                                    {activeMenuChat.messages[activeMenuChat.messages.length - 1] ? (
                                                        (activeMenuChat.messages[activeMenuChat.messages.length - 1].fromId?.toLowerCase() === userId?.toLowerCase()) ?
                                                            (activeMenuChat.messages[activeMenuChat.messages.length - 1].status === 'read' ? `Read ${timeAgo(activeMenuChat.messages[activeMenuChat.messages.length - 1].timestamp)}` : `Sent ${timeAgo(activeMenuChat.messages[activeMenuChat.messages.length - 1].timestamp)}`)
                                                            : timeAgo(activeMenuChat.messages[activeMenuChat.messages.length - 1].timestamp)
                                                    ) : <span>No messages</span>}
                                                </span>
                                            </div>
                                        </div>
                                        <div className="chat-row-meta-col">
                                            {activeMenuChat.unreadCount ? <div className="unread-badge">{activeMenuChat.unreadCount}</div> : null}
                                            <div className="chat-row-icons">
                                                {activeMenuChat.pinned && <Pin size={14} fill="var(--text-secondary)" color="var(--text-secondary)" style={{ transform: 'rotate(45deg)' }} />}
                                                {activeMenuChat.muted && <VolumeX size={14} color="var(--text-secondary)" />}
                                            </div>
                                        </div>
                                    </div>
                                </motion.div>

                                {/* Menu Items */}
                                <motion.div
                                    initial={{ opacity: 0, scale: 0.95 }}
                                    animate={{ opacity: 1, scale: 1 }}
                                    exit={{ opacity: 0, scale: 0.95 }}
                                    className="context-menu-container"
                                    style={{
                                        position: 'absolute',
                                        width: 240,
                                        top: contextMenu.rect.bottom + 10,
                                        left: (window.innerWidth - 240) / 2
                                    }}
                                    onClick={(e) => e.stopPropagation()}
                                >
                                    <button className="context-menu-item" onClick={() => {
                                        navigator.clipboard.writeText(activeMenuChat.previewLastMessage || activeMenuChat.messages[activeMenuChat.messages.length - 1]?.plaintext || '');
                                        closeContextMenu();
                                    }}>
                                        <Copy size={20} strokeWidth={1.5} /> <span>Copy Value</span>
                                    </button>

                                    <button className="context-menu-item" onClick={(e) => {
                                        e.stopPropagation();
                                        toggleMute(contextMenu.chatId);
                                        closeContextMenu();
                                    }}>
                                        <VolumeX size={20} strokeWidth={1.5} /> <span>{activeMenuChat.muted ? 'Unmute' : 'Mute'}</span>
                                    </button>

                                    <button className="context-menu-item" onClick={(e) => {
                                        e.stopPropagation();
                                        pinChat(contextMenu.chatId);
                                        closeContextMenu();
                                    }}>
                                        <Pin size={20} strokeWidth={1.5} /> <span>{activeMenuChat.pinned ? 'Unpin' : 'Pin'}</span>
                                    </button>

                                    <div className="context-menu-divider" />

                                    <button className="context-menu-item danger" onClick={(e) => {
                                        e.stopPropagation();
                                        if (confirm('Delete this chat?')) deleteChat(contextMenu.chatId);
                                        closeContextMenu();
                                    }}>
                                        <Trash2 size={20} strokeWidth={1.5} /> <span>Delete Chat</span>
                                    </button>
                                </motion.div>
                            </div>
                        </motion.div>
                    );
                })()}
            </AnimatePresence>
        </div>
    );
};

export default Home;
