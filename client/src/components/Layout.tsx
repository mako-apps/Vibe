import { ReactNode } from 'react';
import { motion, AnimatePresence } from 'framer-motion';

interface LayoutProps {
    children: ReactNode;
    isPresent: boolean;
    keyName: string;
    zIndex?: number;
}

export default function Layout({ children, isPresent, keyName, zIndex = 10 }: LayoutProps) {
    return (
        <AnimatePresence>
            {isPresent && (
                <motion.div
                    key={keyName}
                    initial={{ x: '100%' }}
                    animate={{ x: 0 }}
                    exit={{ x: '100%' }}
                    transition={{ duration: 0.35, ease: [0.32, 0.72, 0, 1] }}
                    style={{
                        position: 'absolute',
                        width: '100%',
                        height: '100%',
                        background: 'var(--bg-primary)',
                        zIndex: zIndex,
                        top: 0,
                        left: 0,
                        // Ensure no drag here unless specifically added
                        touchAction: 'pan-y' // Allow vertical scroll, prevent side swipes from browser if issues
                    }}
                // No drag props here!
                >
                    {children}
                </motion.div>
            )}
        </AnimatePresence>
    );
}
