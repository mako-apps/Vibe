import React, { useState, useEffect } from 'react';
import { GiphyFetch } from '@giphy/js-fetch-api';
import { Grid } from '@giphy/react-components';
import { X, Search } from 'lucide-react';
import './GifPicker.css';

// Free public API key (you can get your own at developers.giphy.com)
const GIPHY_API_KEY = 'sXpGFDGZs0Dv1mmNFvYaGUvYwKX0PWIh'; // Public demo key

const giphyFetch = new GiphyFetch(GIPHY_API_KEY);

interface GifPickerProps {
    isOpen: boolean;
    onClose: () => void;
    onSelectGif: (gifUrl: string) => void;
}

const GifPicker: React.FC<GifPickerProps> = ({ isOpen, onClose, onSelectGif }) => {
    const [searchQuery, setSearchQuery] = useState('');
    const [debouncedQuery, setDebouncedQuery] = useState('');
    const [width, setWidth] = useState(window.innerWidth > 500 ? 400 : window.innerWidth - 40);

    // Debounce search query
    useEffect(() => {
        const timer = setTimeout(() => {
            setDebouncedQuery(searchQuery);
        }, 500);

        return () => clearTimeout(timer);
    }, [searchQuery]);

    // Update width on resize
    useEffect(() => {
        const handleResize = () => {
            setWidth(window.innerWidth > 500 ? 400 : window.innerWidth - 40);
        };
        window.addEventListener('resize', handleResize);
        return () => window.removeEventListener('resize', handleResize);
    }, []);

    // Fetch GIFs function
    const fetchGifs = (offset: number) => {
        if (debouncedQuery.trim()) {
            return giphyFetch.search(debouncedQuery, { offset, limit: 10 });
        } else {
            return giphyFetch.trending({ offset, limit: 10 });
        }
    };

    const handleGifClick = (gif: any, e: React.SyntheticEvent<HTMLElement, Event>) => {
        e.preventDefault();
        // Get the original GIF URL (best quality)
        const gifUrl = gif.images.original.url;
        onSelectGif(gifUrl);
        onClose();
    };

    if (!isOpen) return null;

    return (
        <div className="gif-picker-overlay">
            <div className="gif-picker-container">
                <div className="gif-picker-header">
                    <div className="gif-search-bar">
                        <Search size={18} className="gif-search-icon" />
                        <input
                            type="text"
                            placeholder="Search GIFs..."
                            value={searchQuery}
                            onChange={(e) => setSearchQuery(e.target.value)}
                            className="gif-search-input"
                            autoFocus
                        />
                    </div>
                    <button className="gif-close-btn" onClick={onClose}>
                        <X size={20} />
                    </button>
                </div>

                <div className="gif-picker-content">
                    <Grid
                        key={debouncedQuery} // Re-render when query changes
                        width={width}
                        columns={2}
                        gutter={6}
                        fetchGifs={fetchGifs}
                        onGifClick={handleGifClick}
                        noLink={true}
                    />
                </div>

                <div className="gif-picker-footer">
                    <span className="giphy-attribution">Powered by GIPHY</span>
                </div>
            </div>
        </div>
    );
};

export default GifPicker;
