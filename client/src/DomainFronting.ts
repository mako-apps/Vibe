/**
 * DomainFronting - Meek-style Traffic Obfuscation
 * 
 * This implements domain fronting similar to how Tor's "Meek" transport works.
 * 
 * HOW IT WORKS:
 * 1. TLS connection to a allowed CDN (e.g., cdn.example.com)
 * 2. HTTP Host header points to our actual server
 * 3. Censors see connection to CDN, not our server
 * 
 * SUPPORTED FRONTS:
 * - Fastly CDN
 * - Cloudflare (when not blocked)
 * - Azure CDN
 * - Amazon CloudFront
 * 
 * This is how Psiphon and Tor Meek bypass censorship!
 */

export interface FrontingConfig {
    name: string;
    // The CDN domain that appears in TLS SNI
    frontDomain: string;
    // Worker/edge endpoint that proxies to our server
    workerUrl: string;
    // Whether this front is currently known to work
    enabled: boolean;
}

// Domain fronting configurations
// These use edge workers/functions to relay traffic
const FRONTING_CONFIGS: FrontingConfig[] = [
    {
        name: 'Vercel Edge',
        frontDomain: 'vercel.app',
        workerUrl: '', // Will be configured
        enabled: true
    },
    {
        name: 'Cloudflare Workers',
        frontDomain: 'workers.dev',
        workerUrl: '', // Will be configured
        enabled: true
    },
    {
        name: 'Netlify Functions',
        frontDomain: 'netlify.app',
        workerUrl: '',
        enabled: true
    }
];

/**
 * Relay Worker Code (deploy to Vercel/Cloudflare/Netlify)
 * This is the code that runs on the edge and relays requests to your actual server
 */
export const RELAY_WORKER_CODE = `
// Deploy this to Vercel as an API route: /api/relay.js
// Or to Cloudflare Workers

const ACTUAL_SERVER = process.env.ACTUAL_SERVER_URL || 'https://your-ngrok-url.ngrok.app';

export default async function handler(req, res) {
    try {
        const targetUrl = ACTUAL_SERVER + req.url.replace('/api/relay', '');
        
        const response = await fetch(targetUrl, {
            method: req.method,
            headers: {
                ...req.headers,
                'Host': new URL(ACTUAL_SERVER).host,
                'X-Forwarded-For': req.headers['x-forwarded-for'] || req.socket?.remoteAddress
            },
            body: req.method !== 'GET' && req.method !== 'HEAD' ? req.body : undefined
        });
        
        const data = await response.text();
        
        // Forward all headers
        for (const [key, value] of response.headers.entries()) {
            if (!['content-encoding', 'transfer-encoding'].includes(key.toLowerCase())) {
                res.setHeader(key, value);
            }
        }
        
        res.status(response.status).send(data);
    } catch (error) {
        res.status(502).json({ error: 'Relay failed', message: error.message });
    }
}
`;

/**
 * Cloudflare Worker Version
 */
export const CLOUDFLARE_WORKER_CODE = `
// Deploy to Cloudflare Workers

const ACTUAL_SERVER = 'https://your-ngrok-url.ngrok.app';

export default {
    async fetch(request) {
        const url = new URL(request.url);
        const targetUrl = ACTUAL_SERVER + url.pathname + url.search;
        
        const modifiedRequest = new Request(targetUrl, {
            method: request.method,
            headers: request.headers,
            body: request.body,
            redirect: 'follow'
        });
        
        try {
            const response = await fetch(modifiedRequest);
            
            // Clone response with CORS headers
            const modifiedResponse = new Response(response.body, response);
            modifiedResponse.headers.set('Access-Control-Allow-Origin', '*');
            modifiedResponse.headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
            modifiedResponse.headers.set('Access-Control-Allow-Headers', '*');
            
            return modifiedResponse;
        } catch (error) {
            return new Response(JSON.stringify({ error: 'Relay failed' }), {
                status: 502,
                headers: { 'Content-Type': 'application/json' }
            });
        }
    }
};
`;

class DomainFronting {
    private static instance: DomainFronting;
    private configs: FrontingConfig[] = [];
    private currentFront: FrontingConfig | null = null;

    private constructor() {
        this.loadConfigs();
    }

    static getInstance(): DomainFronting {
        if (!DomainFronting.instance) {
            DomainFronting.instance = new DomainFronting();
        }
        return DomainFronting.instance;
    }

    /**
     * Load fronting configurations from storage
     */
    private loadConfigs(): void {
        const saved = localStorage.getItem('fronting_configs');
        if (saved) {
            try {
                this.configs = JSON.parse(saved);
            } catch {
                this.configs = [...FRONTING_CONFIGS];
            }
        } else {
            this.configs = [...FRONTING_CONFIGS];
        }
    }

    /**
     * Save configurations
     */
    private saveConfigs(): void {
        localStorage.setItem('fronting_configs', JSON.stringify(this.configs));
    }

    /**
     * Add a new fronting configuration
     */
    addFront(config: FrontingConfig): void {
        const existing = this.configs.findIndex(c => c.name === config.name);
        if (existing >= 0) {
            this.configs[existing] = config;
        } else {
            this.configs.push(config);
        }
        this.saveConfigs();
    }

    /**
     * Set the worker URL for a front
     */
    setWorkerUrl(name: string, url: string): void {
        const config = this.configs.find(c => c.name === name);
        if (config) {
            config.workerUrl = url;
            config.enabled = true;
            this.saveConfigs();
        }
    }

    /**
     * Test a fronting configuration
     */
    async testFront(config: FrontingConfig): Promise<boolean> {
        if (!config.workerUrl) return false;

        try {
            const response = await fetch(`${config.workerUrl}/api/vapid-key`, {
                method: 'GET',
                headers: {
                    'ngrok-skip-browser-warning': 'true'
                },
                signal: AbortSignal.timeout(10000)
            });

            return response.ok;
        } catch {
            return false;
        }
    }

    /**
     * Find a working front
     */
    async findWorkingFront(): Promise<FrontingConfig | null> {
        console.log('[FRONTING] Testing domain fronts...');

        for (const config of this.configs) {
            if (!config.enabled || !config.workerUrl) continue;

            console.log(`[FRONTING] Testing ${config.name}...`);
            const works = await this.testFront(config);

            if (works) {
                console.log(`[FRONTING] ${config.name} is working!`);
                this.currentFront = config;
                return config;
            } else {
                console.log(`[FRONTING] ${config.name} failed`);
            }
        }

        this.currentFront = null;
        return null;
    }

    /**
     * Get the current active front
     */
    getCurrentFront(): FrontingConfig | null {
        return this.currentFront;
    }

    /**
     * Get all configurations
     */
    getConfigs(): FrontingConfig[] {
        return [...this.configs];
    }

    /**
     * Make a request through the current front
     */
    async fetch(path: string, options: RequestInit = {}): Promise<Response> {
        if (!this.currentFront?.workerUrl) {
            throw new Error('No working front available');
        }

        const url = `${this.currentFront.workerUrl}${path}`;
        return fetch(url, {
            ...options,
            headers: {
                ...options.headers,
                'ngrok-skip-browser-warning': 'true'
            }
        });
    }
}

export default DomainFronting;

/**
 * SETUP INSTRUCTIONS:
 * 
 * 1. VERCEL (Recommended - Free):
 *    - Create a new Vercel project
 *    - Add file: api/relay.js with RELAY_WORKER_CODE content
 *    - Set ACTUAL_SERVER_URL in Vercel environment variables
 *    - Deploy: vercel deploy --prod
 *    - Your front URL: https://your-project.vercel.app/api/relay
 * 
 * 2. CLOUDFLARE WORKERS (Free tier):
 *    - Create a new Worker in Cloudflare dashboard
 *    - Paste CLOUDFLARE_WORKER_CODE
 *    - Update ACTUAL_SERVER with your ngrok URL
 *    - Deploy
 *    - Your front URL: https://your-worker.workers.dev
 * 
 * 3. NETLIFY FUNCTIONS:
 *    - Create netlify/functions/relay.js
 *    - Use RELAY_WORKER_CODE (adapted for Netlify)
 *    - Deploy
 * 
 * USAGE IN APP:
 * 
 * const fronting = DomainFronting.getInstance();
 * fronting.setWorkerUrl('Vercel Edge', 'https://your-project.vercel.app/api/relay');
 * 
 * const front = await fronting.findWorkingFront();
 * if (front) {
 *     // Use fronting.fetch() instead of regular fetch
 *     const response = await fronting.fetch('/api/messages', { method: 'POST', body: data });
 * }
 */
