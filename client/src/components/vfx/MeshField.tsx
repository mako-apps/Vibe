import { useEffect, useRef } from 'react';

/**
 * MeshField — a live peer-to-peer network simulation on 2D canvas.
 *
 * Nodes drift, links form by proximity, and encrypted "packets" pulse across
 * live links. One node is you. Pauses off-screen; static under
 * prefers-reduced-motion.
 */

interface Node {
  x: number;
  y: number;
  vx: number;
  vy: number;
  r: number;
}

interface Packet {
  a: number;
  b: number;
  t0: number;
  dur: number;
}

const TEAL = '99, 226, 217';
const VIOLET = '156, 140, 255';

export const MeshField = ({ className }: { className?: string }) => {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    let nodes: Node[] = [];
    let packets: Packet[] = [];
    let raf = 0;
    let running = false;
    let inView = true;
    let lastSpawn = 0;
    let w = 0;
    let h = 0;
    let dpr = 1;

    const seedNodes = () => {
      const count = Math.max(16, Math.min(40, Math.round((w * h) / 24000)));
      nodes = Array.from({ length: count }, () => ({
        x: Math.random() * w,
        y: Math.random() * h,
        vx: (Math.random() - 0.5) * 9,
        vy: (Math.random() - 0.5) * 9,
        r: 1.4 + Math.random() * 1.4,
      }));
      // Node 0 is "YOU" — keep it near the golden-ratio point.
      nodes[0].x = w * 0.38;
      nodes[0].y = h * 0.55;
      nodes[0].r = 3;
      packets = [];
    };

    const resize = () => {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = canvas.clientWidth;
      h = canvas.clientHeight;
      if (w === 0 || h === 0) return;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      seedNodes();
      if (reduced) drawFrame(0, 0);
    };

    const linkRadius = () => Math.min(w, h) * 0.34;

    const drawFrame = (now: number, dt: number) => {
      ctx.clearRect(0, 0, w, h);
      const R = linkRadius();

      // Drift.
      if (dt > 0) {
        for (const n of nodes) {
          n.x += n.vx * dt;
          n.y += n.vy * dt;
          if (n.x < -10) n.x = w + 10;
          if (n.x > w + 10) n.x = -10;
          if (n.y < -10) n.y = h + 10;
          if (n.y > h + 10) n.y = -10;
        }
      }

      // Links.
      const pairs: Array<[number, number, number]> = [];
      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          const dx = nodes[i].x - nodes[j].x;
          const dy = nodes[i].y - nodes[j].y;
          const d = Math.hypot(dx, dy);
          if (d < R) pairs.push([i, j, d]);
        }
      }
      ctx.lineWidth = 1;
      for (const [i, j, d] of pairs) {
        const a = (1 - d / R) * 0.32;
        const you = i === 0 || j === 0;
        ctx.strokeStyle = `rgba(${you ? VIOLET : TEAL}, ${you ? a * 1.5 : a})`;
        ctx.beginPath();
        ctx.moveTo(nodes[i].x, nodes[i].y);
        ctx.lineTo(nodes[j].x, nodes[j].y);
        ctx.stroke();
      }

      // Packets riding live links.
      if (dt > 0 && now - lastSpawn > 520 + Math.random() * 600 && pairs.length > 0) {
        const [i, j] = pairs[Math.floor(Math.random() * pairs.length)];
        packets.push({ a: i, b: j, t0: now, dur: 380 + Math.random() * 320 });
        lastSpawn = now;
      }
      packets = packets.filter((p) => now - p.t0 < p.dur);
      for (const p of packets) {
        const t = (now - p.t0) / p.dur;
        const e = t * t * (3 - 2 * t);
        const x = nodes[p.a].x + (nodes[p.b].x - nodes[p.a].x) * e;
        const y = nodes[p.a].y + (nodes[p.b].y - nodes[p.a].y) * e;
        const fade = Math.sin(Math.PI * t);
        ctx.fillStyle = `rgba(${TEAL}, ${0.9 * fade})`;
        ctx.beginPath();
        ctx.arc(x, y, 2.2, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = `rgba(${TEAL}, ${0.16 * fade})`;
        ctx.beginPath();
        ctx.arc(x, y, 6.5, 0, Math.PI * 2);
        ctx.fill();
      }

      // Nodes.
      for (let i = 1; i < nodes.length; i++) {
        const n = nodes[i];
        ctx.fillStyle = `rgba(${TEAL}, 0.75)`;
        ctx.beginPath();
        ctx.arc(n.x, n.y, n.r, 0, Math.PI * 2);
        ctx.fill();
      }

      // You.
      const you = nodes[0];
      const pulse = dt > 0 ? 0.5 + 0.5 * Math.sin(now / 600) : 0.5;
      ctx.strokeStyle = `rgba(${VIOLET}, ${0.35 + 0.3 * pulse})`;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(you.x, you.y, 9 + pulse * 3, 0, Math.PI * 2);
      ctx.stroke();
      ctx.fillStyle = `rgba(${VIOLET}, 0.95)`;
      ctx.beginPath();
      ctx.arc(you.x, you.y, you.r, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = `rgba(${VIOLET}, 0.85)`;
      ctx.font = '600 9px "JetBrains Mono Variable", ui-monospace, monospace';
      ctx.letterSpacing = '2px';
      ctx.fillText('YOU', you.x + 14, you.y + 3);
    };

    let prev = 0;
    const loop = (now: number) => {
      if (!running) return;
      const dt = prev ? Math.min((now - prev) / 1000, 0.05) : 0;
      prev = now;
      drawFrame(now, dt);
      raf = requestAnimationFrame(loop);
    };

    const syncRunning = () => {
      const should = inView && !document.hidden && !reduced;
      if (should && !running) {
        running = true;
        prev = 0;
        raf = requestAnimationFrame(loop);
      } else if (!should && running) {
        running = false;
        cancelAnimationFrame(raf);
      }
    };

    const io = new IntersectionObserver((entries) => {
      inView = entries[0]?.isIntersecting ?? true;
      syncRunning();
    });
    io.observe(canvas);
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);
    resize();
    const onVisibility = () => syncRunning();
    document.addEventListener('visibilitychange', onVisibility);
    syncRunning();

    return () => {
      running = false;
      cancelAnimationFrame(raf);
      io.disconnect();
      ro.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, []);

  return <canvas ref={canvasRef} className={className} aria-hidden="true" />;
};

export default MeshField;
