// Industry-Standard Audio Player with Web Audio API - Optimized for Real-time Streaming
export class SimpleAudioPlayer {
    private static instance: SimpleAudioPlayer;
    private audioContext: AudioContext | null = null;
    private isUnlocked = false;



    private currentSource: AudioBufferSourceNode | null = null;
    private gainNode: GainNode | null = null;






    // Track playback time for progress bars
    public startTime: number = 0;

    public isPlaying: boolean = false;


    static getInstance(): SimpleAudioPlayer {
        if (!SimpleAudioPlayer.instance) {
            SimpleAudioPlayer.instance = new SimpleAudioPlayer();
            SimpleAudioPlayer.instance.initializeAudioContext();
            SimpleAudioPlayer.instance.startQueueProcessor();
            SimpleAudioPlayer.instance.addUnlockListeners(); // Global listener setup
        }
        return SimpleAudioPlayer.instance;
    }

    private addUnlockListeners() {
        const unlock = () => {
            this.unlockAudio();
            // We can remove listeners if successful, or keep trying until verified unlocked
            if (this.audioContext?.state === 'running') {
                window.removeEventListener('click', unlock);
                window.removeEventListener('touchstart', unlock);
                window.removeEventListener('keydown', unlock);
            }
        };
        window.addEventListener('click', unlock);
        window.addEventListener('touchstart', unlock);
        window.addEventListener('keydown', unlock);
    }

    // Initialize AudioContext immediately (not just on unlock)
    private initializeAudioContext(): void {
        if (!this.audioContext) {
            try {
                const AudioContext = window.AudioContext || (window as any).webkitAudioContext;
                this.audioContext = new AudioContext();
                this.gainNode = this.audioContext.createGain();
                this.gainNode.connect(this.audioContext.destination);
            } catch (error) {
                console.error('🚨 [INIT] Failed to create AudioContext:', error);
            }
        }
    }

    async unlockAudio(): Promise<boolean> {
        if (this.isUnlocked && this.audioContext?.state === 'running') return true;

        try {
            if (!this.audioContext) this.initializeAudioContext();

            if (this.audioContext?.state === 'suspended') {
                await this.audioContext.resume();
            }

            // Play silent buffer to force unlock on stricter browsers (iOS)
            const buffer = this.audioContext!.createBuffer(1, 1, 22050);
            const source = this.audioContext!.createBufferSource();
            source.buffer = buffer;
            source.connect(this.audioContext!.destination);
            source.start(0);

            this.isUnlocked = true;
            return true;
        } catch (e) {
            console.warn("Unlock attempt failed", e);
            return false;
        }
    }

    // NEW METHOD: Play from URL (Blob or Remote)
    async playUrl(url: string, onEnded?: () => void, onProgress?: (time: number, duration: number) => void): Promise<void> {
        try {
            await this.unlockAudio();

            // Stop previous if playing
            this.stop();

            const response = await fetch(url);
            const arrayBuffer = await response.arrayBuffer();
            const audioBuffer = await this.audioContext!.decodeAudioData(arrayBuffer);

            this.currentSource = this.audioContext!.createBufferSource();
            this.currentSource.buffer = audioBuffer;
            this.currentSource.connect(this.gainNode!);

            this.currentSource.onended = () => {
                this.isPlaying = false;
                if (onEnded) onEnded();
            };

            this.startTime = this.audioContext!.currentTime;
            this.currentSource.start(0);
            this.isPlaying = true;

            // Progress Loop
            const loop = () => {
                if (!this.isPlaying) return;
                const elapsed = this.audioContext!.currentTime - this.startTime;
                if (onProgress) onProgress(Math.min(elapsed, audioBuffer.duration), audioBuffer.duration);
                if (elapsed < audioBuffer.duration) requestAnimationFrame(loop);
            };
            requestAnimationFrame(loop);

        } catch (e) {
            console.error("Play URL failed", e);
        }
    }

    stop() {
        if (this.currentSource) {
            try { this.currentSource.stop(); } catch (e) { }
            this.currentSource = null;
        }
        this.isPlaying = false;
    }

    private startQueueProcessor(): void {
        // Placeholder
    }
}
export default SimpleAudioPlayer;
