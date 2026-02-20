
import { useMemo } from 'react';

// Enhanced Pattern Set
const MIXED_PATTERNS = [
    // CLASSIC DOODLES
    "M12 2l3 7h7l-6 5 2 7-6-5-6 5 2-7-6-5h7z",
    "M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z",
    "M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4m4-5l5 5 5-5m-5 5V3",
    "M12 3v18m9-9H3",
    "M12 2a10 10 0 100 20 10 10 0 000-20zm-1 15l-5-5 1.41-1.41L11 14.17l7.59-7.59L20 8l-9 9z",
    "M9 18V5l12-2v13",
    "M2 12h20M2 12l6-6m-6 6l6 6",
    "M12 2L2 22h20",
    "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z",
    "M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z",
    "M20 4h-3.17L15 2H9L7.17 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm-5 11.5V13H9v2.5L5.5 12 9 8.5V11h6V8.5l3.5 3.5-3.5 3.5z",
    "M4 16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2H9.66l-2-2H4c-1.1 0-2 .9-2 2v12z",
    "M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z",
    "M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z",
    "M12 6c1.1 0 2 .9 2 2s-.9 2-2 2-2-.9-2-2 .9-2 2-2m0 10c2.7 0 5.8 1.29 6 2H6c.23-.72 3.31-2 6-2m0-12C9.79 4 8 5.79 8 8s1.79 4 4 4 4-1.79 4-4-1.79-4-4-4zm0 10c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z",
    "M7 18c-1.1 0-1.99.9-1.99 2S5.9 22 7 22s2-.9 2-2-.9-2-2-2zM1 2v2h2l3.6 7.59-1.35 2.45c-.16.28-.25.61-.25.96 0 1.1.9 2 2 2h12v-2H7.42c-.14 0-.25-.11-.25-.25l.03-.12.9-1.63h7.45c.75 0 1.41-.41 1.75-1.03l3.58-6.49c.08-.14.12-.31.12-.48 0-.55-.45-1-1-1H5.21l-.94-2H1zm16 16c-1.1 0-1.99.9-1.99 2s.89 2 1.99 2 2-.9 2-2-.9-2-2-2z",
    "M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8z",
    "M2 20h20v-2H2v2zm2-3h2v-2H4v2zm4 0h2v-2H8v2zm4 0h2v-2h-2v2zm4 0h2v-2h-2v2zM2 4v10h20V4H2zm10 7c-1.66 0-3-1.34-3-3s1.34-3 3-3 3 1.34 3 3-1.34 3-3 3z",

    // NATURE
    "M12 2c0 5-4 9-4 15 0 2 2 4 4 4s4-2 4-4c0-6-4-10-4-15z",
    "M2 12c3-4 7-6 12-6 4 0 7 2 7 6s-5 6-9 6c-3 0-7-4-10-6z",
    "M12 2L9 9 2 12l7 3 3 7 3-7 7-3-7-3-3-7z",
    "M10 2a8 8 0 100 16 8 8 0 000-16zm4 2a4 4 0 110 8 4 4 0 010-8z",
    "M6 18c0-3 2-6 6-6s6 3 6 6H6z",
    "M12 4c-4 0-8 3-8 8s4 8 8 8 8-3 8-8-4-8-8-8zm-2 10c0-2 2-4 4-4",
    "M5 12q3-6 7-6t7 6q-3 6-7 6t-7-6zM12 9a3 3 0 100 6 3 3 0 000-6z",

    // SPACE
    "M12 4a8 8 0 100 16 8 8 0 000-16zm2 3a2 2 0 110 4 2 2 0 010-4z",
    "M4 12c0-4 4-8 8-8s8 4 8 8-4 8-8 8-8-4-8-8zm2 0c0 2 2 4 6 4s6-2 6-4-2-4-6-4-6 2-6 4z",
    "M2 2l4 4m16-4l-4 4M2 22l4-4m16 4l-4-4",
    "M10 2c-4 4-4 10 0 14m4-14c4 4 4 10 0 14",

    // GEOMETRIC & ABSTRACT
    "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z",
    "M3 3v18h18V3H3zm16 16H5V5h14v14z",
    "M12 4l-8 16h16L12 4zm0 4.5l5 10H7l5-10z",
    "M7 2v5H2v2h5v5h2V9h5V7H9V2H7z",
    "M12 2l9 5v10l-9 5-9-5V7l9-5zm0 2.3L4.8 8.1v7.8l7.2 3.8 7.2-3.8V8.1L12 4.3z",
    "M2 12c4 0 4-6 10-6s6 6 10 6",
    "M4 4c4 0 4 16 8 16s4-16 8-16",
    "M2 2l20 20M22 2L2 22",
    "M12 2a2 2 0 100 4 2 2 0 000-4zm0 8a2 2 0 100 4 2 2 0 000-4zm0 8a2 2 0 100 4 2 2 0 000-4z",
    "M6 6h4v4H6V6zm8 8h4v4h-4v-4z",
];

interface Props {
    colors?: string[];
    patternOpacity?: number;
}

// Muted/Luxe Colors from mobile/src/lib/theme.ts to ensure blended/low-contrast look
const THEME_PALETTE = {
    bg: '#191919',
    mauve: '#b4a7c7', // Muted purple
    slate: '#64748b', // Muted blue-grey
    zinc: '#71717a',  // Muted grey
};

const CELL_SIZE = 50;

const rng = (seed: number) => {
    const x = Math.sin(seed) * 10000;
    return x - Math.floor(x);
};

export default function PatternWallpaper({ colors, }: Props) {
    const items = useMemo(() => {
        const seed = 9932;
        const cols = 50;
        const rows = 30;

        const grid = new Uint8Array(cols * rows);
        const result: any[] = [];

        for (let r = 0; r < rows; r++) {
            for (let c = 0; c < cols; c++) {
                if (grid[r * cols + c]) continue;

                let isBig = false;
                // Probability for larger items
                const rRand = rng(seed + r * 19 + c * 73);
                if (rRand > 0.88 && c < cols - 1 && r < rows - 1) {
                    if (!grid[r * cols + (c + 1)] && !grid[(r + 1) * cols + c] && !grid[(r + 1) * cols + (c + 1)]) {
                        isBig = true;
                    }
                }

                const pathIdx = Math.floor(rng(seed + r * cols + c) * MIXED_PATTERNS.length);
                const rotation = (rng(seed + r * 17 + c) - 0.5) * 45;

                const cellX = c * CELL_SIZE;
                const cellY = r * CELL_SIZE;

                const baseScale = isBig ? 2.2 : 1.0;
                const scaleVar = (rng(seed + r * 33 + c) - 0.5) * (isBig ? 0.3 : 0.4);
                const finalScale = baseScale + scaleVar;

                const jitterX = (rng(seed + r * 101 + c) - 0.5) * (CELL_SIZE * 0.4);
                const jitterY = (rng(seed + r * 102 + c + 1) - 0.5) * (CELL_SIZE * 0.4);

                const gridSpan = isBig ? CELL_SIZE * 2 : CELL_SIZE;
                const cx = cellX + gridSpan / 2 + jitterX;
                const cy = cellY + gridSpan / 2 + jitterY;

                result.push({
                    path: MIXED_PATTERNS[pathIdx],
                    cx, cy,
                    scale: finalScale,
                    rotation,
                    // Very low opacity: 0.05 to 0.12 for extreme blending
                    opacity: 0.06 + rng(seed * 3 + r) * 0.06
                });

                grid[r * cols + c] = 1;
                if (isBig) {
                    grid[r * cols + c + 1] = 1; grid[(r + 1) * cols + c] = 1; grid[(r + 1) * cols + c + 1] = 1;
                }
            }
        }
        return result;
    }, []);

    return (
        <div style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%', zIndex: 0, overflow: 'hidden', pointerEvents: 'none' }}>
            {/* 
                BACKGROUND LAYER 
             */}
            <div style={{
                position: 'absolute', inset: 0,
                background: colors && colors.length > 0
                    ? (colors.length > 1 ? `linear-gradient(135deg, ${colors[0]}, ${colors[1]})` : colors[0])
                    : THEME_PALETTE.bg
            }} />

            {/* 
                SVG Pattern Layer using MASKING
             */}
            <svg width="100%" height="100%" style={{ position: 'absolute', top: 0, left: 0 }}>
                <defs>
                    {/* Soft Muted Gradient (Mauve -> Zinc -> Slate) */}
                    <linearGradient id="main-gradient" x1="0%" y1="0%" x2="100%" y2="100%" gradientUnits="userSpaceOnUse">
                        <stop offset="0%" stopColor={THEME_PALETTE.mauve} />
                        <stop offset="50%" stopColor={THEME_PALETTE.zinc} />
                        <stop offset="100%" stopColor={THEME_PALETTE.slate} />
                    </linearGradient>

                    <pattern id="paths-pattern" x="0" y="0" width={50 * CELL_SIZE} height={30 * CELL_SIZE} patternUnits="userSpaceOnUse">
                        {items.map((item, i) => (
                            <g key={i} transform={`translate(${item.cx}, ${item.cy}) rotate(${item.rotation}) scale(${item.scale})`}>
                                <path
                                    d={item.path}
                                    transform="translate(-12, -12)"
                                    fill="none"
                                    stroke="white"
                                    strokeWidth={1.2 / item.scale}
                                    strokeLinecap="round"
                                    strokeLinejoin="round"
                                    strokeOpacity={item.opacity}
                                />
                            </g>
                        ))}
                    </pattern>

                    <mask id="pattern-mask">
                        <rect width="100%" height="100%" fill="black" />
                        <rect width="100%" height="100%" fill="url(#paths-pattern)" />
                    </mask>
                </defs>

                <rect width="100%" height="100%" fill="url(#main-gradient)" mask="url(#pattern-mask)" />
            </svg>
        </div>
    );
}
