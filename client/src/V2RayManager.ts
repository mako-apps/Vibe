/**
 * V2RayManager - Advanced Proxy Support for Filtered Regions
 *
 * Supports:
 * - V2Ray/VMess configurations
 * - Shadowsocks configs
 * - Custom proxy URLs
 * - Smart region detection
 * - Auto-fallback between direct and proxy connections
 *
 * For users in Iran and other filtered regions where ngrok/tunnels are blocked
 */

export interface V2RayConfig {
    id: string;
    name: string;
    type: 'vmess' | 'vless' | 'shadowsocks' | 'trojan' | 'custom';
    enabled: boolean;
    // VMess/VLESS config
    address?: string;
    port?: number;
    uuid?: string;
    alterId?: number;
    security?: string;
    network?: 'tcp' | 'ws' | 'grpc' | 'h2';
    path?: string;
    host?: string;
    tls?: boolean;
    sni?: string;
    // Shadowsocks config
    method?: string;
    password?: string;
    // Custom proxy URL (for simple HTTP/SOCKS proxy)
    proxyUrl?: string;
    // Raw config string (vmess://... or ss://...)
    rawConfig?: string;
    // Metadata
    latency?: number;
    lastTested?: number;
    status: 'unknown' | 'online' | 'offline' | 'testing';
    priority: number;
}

export interface RegionInfo {
    country: string;
    countryCode: string;
    isFiltered: boolean;
    requiresProxy: boolean;
    detectedAt: number;
}

// Known filtered regions that need proxy
const FILTERED_REGIONS = ['IR', 'CN', 'RU', 'BY', 'TM', 'KP'];

// Public IP check services (for region detection)
const IP_CHECK_SERVICES = [
    'https://ipapi.co/json/',
    'https://ip-api.com/json/',
    'https://ipinfo.io/json'
];

class V2RayManager {
    private static instance: V2RayManager;
    private configs: V2RayConfig[] = [];
    private regionInfo: RegionInfo | null = null;
    private activeProxy: V2RayConfig | null = null;
    private proxyEnabled: boolean = false;
    private listeners: ((status: string, config: V2RayConfig | null) => void)[] = [];

    private constructor() {
        this.loadConfigs();
        this.loadRegionInfo();
        // Auto-detect region on startup
        this.detectRegion();
    }

    static getInstance(): V2RayManager {
        if (!V2RayManager.instance) {
            V2RayManager.instance = new V2RayManager();
        }
        return V2RayManager.instance;
    }

    // ========== CONFIG MANAGEMENT ==========

    private loadConfigs(): void {
        try {
            const saved = localStorage.getItem('v2ray_configs');
            if (saved) {
                this.configs = JSON.parse(saved);
            }
            this.proxyEnabled = localStorage.getItem('proxy_enabled') === 'true';
        } catch (e) {
            console.warn('[V2Ray] Failed to load configs:', e);
            this.configs = [];
        }
    }

    private saveConfigs(): void {
        try {
            localStorage.setItem('v2ray_configs', JSON.stringify(this.configs));
            localStorage.setItem('proxy_enabled', String(this.proxyEnabled));
        } catch (e) {
            console.warn('[V2Ray] Failed to save configs:', e);
        }
    }

    private loadRegionInfo(): void {
        try {
            const saved = localStorage.getItem('region_info');
            if (saved) {
                this.regionInfo = JSON.parse(saved);
            }
        } catch (e) {
            this.regionInfo = null;
        }
    }

    private saveRegionInfo(): void {
        if (this.regionInfo) {
            localStorage.setItem('region_info', JSON.stringify(this.regionInfo));
        }
    }

    // ========== REGION DETECTION ==========

    async detectRegion(): Promise<RegionInfo | null> {
        // Check cache first (valid for 1 hour)
        if (this.regionInfo && Date.now() - this.regionInfo.detectedAt < 3600000) {
            return this.regionInfo;
        }

        for (const service of IP_CHECK_SERVICES) {
            try {
                const controller = new AbortController();
                const timeout = setTimeout(() => controller.abort(), 5000);

                const res = await fetch(service, {
                    signal: controller.signal,
                    headers: { 'Accept': 'application/json' }
                });
                clearTimeout(timeout);

                if (res.ok) {
                    const data = await res.json();
                    const countryCode = data.country_code || data.countryCode || data.country || '';

                    this.regionInfo = {
                        country: data.country_name || data.country || countryCode,
                        countryCode: countryCode.toUpperCase(),
                        isFiltered: FILTERED_REGIONS.includes(countryCode.toUpperCase()),
                        requiresProxy: FILTERED_REGIONS.includes(countryCode.toUpperCase()),
                        detectedAt: Date.now()
                    };

                    this.saveRegionInfo();
                    console.log('[V2Ray] Region detected:', this.regionInfo);

                    // Auto-enable proxy for filtered regions
                    if (this.regionInfo.requiresProxy && this.configs.length > 0) {
                        this.enableProxy();
                    }

                    return this.regionInfo;
                }
            } catch (e) {
                console.warn(`[V2Ray] Region detection failed for ${service}`);
            }
        }

        // If all services fail, assume filtered (safer)
        this.regionInfo = {
            country: 'Unknown',
            countryCode: 'XX',
            isFiltered: true,
            requiresProxy: true,
            detectedAt: Date.now()
        };
        return this.regionInfo;
    }

    getRegionInfo(): RegionInfo | null {
        return this.regionInfo;
    }

    isInFilteredRegion(): boolean {
        return this.regionInfo?.isFiltered ?? false;
    }

    // ========== PROXY CONFIGURATION ==========

    /**
     * Add a V2Ray/VMess config from URL string
     * Supports: vmess://, vless://, ss://, trojan://
     */
    addConfigFromUrl(configUrl: string, name?: string): V2RayConfig | null {
        try {
            let config: Partial<V2RayConfig> = {
                id: crypto.randomUUID(),
                name: name || 'Imported Config',
                enabled: true,
                status: 'unknown',
                priority: this.configs.length,
                rawConfig: configUrl
            };

            if (configUrl.startsWith('vmess://')) {
                const decoded = atob(configUrl.replace('vmess://', ''));
                const vmessConfig = JSON.parse(decoded);
                config = {
                    ...config,
                    type: 'vmess',
                    name: name || vmessConfig.ps || 'VMess Server',
                    address: vmessConfig.add,
                    port: parseInt(vmessConfig.port),
                    uuid: vmessConfig.id,
                    alterId: parseInt(vmessConfig.aid) || 0,
                    security: vmessConfig.scy || 'auto',
                    network: vmessConfig.net || 'tcp',
                    path: vmessConfig.path || '/',
                    host: vmessConfig.host || '',
                    tls: vmessConfig.tls === 'tls',
                    sni: vmessConfig.sni || vmessConfig.host || ''
                };
            } else if (configUrl.startsWith('vless://')) {
                const url = new URL(configUrl);
                config = {
                    ...config,
                    type: 'vless',
                    name: name || decodeURIComponent(url.hash.slice(1)) || 'VLESS Server',
                    address: url.hostname,
                    port: parseInt(url.port) || 443,
                    uuid: url.username,
                    network: (url.searchParams.get('type') as any) || 'tcp',
                    security: url.searchParams.get('security') || 'none',
                    path: url.searchParams.get('path') || '/',
                    sni: url.searchParams.get('sni') || url.hostname,
                    tls: url.searchParams.get('security') === 'tls'
                };
            } else if (configUrl.startsWith('ss://')) {
                // Shadowsocks format: ss://BASE64(method:password)@host:port#name
                const url = new URL(configUrl);
                let method = '', password = '';

                if (url.username) {
                    // New format: ss://method:password@host:port
                    const decoded = atob(url.username);
                    [method, password] = decoded.split(':');
                } else {
                    // Old format: ss://BASE64@host:port
                    const base64Part = configUrl.replace('ss://', '').split('@')[0];
                    const decoded = atob(base64Part);
                    [method, password] = decoded.split(':');
                }

                config = {
                    ...config,
                    type: 'shadowsocks',
                    name: name || decodeURIComponent(url.hash.slice(1)) || 'Shadowsocks Server',
                    address: url.hostname,
                    port: parseInt(url.port) || 443,
                    method,
                    password
                };
            } else if (configUrl.startsWith('trojan://')) {
                const url = new URL(configUrl);
                config = {
                    ...config,
                    type: 'trojan',
                    name: name || decodeURIComponent(url.hash.slice(1)) || 'Trojan Server',
                    address: url.hostname,
                    port: parseInt(url.port) || 443,
                    password: url.username,
                    sni: url.searchParams.get('sni') || url.hostname
                };
            } else if (configUrl.startsWith('http://') || configUrl.startsWith('https://') || configUrl.startsWith('socks5://')) {
                // Simple HTTP/SOCKS proxy
                config = {
                    ...config,
                    type: 'custom',
                    name: name || 'Custom Proxy',
                    proxyUrl: configUrl
                };
            } else {
                console.error('[V2Ray] Unknown config format');
                return null;
            }

            const fullConfig = config as V2RayConfig;
            this.configs.push(fullConfig);
            this.saveConfigs();
            this.notify('config_added', fullConfig);
            return fullConfig;
        } catch (e) {
            console.error('[V2Ray] Failed to parse config:', e);
            return null;
        }
    }

    /**
     * Add multiple configs from subscription URL
     */
    async addConfigsFromSubscription(subscriptionUrl: string): Promise<V2RayConfig[]> {
        try {
            const res = await fetch(subscriptionUrl);
            if (!res.ok) throw new Error('Failed to fetch subscription');

            const text = await res.text();
            // Subscription is usually base64 encoded list of configs
            const decoded = atob(text.trim());
            const lines = decoded.split('\n').filter(l => l.trim());

            const added: V2RayConfig[] = [];
            for (const line of lines) {
                const config = this.addConfigFromUrl(line.trim());
                if (config) added.push(config);
            }

            console.log(`[V2Ray] Added ${added.length} configs from subscription`);
            return added;
        } catch (e) {
            console.error('[V2Ray] Failed to fetch subscription:', e);
            return [];
        }
    }

    /**
     * Remove a config by ID
     */
    removeConfig(id: string): void {
        this.configs = this.configs.filter(c => c.id !== id);
        if (this.activeProxy?.id === id) {
            this.activeProxy = null;
        }
        this.saveConfigs();
        this.notify('config_removed', null);
    }

    /**
     * Get all configs
     */
    getConfigs(): V2RayConfig[] {
        return [...this.configs];
    }

    /**
     * Update config priority
     */
    setConfigPriority(id: string, priority: number): void {
        const config = this.configs.find(c => c.id === id);
        if (config) {
            config.priority = priority;
            this.saveConfigs();
        }
    }

    /**
     * Toggle config enabled state
     */
    toggleConfig(id: string): void {
        const config = this.configs.find(c => c.id === id);
        if (config) {
            config.enabled = !config.enabled;
            this.saveConfigs();
        }
    }

    // ========== PROXY TESTING ==========

    /**
     * Test a specific proxy config
     */
    async testConfig(config: V2RayConfig): Promise<number> {
        config.status = 'testing';
        this.notify('testing', config);

        const start = Date.now();
        try {
            // For browser environment, we can't directly test V2Ray protocols
            // We'll test via a proxy test endpoint if available
            const testUrl = this.getProxyTestUrl(config);

            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 10000);

            await fetch(testUrl, {
                method: 'HEAD',
                signal: controller.signal,
                mode: 'no-cors' // Allow testing cross-origin
            });
            clearTimeout(timeout);

            config.latency = Date.now() - start;
            config.status = 'online';
            config.lastTested = Date.now();
        } catch (e) {
            config.latency = -1;
            config.status = 'offline';
            config.lastTested = Date.now();
        }

        this.saveConfigs();
        this.notify('tested', config);
        return config.latency ?? -1;
    }

    /**
     * Test all enabled configs
     */
    async testAllConfigs(): Promise<V2RayConfig | null> {
        const enabledConfigs = this.configs.filter(c => c.enabled);

        const results: { config: V2RayConfig; latency: number }[] = [];

        await Promise.all(
            enabledConfigs.map(async (config) => {
                const latency = await this.testConfig(config);
                if (latency > 0) {
                    results.push({ config, latency });
                }
            })
        );

        results.sort((a, b) => a.latency - b.latency);

        if (results.length > 0) {
            this.activeProxy = results[0].config;
            return this.activeProxy;
        }

        return null;
    }

    private getProxyTestUrl(config: V2RayConfig): string {
        // Use the proxy's address for a simple connectivity test
        if (config.proxyUrl) {
            return config.proxyUrl;
        }
        if (config.address) {
            const protocol = config.tls ? 'https' : 'http';
            return `${protocol}://${config.address}:${config.port}`;
        }
        return 'https://www.google.com/generate_204';
    }

    // ========== PROXY CONTROL ==========

    enableProxy(): void {
        this.proxyEnabled = true;
        this.saveConfigs();
        this.notify('proxy_enabled', this.activeProxy);
        console.log('[V2Ray] Proxy enabled');
    }

    disableProxy(): void {
        this.proxyEnabled = false;
        this.saveConfigs();
        this.notify('proxy_disabled', null);
        console.log('[V2Ray] Proxy disabled');
    }

    isProxyEnabled(): boolean {
        return this.proxyEnabled;
    }

    getActiveProxy(): V2RayConfig | null {
        return this.activeProxy;
    }

    setActiveProxy(id: string): void {
        const config = this.configs.find(c => c.id === id);
        if (config) {
            this.activeProxy = config;
            this.notify('proxy_changed', config);
        }
    }

    /**
     * Find best working proxy
     */
    async findBestProxy(): Promise<V2RayConfig | null> {
        if (this.activeProxy && this.activeProxy.status === 'online') {
            const latency = await this.testConfig(this.activeProxy);
            if (latency > 0) return this.activeProxy;
        }

        return await this.testAllConfigs();
    }

    // ========== CONNECTION HELPERS ==========

    /**
     * Get WebSocket URL with proxy support
     * For browser environment, this returns the proxy-aware endpoint
     */
    getProxiedWebSocketUrl(originalUrl: string): string {
        if (!this.proxyEnabled || !this.activeProxy) {
            return originalUrl;
        }

        // For VMess/VLESS with WebSocket transport, modify the URL
        if (this.activeProxy.network === 'ws' && this.activeProxy.address) {
            const protocol = this.activeProxy.tls ? 'wss' : 'ws';
            const path = this.activeProxy.path || '/';
            return `${protocol}://${this.activeProxy.address}:${this.activeProxy.port}${path}`;
        }

        // For custom proxies, return as-is (would need server-side proxy)
        return originalUrl;
    }

    /**
     * Get fetch options with proxy headers
     */
    getProxiedFetchOptions(options: RequestInit = {}): RequestInit {
        if (!this.proxyEnabled || !this.activeProxy) {
            return options;
        }

        // Add proxy-related headers that server can use
        return {
            ...options,
            headers: {
                ...options.headers,
                'X-Proxy-Enabled': 'true',
                'X-Proxy-Type': this.activeProxy.type,
                'X-Proxy-Address': this.activeProxy.address || '',
            }
        };
    }

    /**
     * Export all configs as subscription format
     */
    exportConfigs(): string {
        const configUrls = this.configs
            .filter(c => c.rawConfig)
            .map(c => c.rawConfig)
            .join('\n');
        return btoa(configUrls);
    }

    /**
     * Clear all configs
     */
    clearAllConfigs(): void {
        this.configs = [];
        this.activeProxy = null;
        this.saveConfigs();
        this.notify('configs_cleared', null);
    }

    // ========== EVENT HANDLING ==========

    subscribe(callback: (status: string, config: V2RayConfig | null) => void): () => void {
        this.listeners.push(callback);
        return () => {
            this.listeners = this.listeners.filter(l => l !== callback);
        };
    }

    private notify(status: string, config: V2RayConfig | null): void {
        this.listeners.forEach(cb => cb(status, config));
    }
}

export default V2RayManager;
