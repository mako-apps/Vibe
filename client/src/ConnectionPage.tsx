import React, { useState, useEffect } from 'react';
import {
    ArrowLeft, Plus, Check, Loader2
} from 'lucide-react';
import { motion, AnimatePresence } from 'framer-motion';
import ConnectionManager from './ConnectionManager';
import ProxyManager, { ServerEndpoint } from './ProxyManager';
import V2RayManager from './V2RayManager';
import './ConnectionPage.css';

interface ConnectionPageProps {
    onBack: () => void;
}

const ConnectionPage: React.FC<ConnectionPageProps> = ({ onBack }) => {
    const connManager = ConnectionManager.getInstance();
    const proxyManager = ProxyManager.getInstance();
    const [v2rayManager] = useState(V2RayManager.getInstance());

    const [status, setStatus] = useState(connManager.getStatus().status);
    const [latency, setLatency] = useState(connManager.getStatus().latency);
    const [currentEndpoint, setCurrentEndpoint] = useState<ServerEndpoint | null>(connManager.getCurrentEndpoint());
    const [regionInfo, setRegionInfo] = useState(v2rayManager.getRegionInfo());

    // Input States
    const [showAddServer, setShowAddServer] = useState(false);
    const [newServerType, setNewServerType] = useState<'v2ray' | 'custom'>('v2ray');
    const [newServerInput, setNewServerInput] = useState('');
    const [newServerName, setNewServerName] = useState('');

    useEffect(() => {
        const unsubConn = connManager.subscribe((s, lat, ep) => {
            setStatus(s);
            setLatency(lat);
            if (ep) setCurrentEndpoint(ep);
        });

        const unsubV2Ray = v2rayManager.subscribe(() => {
            setRegionInfo(v2rayManager.getRegionInfo());
        });

        v2rayManager.detectRegion().then(info => setRegionInfo(info));

        if (connManager.getStatus().status === 'connected') {
            const ep = connManager.getCurrentEndpoint();
            if (ep) proxyManager.testEndpoint(ep).then(l => setLatency(l));
        }

        return () => {
            unsubConn();
            unsubV2Ray();
        };
    }, []);

    const handleAddServer = () => {
        if (!newServerInput.trim()) return;

        if (newServerType === 'v2ray') {
            const added = proxyManager.addV2RayConfig(newServerInput, newServerName || 'Custom V2Ray');
            if (added && status !== 'connected') connManager.connect();
        } else {
            proxyManager.addEndpoint(newServerInput, newServerName || 'Custom Server', 'direct');
            if (status !== 'connected') connManager.setServerUrl(newServerInput);
        }

        setNewServerInput('');
        setNewServerName('');
        setShowAddServer(false);
    };

    return (
        <motion.div
            className="cp-container"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2 }}
        >
            {/* Header Deck - Fixed Top */}
            <div className="cp-header-mask" />
            <header className="cp-header-deck">
                <button className="cp-icon-btn" onClick={onBack}>
                    <ArrowLeft size={20} />
                </button>
                <div className="cp-header-title-container">
                    <span className="cp-header-title">Network</span>
                </div>
                <button className="cp-icon-btn" onClick={() => setShowAddServer(!showAddServer)}>
                    <Plus size={20} />
                </button>
            </header>

            {/* Scrollable Content */}
            <div className="cp-content-scroll">

                {/* INFO Section at Top */}
                <div className="cp-section-label">INFO</div>
                <div className="cp-list-group">
                    <div className="cp-list-item" style={{ cursor: 'default' }}>
                        <div className="cp-item-text">Status</div>
                        <div className={`cp-status-pill-inline ${status}`}>
                            {status === 'connected' ? (
                                <>
                                    <Check size={12} strokeWidth={3} />
                                    <span>Connected</span>
                                </>
                            ) : status === 'connecting' ? (
                                <>
                                    <Loader2 size={12} className="animate-spin" />
                                    <span>Connecting</span>
                                </>
                            ) : (
                                <span>Disconnected</span>
                            )}
                        </div>
                    </div>
                    <div className="cp-list-item" style={{ cursor: 'default' }}>
                        <div className="cp-item-text">Latency</div>
                        <div className="cp-item-meta">{latency > 0 ? `${latency}ms` : '—'}</div>
                    </div>
                    <div className="cp-list-item" style={{ cursor: 'default' }}>
                        <div className="cp-item-text">Region</div>
                        <div className="cp-item-meta">{regionInfo?.country || 'Unknown'}</div>
                    </div>
                </div>

                {/* Add Server Form */}
                <AnimatePresence>
                    {showAddServer && (
                        <motion.div
                            className="cp-add-form"
                            initial={{ height: 0, opacity: 0, marginBottom: 0 }}
                            animate={{ height: 'auto', opacity: 1, marginBottom: 20 }}
                            exit={{ height: 0, opacity: 0, marginBottom: 0 }}
                        >
                            <input
                                placeholder={newServerType === 'v2ray' ? "vmess://... or vless://..." : "https://example.com"}
                                value={newServerInput}
                                onChange={e => setNewServerInput(e.target.value)}
                                className="cp-clean-input"
                                autoFocus
                            />
                            <div className="cp-toggle-row">
                                <span
                                    className={`cp-toggle-opt ${newServerType === 'v2ray' ? 'active' : ''}`}
                                    onClick={() => setNewServerType('v2ray')}
                                >V2Ray Proxy</span>
                                <span
                                    className={`cp-toggle-opt ${newServerType === 'custom' ? 'active' : ''}`}
                                    onClick={() => setNewServerType('custom')}
                                >Direct Server</span>
                            </div>
                            <button className="cp-action-btn" onClick={handleAddServer}>Add Connection</button>
                        </motion.div>
                    )}
                </AnimatePresence>

                {/* Servers List */}
                <div className="cp-section-label">SERVERS</div>
                <div className="cp-list-group">
                    {Array.from(new Map(proxyManager.getEndpoints().map(ep => [ep.url, ep])).values())
                        .slice(0, 50)
                        .map((ep, i) => {
                            const isActive = currentEndpoint?.url === ep.url;
                            return (
                                <div
                                    key={ep.url}
                                    className={`cp-list-item ${isActive ? 'active' : ''}`}
                                    onClick={() => connManager.switchToEndpoint(ep)}
                                >
                                    <div className="cp-item-text">{`Server ${i + 1}`}</div>
                                    {isActive && (
                                        <div className="cp-check-indicator">
                                            <Check size={18} />
                                        </div>
                                    )}
                                </div>
                            );
                        })}
                </div>

                <button className="cp-reset-link" onClick={() => {
                    if (confirm('Reset all network settings?')) {
                        localStorage.removeItem('proxy_endpoints');
                        connManager.forceReconnect();
                    }
                }}>
                    Reset Network Settings
                </button>
            </div>
        </motion.div>
    );
};

export default ConnectionPage;
