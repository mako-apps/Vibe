import React from 'react';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import MaskedImageWallpaper from './MaskedImageWallpaper';

interface Props {
    theme: ChatTheme;
    width?: number;
    height?: number;
}

export default function DoodleWallpaper(props: Props) {
    return (
        <MaskedImageWallpaper
            {...props}
            imageSource={require('../../../../assets/Wallpapers/doodle.png')}
        />
    );
}
