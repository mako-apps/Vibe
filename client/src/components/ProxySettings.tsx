/**
 * ProxySettings - UI for managing V2Ray/proxy configurations
 *
 * Features:
 * - Add V2Ray configs (vmess://, vless://, ss://, trojan://)
 * - Import from subscription URL
 * - Test proxy latency
 * - Enable/disable proxy mode
 * - View region detection status
 */

import React, { useState, useEffect } from 'react';
import ProxyManager from '../ProxyManager';
import type { V2RayConfig, RegionInfo } from '../V2RayManager';
import './ProxySettings.css';

interface ProxySettingsProps {
    onClose: () => void;
}

const ProxySettings: React.FC<ProxySettingsProps> = ({ onClose }) => {
    const [configs, setConfigs] = useState<V2RayConfig[]>([]);
    const [regionInfo, setRegionInfo] = useState<RegionInfo | null>(null);
    const [proxyEnabled, setProxyEnabled] = useState(false);
    const [newConfigUrl, setNewConfigUrl] = useState('');
    const [subscriptionUrl, setSubscriptionUrl] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [isTesting, setIsTesting] = useState(false);
    const [error, setError] = useState('');
    const [success, setSuccess] = useState('');

    const proxyManager = ProxyManager.getInstance();
    const v2rayManager = proxyManager.getV2RayManager();

    useEffect(() => {
        loadData();
    }, []);

    const loadData = async () => {
        setConfigs(v2rayManager.getConfigs());
        setProxyEnabled(v2rayManager.isProxyEnabled());

        const region = await v2rayManager.detectRegion();
        setRegionInfo(region);
    };

    const handleAddConfig = () => {
        if (!newConfigUrl.trim()) {
            setError('Please enter a config URL');
            return;
        }

        setError('');
        const config = v2rayManager.addConfigFromUrl(newConfigUrl.trim());

        if (config) {
            setSuccess(`Added: ${config.name}`);
            setNewConfigUrl('');
            setConfigs(v2rayManager.getConfigs());
            setTimeout(() => setSuccess(''), 3000);
        } else {
            setError('Invalid config format. Supported: vmess://, vless://, ss://, trojan://');
        }
    };

    const handleImportSubscription = async () => {
        if (!subscriptionUrl.trim()) {
            setError('Please enter a subscription URL');
            return;
        }

        setIsLoading(true);
        setError('');

        try {
            const added = await v2rayManager.addConfigsFromSubscription(subscriptionUrl.trim());
            if (added.length > 0) {
                setSuccess(`Imported ${added.length} configs`);
                setSubscriptionUrl('');
                setConfigs(v2rayManager.getConfigs());
            } else {
                setError('No valid configs found in subscription');
            }
        } catch (e) {
            setError('Failed to import subscription');
        }

        setIsLoading(false);
        setTimeout(() => setSuccess(''), 3000);
    };

    const handleTestConfig = async (config: V2RayConfig) => {
        setIsTesting(true);
        await v2rayManager.testConfig(config);
        setConfigs(v2rayManager.getConfigs());
        setIsTesting(false);
    };

    const handleTestAll = async () => {
        setIsTesting(true);
        await v2rayManager.testAllConfigs();
        setConfigs(v2rayManager.getConfigs());
        setIsTesting(false);
    };

    const handleRemoveConfig = (id: string) => {
        v2rayManager.removeConfig(id);
        setConfigs(v2rayManager.getConfigs());
    };

    const handleToggleProxy = () => {
        if (proxyEnabled) {
            proxyManager.disableProxyMode();
        } else {
            proxyManager.enableProxyMode();
        }
        setProxyEnabled(!proxyEnabled);
    };

    const handleSetActive = (id: string) => {
        v2rayManager.setActiveProxy(id);
        setConfigs(v2rayManager.getConfigs());
    };

    const getStatusColor = (status: string) => {
        switch (status) {
            case 'online': return '#4CAF50';
            case 'offline': return '#f44336';
            case 'testing': return '#FF9800';
            default: return '#9E9E9E';
        }
    };

    const getStatusIcon = (status: string) => {
        switch (status) {
            case 'online': return '✓';
            case 'offline': return '✗';
            case 'testing': return '...';
            default: return '?';
        }
    };

    return (
        <div className="proxy-settings-overlay">
            <div className="proxy-settings-modal">
                <div className="proxy-settings-header">
                    <h2>Proxy Settings</h2>
                    <button className="close-btn" onClick={onClose}>×</button>
                </div>

                {/* Region Detection */}
                <div className="proxy-section">
                    <h3>Region Detection</h3>
                    <div className="region-info">
                        {regionInfo ? (
                            <>
                                <div className="region-item">
                                    <span>Country:</span>
                                    <strong>{regionInfo.country} ({regionInfo.countryCode})</strong>
                                </div>
                                <div className="region-item">
                                    <span>Status:</span>
                                    <strong style={{ color: regionInfo.isFiltered ? '#f44336' : '#4CAF50' }}>
                                        {regionInfo.isFiltered ? 'Filtered Region' : 'Unfiltered'}
                                    </strong>
                                </div>
                                {regionInfo.isFiltered && (
                                    <p className="region-warning">
                                        Your region requires proxy for optimal connection.
                                        Add V2Ray configs below.
                                    </p>
                                )}
                            </>
                        ) : (
                            <p>Detecting region...</p>
                        )}
                    </div>
                </div>

                {/* Proxy Toggle */}
                <div className="proxy-section">
                    <div className="proxy-toggle">
                        <span>Enable Proxy Mode</span>
                        <label className="switch">
                            <input
                                type="checkbox"
                                checked={proxyEnabled}
                                onChange={handleToggleProxy}
                            />
                            <span className="slider"></span>
                        </label>
                    </div>
                    <p className="hint">
                        {proxyEnabled
                            ? 'Traffic will route through proxy servers'
                            : 'Direct connection (faster for unfiltered regions)'}
                    </p>
                </div>

                {/* Add Config */}
                <div className="proxy-section">
                    <h3>Add Proxy Config</h3>
                    <div className="input-group">
                        <input
                            type="text"
                            placeholder="vmess://... or vless://... or ss://..."
                            value={newConfigUrl}
                            onChange={(e) => setNewConfigUrl(e.target.value)}
                        />
                        <button onClick={handleAddConfig} disabled={isLoading}>
                            Add
                        </button>
                    </div>

                    <div className="input-group" style={{ marginTop: 10 }}>
                        <input
                            type="text"
                            placeholder="Subscription URL (optional)"
                            value={subscriptionUrl}
                            onChange={(e) => setSubscriptionUrl(e.target.value)}
                        />
                        <button onClick={handleImportSubscription} disabled={isLoading}>
                            {isLoading ? 'Importing...' : 'Import'}
                        </button>
                    </div>

                    {error && <p className="error-msg">{error}</p>}
                    {success && <p className="success-msg">{success}</p>}
                </div>

                {/* Config List */}
                <div className="proxy-section">
                    <div className="section-header">
                        <h3>Proxy Servers ({configs.length})</h3>
                        {configs.length > 0 && (
                            <button
                                className="test-all-btn"
                                onClick={handleTestAll}
                                disabled={isTesting}
                            >
                                {isTesting ? 'Testing...' : 'Test All'}
                            </button>
                        )}
                    </div>

                    {configs.length === 0 ? (
                        <p className="no-configs">No proxy configs added yet</p>
                    ) : (
                        <div className="config-list">
                            {configs.map((config) => (
                                <div key={config.id} className="config-item">
                                    <div className="config-info">
                                        <div className="config-name">
                                            <span
                                                className="status-dot"
                                                style={{ backgroundColor: getStatusColor(config.status) }}
                                            >
                                                {getStatusIcon(config.status)}
                                            </span>
                                            {config.name}
                                        </div>
                                        <div className="config-details">
                                            <span className="config-type">{config.type.toUpperCase()}</span>
                                            {config.address && (
                                                <span className="config-address">
                                                    {config.address}:{config.port}
                                                </span>
                                            )}
                                            {config.latency && config.latency > 0 && (
                                                <span className="config-latency">{config.latency}ms</span>
                                            )}
                                        </div>
                                    </div>
                                    <div className="config-actions">
                                        <button
                                            className="action-btn test"
                                            onClick={() => handleTestConfig(config)}
                                            disabled={isTesting}
                                            title="Test"
                                        >
                                            Test
                                        </button>
                                        <button
                                            className="action-btn use"
                                            onClick={() => handleSetActive(config.id)}
                                            title="Use this proxy"
                                        >
                                            Use
                                        </button>
                                        <button
                                            className="action-btn delete"
                                            onClick={() => handleRemoveConfig(config.id)}
                                            title="Remove"
                                        >
                                            ×
                                        </button>
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                </div>

                {/* Help */}
                <div className="proxy-section help">
                    <h3>Supported Formats</h3>
                    <ul>
                        <li><code>vmess://...</code> - V2Ray VMess protocol</li>
                        <li><code>vless://...</code> - V2Ray VLESS protocol</li>
                        <li><code>ss://...</code> - Shadowsocks</li>
                        <li><code>trojan://...</code> - Trojan protocol</li>
                    </ul>
                    <p className="hint">
                        Get free configs from v2ray-free-proxy channels or purchase from providers.
                    </p>
                </div>
            </div>
        </div>
    );
};

export default ProxySettings;
