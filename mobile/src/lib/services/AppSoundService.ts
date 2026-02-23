import { Platform } from 'react-native';
import { Audio } from 'expo-av';

class AppSoundService {
  private ringSound: Audio.Sound | null = null;
  private readyCueSound: Audio.Sound | null = null;
  private audioModeConfigured = false;
  private ringActive = false;
  private ringBusy: Promise<void> | null = null;
  private lastReadyCueAt = 0;

  private async ensureAudioMode(): Promise<void> {
    if (this.audioModeConfigured || Platform.OS === 'web') return;
    try {
      await Audio.setAudioModeAsync({
        playsInSilentModeIOS: true,
        staysActiveInBackground: false,
      });
      this.audioModeConfigured = true;
    } catch {
      // Ignore audio mode failures; playback may still work.
    }
  }

  private async ensureRingSound(): Promise<Audio.Sound | null> {
    if (Platform.OS === 'web') return null;
    if (this.ringSound) return this.ringSound;
    await this.ensureAudioMode();
    try {
      const { sound } = await Audio.Sound.createAsync(
        require('../../../assets/sounds/freesound_community-phone-call-14472 (2).mp3'),
        {
          isLooping: true,
          shouldPlay: false,
          volume: 1.0,
        }
      );
      this.ringSound = sound;
      return sound;
    } catch (error) {
      console.warn('[AppSoundService] Failed to load ring sound', error);
      return null;
    }
  }

  private async ensureReadyCueSound(): Promise<Audio.Sound | null> {
    if (Platform.OS === 'web') return null;
    if (this.readyCueSound) return this.readyCueSound;
    await this.ensureAudioMode();
    try {
      const { sound } = await Audio.Sound.createAsync(
        require('../../../assets/sounds/47313572-intro-sound-1-269293.mp3'),
        {
          shouldPlay: false,
          volume: 0.85,
        }
      );
      this.readyCueSound = sound;
      return sound;
    } catch (error) {
      console.warn('[AppSoundService] Failed to load ready cue sound', error);
      return null;
    }
  }

  async startIncomingRingLoop(): Promise<void> {
    if (Platform.OS === 'web') return;
    this.ringActive = true;
    if (this.ringBusy) {
      await this.ringBusy;
      return;
    }

    this.ringBusy = (async () => {
      const sound = await this.ensureRingSound();
      if (!sound || !this.ringActive) return;
      try {
        await sound.setPositionAsync(0);
        await sound.playAsync();
      } catch (error) {
        console.warn('[AppSoundService] Failed to start ring loop', error);
      }
    })();

    try {
      await this.ringBusy;
    } finally {
      this.ringBusy = null;
    }
  }

  async stopIncomingRingLoop(): Promise<void> {
    this.ringActive = false;
    const sound = this.ringSound;
    if (!sound) return;
    try {
      const status = await sound.getStatusAsync();
      if (status.isLoaded && status.isPlaying) {
        await sound.stopAsync();
      }
      if (status.isLoaded) {
        await sound.setPositionAsync(0);
      }
    } catch {
      // Ignore stop failures.
    }
  }

  async playSocketReadyCue(): Promise<void> {
    if (Platform.OS === 'web') return;
    const now = Date.now();
    if (now - this.lastReadyCueAt < 900) return;
    this.lastReadyCueAt = now;

    const sound = await this.ensureReadyCueSound();
    if (!sound) return;
    try {
      await sound.stopAsync().catch(() => undefined);
      await sound.setPositionAsync(0);
      await sound.playAsync();
    } catch (error) {
      console.warn('[AppSoundService] Failed to play ready cue', error);
    }
  }
}

export default new AppSoundService();
