import React, { useRef, useEffect } from 'react';
import { Pressable, StyleProp, ViewStyle } from 'react-native';
import LottieView from 'lottie-react-native';

interface AnimatedEmojiProps {
    source: any;
    size?: number;
    autoplay?: boolean;
    loop?: boolean;
    style?: StyleProp<ViewStyle>;
}

export default function AnimatedEmoji({ source, size = 120, autoplay = true, loop = false, style }: AnimatedEmojiProps) {
    const animationRef = useRef<LottieView>(null);

    useEffect(() => {
        if (autoplay) {
            animationRef.current?.play();
        }
    }, [autoplay]);

    const handlePress = () => {
        animationRef.current?.reset();
        animationRef.current?.play();
    };

    return (
        <Pressable onPress={handlePress} style={style}>
            <LottieView
                ref={animationRef}
                source={source}
                style={{ width: size, height: size }}
                autoPlay={autoplay}
                loop={loop}
                resizeMode="contain"
            />
        </Pressable>
    );
}
