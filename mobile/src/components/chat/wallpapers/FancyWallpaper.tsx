import React from 'react';
import { ChatTheme } from '../../../lib/stores/wallpaper-store';
import MaskedImageWallpaper from './MaskedImageWallpaper';

interface Props {
    theme: ChatTheme;
    width?: number;
    height?: number;
}

export default function FancyWallpaper(props: Props) {
    return (
        <MaskedImageWallpaper
            {...props}
            imageSource={require('../../../../assets/Wallpapers/fancy.png')}
        />
    );
}
