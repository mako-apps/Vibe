import React from 'react';
import { Wifi, WifiOff, Pencil, Settings } from 'lucide-react';

interface HomeHeaderProps {
    connectionStatus: string;
    setView: (view: string) => void;
    setShowNewChatModal: (show: boolean) => void;
    isEditing: boolean;
    setIsEditing: (is: boolean) => void;
}

const HomeHeader: React.FC<HomeHeaderProps> = ({
    connectionStatus, setView, setShowNewChatModal, isEditing, setIsEditing
}) => {
    return (
        <div className="header-mask-container no-blur">
            <header className="main-header home-header">
                {/* Left: Edit Mode */}
                <div className="header-left-area" style={{ position: 'absolute', left: 0, height: '100%', display: 'flex', alignItems: 'center', paddingLeft: 16 }}>
                    <div className="glass-btn-container">
                        <button
                            onClick={() => setIsEditing(!isEditing)}
                            className="glass-text-btn"
                        >
                            {isEditing ? 'Done' : 'Edit'}
                        </button>
                    </div>
                </div>

                {/* Center: Title */}
                <div className="header-center-area no-glass">
                    <h2 className="header-title">Chats</h2>
                </div>

                {/* Right: Actions */}
                <div className="header-glass-group">
                    <button
                        className={`glass-btn ${connectionStatus === 'connecting' ? 'wifi-pulse' : ''}`}
                        onClick={() => setView('connection')}
                        title={connectionStatus.toUpperCase()}
                    >
                        {connectionStatus === 'connected' ? (
                            <Wifi size={18} color="#10b981" />
                        ) : connectionStatus === 'disconnected' ? (
                            <WifiOff size={18} color="#ef4444" />
                        ) : (
                            <Wifi size={18} color="#fbbf24" style={{ opacity: 0.7 }} />
                        )}
                    </button>

                    <div className="glass-divider" />

                    <button className="glass-btn" onClick={() => setShowNewChatModal(true)}>
                        <Pencil size={18} />
                    </button>

                    <div className="glass-divider" />

                    <button className="glass-btn" onClick={() => setView('profile')}>
                        <Settings size={18} />
                    </button>
                </div>
            </header>
        </div>
    );
};

export default HomeHeader;
