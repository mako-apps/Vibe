
import React, { useState, useEffect, useMemo } from 'react';
import { Play, Pause } from 'lucide-react';
import SimpleAudioPlayer from '../SimpleAudioPlayer';

interface VoiceBubbleProps {
    src: string;
}

const VoiceBubble: React.FC<VoiceBubbleProps> = ({ src }) => {
    const [isPlaying, setIsPlaying] = useState(false);
    const [progress, setProgress] = useState(0);
    const [duration, setDuration] = useState(0);
    const [currentTime, setCurrentTime] = useState(0);

    // Fake Waveform
    const bars = useMemo(() => {
        return Array.from({ length: 30 }, () => Math.floor(Math.random() * 12) + 4);
    }, []); // Static for the lifetime

    useEffect(() => {
        if (!src) return;
        const audio = new Audio(src);
        audio.preload = 'metadata';

        const onDur = () => {
            const d = audio.duration;
            if (d !== Infinity && !isNaN(d)) {
                setDuration(d);
            }
        };

        // Force load
        audio.load();
        audio.addEventListener('loadedmetadata', onDur);
        audio.addEventListener('durationchange', onDur);
        return () => {
            audio.removeEventListener('loadedmetadata', onDur);
            audio.removeEventListener('durationchange', onDur);
            audio.src = '';
        };
    }, [src]);

    const togglePlay = () => {
        const player = SimpleAudioPlayer.getInstance();

        if (isPlaying) {
            player.stop();
            setIsPlaying(false);
        } else {
            setIsPlaying(true);
            player.playUrl(src,
                () => { // On Ended
                    setIsPlaying(false);
                    setProgress(0);
                    setCurrentTime(0);
                },
                (curr, tot) => { // On Progress
                    setCurrentTime(curr);
                    if (tot > 0) {
                        setDuration(tot); // Ensure duration is captured
                        setProgress((curr / tot) * 100);
                    }
                }
            );
        }
    };

    const formatTime = (t: number) => {
        if (!t || isNaN(t) || t === Infinity) return '0:00';
        const m = Math.floor(t / 60);
        const s = Math.floor(t % 60);
        return `${m}:${s < 10 ? '0' : ''}${s}`;
    };

    return (
        <div className="voice-content">
            <button className="voice-play-btn" onClick={togglePlay}>
                {isPlaying ? <Pause size={14} /> : <Play size={14} style={{ marginLeft: 2 }} />}
            </button>

            {/* Waveform Visualization */}
            <div className="voice-waveform">
                {bars.map((h, i) => {
                    const barProgress = (i / bars.length) * 100;
                    const isFilled = barProgress < progress;
                    return (
                        <div key={i}
                            className={`voice-bar ${isFilled ? 'filled' : ''}`}
                            style={{ height: h }}
                        />
                    )
                })}
            </div>

            <span className="voice-time">
                {formatTime(isPlaying ? currentTime : duration)}
            </span>
        </div>
    );
};

export default VoiceBubble;
