
import React, { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Search, X, AlertCircle, Loader2 } from 'lucide-react';
import { getApiUrl } from '../utils';
import './NewChatModal.css';

interface UserInfo {
    userId: string;
    username: string;
    name?: string;
    publicKey: string;
    identityKey?: string;
    profileImage?: string;
}

interface NewChatModalProps {
    isOpen: boolean;
    onClose: () => void;
    onStartChat: (user: UserInfo) => void;
    myId: string;
}

const NewChatModal: React.FC<NewChatModalProps> = ({ isOpen, onClose, onStartChat, myId }) => {
    const [searchId, setSearchId] = useState('');
    const [isSearching, setIsSearching] = useState(false);
    const [searchError, setSearchError] = useState('');

    const handleStartChat = async () => {
        if (!searchId.trim()) return;
        if (searchId.trim() === myId) {
            setSearchError("You cannot chat with yourself");
            return;
        }

        setSearchError('');
        setIsSearching(true);

        try {
            // Determine search type
            const rawInput = searchId.trim();
            const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
            const isUuid = uuidRegex.test(rawInput);
            const isExplicitUsername = rawInput.startsWith('@');

            let endpoint = '';

            if (isExplicitUsername) {
                // @username -> force username search
                const username = rawInput.substring(1).toLowerCase();
                endpoint = `${getApiUrl()}/api/user/name/${username}`;
            } else if (isUuid) {
                // UUID -> direct ID search
                endpoint = `${getApiUrl()}/api/user/${rawInput}`;
            } else {
                // Neither -> assume it's a username without @
                endpoint = `${getApiUrl()}/api/user/name/${rawInput.toLowerCase()}`;
            }

            const res = await fetch(endpoint, {
                headers: { 'ngrok-skip-browser-warning': 'true' }
            });

            if (res.status === 404) {
                setSearchError('User not found');
                setIsSearching(false);
                return;
            }

            if (!res.ok) throw new Error('Network error');

            const data = await res.json();

            // Prevent self-chat
            if (data.userId.toLowerCase() === myId.toLowerCase()) {
                setSearchError("You cannot chat with yourself");
                setIsSearching(false);
                return;
            }

            // User exists, pass full user info
            onStartChat({
                userId: data.userId,
                username: data.username,
                name: data.name,
                publicKey: data.publicKey,
                identityKey: data.identityKey,
                profileImage: data.profileImage
            });
            onClose();
            setSearchId('');
        } catch (e) {
            setSearchError('Connection failed');
        } finally {
            setIsSearching(false);
        }
    };

    return (
        <AnimatePresence>
            {isOpen && (
                <>
                    <motion.div
                        initial={{ opacity: 0 }}
                        animate={{ opacity: 1 }}
                        exit={{ opacity: 0 }}
                        className="modal-overlay"
                        onClick={onClose}
                    />
                    <motion.div
                        initial={{ y: '100%' }}
                        animate={{ y: 0 }}
                        exit={{ y: '100%' }}
                        transition={{ type: 'spring', damping: 25, stiffness: 300 }}
                        className="new-chat-modal"
                        onClick={e => e.stopPropagation()}
                    >
                        <div className="modal-header">
                            <h3>New Chat</h3>
                            <button className="icon-btn" onClick={onClose}><X size={20} /></button>
                        </div>

                        <div className="modal-content">
                            <div className="input-field larger">
                                <Search size={20} color="var(--text-secondary)" />
                                <input
                                    type="text"
                                    placeholder="Enter @username or User ID"
                                    value={searchId}
                                    onChange={e => { setSearchId(e.target.value); setSearchError(''); }}
                                    onKeyDown={e => e.key === 'Enter' && handleStartChat()}
                                    autoFocus
                                />
                            </div>

                            {searchError && (
                                <motion.div
                                    initial={{ opacity: 0, y: -10 }}
                                    animate={{ opacity: 1, y: 0 }}
                                    className="error-message"
                                >
                                    <AlertCircle size={14} /> {searchError}
                                </motion.div>
                            )}

                            <button
                                className="primary-btn large"
                                onClick={handleStartChat}
                                disabled={isSearching || !searchId.trim()}
                                style={{ marginTop: 20 }}
                            >
                                {isSearching ? (
                                    <Loader2 size={20} className="spinner" />
                                ) : (
                                    <>
                                        Start Chat
                                    </>
                                )}
                            </button>

                            <div className="modal-footer-hint">
                                Find friends by their @username or unique ID.
                            </div>
                        </div>
                    </motion.div>
                </>
            )}
        </AnimatePresence>
    );
};

export default NewChatModal;
