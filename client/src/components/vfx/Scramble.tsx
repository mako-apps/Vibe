import React, { useEffect, useRef, useState } from 'react';

/**
 * Scramble — text resolves out of cipher noise when it enters the viewport.
 * Static text under prefers-reduced-motion.
 */

const GLYPHS = '<>/\\[]{}#%&$@+=*0123456789ABCDEF';

const randomize = (text: string, from: number) =>
  text
    .split('')
    .map((c, i) => {
      if (i < from || c === ' ' || c === '\n') return c;
      return GLYPHS[Math.floor(Math.random() * GLYPHS.length)];
    })
    .join('');

interface ScrambleProps {
  text: string;
  duration?: number;
  delay?: number;
  className?: string;
  as?: keyof React.JSX.IntrinsicElements;
}

export const Scramble = ({ text, duration = 900, delay = 0, className, as = 'span' }: ScrambleProps) => {
  const Tag = as as React.ElementType;
  const ref = useRef<HTMLElement>(null);
  const [display, setDisplay] = useState(text);
  const played = useRef(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setDisplay(text);
      return;
    }

    let raf = 0;
    let timer = 0;

    const play = () => {
      const start = performance.now();
      const tick = (now: number) => {
        const p = Math.min((now - start) / duration, 1);
        const eased = 1 - Math.pow(1 - p, 2.4);
        setDisplay(p >= 1 ? text : randomize(text, Math.floor(eased * text.length)));
        if (p < 1) raf = requestAnimationFrame(tick);
      };
      raf = requestAnimationFrame(tick);
    };

    const io = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting && !played.current) {
          played.current = true;
          setDisplay(randomize(text, 0));
          timer = window.setTimeout(play, delay);
          io.disconnect();
        }
      },
      { threshold: 0.4 }
    );
    io.observe(el);

    return () => {
      io.disconnect();
      cancelAnimationFrame(raf);
      clearTimeout(timer);
    };
  }, [text, duration, delay]);

  return (
    <Tag ref={ref} className={className} aria-label={text}>
      {display}
    </Tag>
  );
};

export default Scramble;
