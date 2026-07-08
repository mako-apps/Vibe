import React, { useEffect, useRef, useState } from 'react';
import { motion } from 'framer-motion';
import { useNavigate } from 'react-router-dom';
import { Header } from '../components/layout/Header';
import { ContourField } from '../components/vfx/ContourField';
import { MeshField } from '../components/vfx/MeshField';
import { Scramble } from '../components/vfx/Scramble';
import './Home.css';

/* ------------------------------------------------------------------ */
/* shared                                                              */
/* ------------------------------------------------------------------ */

const EASE = [0.22, 1, 0.36, 1] as const;

const Reveal = ({
    children,
    delay = 0,
    className,
}: {
    children: React.ReactNode;
    delay?: number;
    className?: string;
}) => (
    <motion.div
        className={className}
        initial={{ opacity: 0, y: 26 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true, margin: '-60px' }}
        transition={{ duration: 0.9, delay, ease: EASE }}
    >
        {children}
    </motion.div>
);

const SectionHead = ({ index, label }: { index: string; label: string }) => (
    <Reveal className="vl-section-head">
        <span className="vl-section-index">{index}</span>
        <span className="vl-section-rule" aria-hidden="true" />
        <Scramble className="vl-section-label" text={label} duration={700} />
    </Reveal>
);

const Corners = () => (
    <span className="vl-corners" aria-hidden="true">
        <i /><i /><i /><i />
    </span>
);

/* ------------------------------------------------------------------ */
/* hero                                                                */
/* ------------------------------------------------------------------ */

const useFakeNodeCount = () => {
    const [count, setCount] = useState(1284);
    useEffect(() => {
        const id = window.setInterval(() => {
            setCount((n) => Math.max(900, n + (Math.random() < 0.5 ? -1 : 1) * Math.ceil(Math.random() * 4)));
        }, 2400);
        return () => window.clearInterval(id);
    }, []);
    return count;
};

const Hero = () => {
    const navigate = useNavigate();
    const nodes = useFakeNodeCount();

    return (
        <section className="vl-hero" id="top">
            <div className="vl-hero-body">
                <motion.p
                    className="vl-kicker"
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 1 }}
                    transition={{ duration: 1.2, delay: 0.15 }}
                >
                    [ SOVEREIGN MESSAGING PROTOCOL ]
                </motion.p>
                <h1 className="vl-display">
                    <motion.span
                        className="vl-display-line"
                        initial={{ opacity: 0, y: '60%' }}
                        animate={{ opacity: 1, y: '0%' }}
                        transition={{ duration: 1.1, delay: 0.25, ease: EASE }}
                    >
                        Speak <em>freely</em>
                    </motion.span>
                    <motion.span
                        className="vl-display-line"
                        initial={{ opacity: 0, y: '60%' }}
                        animate={{ opacity: 1, y: '0%' }}
                        transition={{ duration: 1.1, delay: 0.4, ease: EASE }}
                    >
                        beyond every border.
                    </motion.span>
                </h1>
                <motion.p
                    className="vl-lede"
                    initial={{ opacity: 0, y: 16 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ duration: 1, delay: 0.65, ease: EASE }}
                >
                    Vibe is a peer-to-peer, end-to-end encrypted messenger that routes around
                    censorship — with Claude&nbsp;&amp;&nbsp;Codex agents living inside your chats.
                    No phone number. No servers to seize. One key, owned by you.
                </motion.p>
                <motion.div
                    className="vl-cta-row"
                    initial={{ opacity: 0, y: 16 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ duration: 1, delay: 0.8, ease: EASE }}
                >
                    <button className="vl-btn vl-btn--primary" onClick={() => navigate('/app')}>
                        Create your key
                        <span className="vl-btn-arrow" aria-hidden="true">→</span>
                    </button>
                    <button className="vl-btn vl-btn--ghost" onClick={() => navigate('/docs/agents')}>
                        Read the protocol
                    </button>
                </motion.div>
            </div>

            <motion.aside
                className="vl-hero-rail"
                aria-hidden="true"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ duration: 1.4, delay: 1 }}
            >
                <span>PROTOCOL v2.5</span>
                <span className="vl-rail-rule" />
                <span>AES-256-GCM</span>
                <span className="vl-rail-rule" />
                <span className="vl-rail-live">
                    <i className="vl-live-dot" />
                    {nodes.toLocaleString()} NODES
                </span>
            </motion.aside>

            <motion.div
                className="vl-hero-foot"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ duration: 1.2, delay: 1.2 }}
            >
                <span className="vl-scroll-cue" aria-hidden="true">
                    <i />
                </span>
                <span>DESCEND</span>
            </motion.div>
        </section>
    );
};

/* ------------------------------------------------------------------ */
/* ticker                                                              */
/* ------------------------------------------------------------------ */

const TICKER_ITEMS = [
    'P2P MESH',
    'AES-256-GCM',
    'NO PHONE NUMBER',
    'DOMAIN FRONTING',
    'V2RAY · SHADOWSOCKS',
    'CLAUDE + CODEX IN-CHAT',
    'FORWARD SECRECY',
    'ZERO METADATA',
];

const Ticker = () => (
    <div className="vl-ticker" aria-hidden="true">
        <div className="vl-ticker-track">
            {[0, 1].map((half) => (
                <span className="vl-ticker-group" key={half}>
                    {TICKER_ITEMS.map((item) => (
                        <span className="vl-ticker-item" key={item}>
                            {item}
                            <i className="vl-ticker-dot" />
                        </span>
                    ))}
                </span>
            ))}
        </div>
    </div>
);

/* ------------------------------------------------------------------ */
/* 01 — mesh                                                           */
/* ------------------------------------------------------------------ */

const MeshSection = () => (
    <section className="vl-section" id="network">
        <SectionHead index="01" label="MESH" />
        <div className="vl-split">
            <div className="vl-split-copy">
                <Reveal>
                    <h2 className="vl-h2">
                        No servers to seize.<br />
                        <em>No middle to attack.</em>
                    </h2>
                </Reveal>
                <Reveal delay={0.1}>
                    <p className="vl-prose">
                        Every conversation is a direct line. Vibe negotiates WebRTC handshakes
                        peer-to-peer and lets relays carry only ciphertext they can never read.
                        The map redraws itself faster than anyone can censor it.
                    </p>
                </Reveal>
                <Reveal delay={0.18}>
                    <div className="vl-stats">
                        <div className="vl-stat-row">
                            <span>RELAY HOPS</span>
                            <span>≤ 3 · dynamic</span>
                        </div>
                        <div className="vl-stat-row">
                            <span>HANDSHAKE</span>
                            <span>~240 ms</span>
                        </div>
                        <div className="vl-stat-row">
                            <span>METADATA RETAINED</span>
                            <span>0 bytes</span>
                        </div>
                    </div>
                </Reveal>
            </div>
            <Reveal delay={0.12} className="vl-split-stage">
                <div className="vl-stage">
                    <Corners />
                    <MeshField className="vl-stage-canvas" />
                    <span className="vl-stage-tag">LIVE TOPOLOGY · SIMULATED</span>
                </div>
            </Reveal>
        </div>
    </section>
);

/* ------------------------------------------------------------------ */
/* 02 — cipher (hold to decrypt)                                       */
/* ------------------------------------------------------------------ */

const PLAINTEXT = 'Meet at the north gate at 21:00. Bring the drive — tell no one else.';
const HEXCHARS = '0123456789ABCDEF';

const sealedGlyph = (i: number, tick: number) => {
    const n = (i * 2654435761 + tick * 40503) >>> 0;
    return HEXCHARS[n % HEXCHARS.length];
};

const CipherDemo = () => {
    const rootRef = useRef<HTMLDivElement>(null);
    const [, force] = useState(0);
    const p = useRef(0);           // 0 = plaintext, 1 = sealed
    const target = useRef(0);
    const tick = useRef(0);
    const [holding, setHolding] = useState(false);
    const reduced = useRef(false);

    useEffect(() => {
        reduced.current = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        const el = rootRef.current;
        if (!el) return;

        let raf = 0;
        let last = 0;
        let lastTick = 0;
        let started = false;

        const loop = (now: number) => {
            const dt = last ? Math.min((now - last) / 1000, 0.05) : 0;
            last = now;
            let dirty = false;

            if (Math.abs(p.current - target.current) > 0.0005) {
                const dir = target.current > p.current ? 1 : -1;
                p.current = Math.max(0, Math.min(1, p.current + dir * dt * 1.7));
                dirty = true;
            }
            if (now - lastTick > 110) {
                lastTick = now;
                tick.current++;
                if (p.current > 0.01) dirty = true;
            }
            if (dirty) force((v) => v + 1);
            raf = requestAnimationFrame(loop);
        };

        const io = new IntersectionObserver(
            (entries) => {
                if (entries[0]?.isIntersecting && !started) {
                    started = true;
                    if (reduced.current) {
                        p.current = 1;
                        target.current = 1;
                        force((v) => v + 1);
                    } else {
                        target.current = 1;
                        raf = requestAnimationFrame(loop);
                    }
                    io.disconnect();
                }
            },
            { threshold: 0.5 }
        );
        io.observe(el);

        return () => {
            io.disconnect();
            cancelAnimationFrame(raf);
        };
    }, []);

    const hold = (down: boolean) => {
        setHolding(down);
        if (reduced.current) {
            p.current = down ? 0 : 1;
            force((v) => v + 1);
        }
        target.current = down ? 0 : 1;
    };

    const len = PLAINTEXT.length;
    const chars = PLAINTEXT.split('').map((c, i) => {
        if (c === ' ') return <span key={i}>&nbsp;</span>;
        const threshold = (i / len) * 0.82 + 0.06;
        const sealed = p.current > threshold;
        return (
            <span key={i} className={sealed ? 'vl-cipher-c is-sealed' : 'vl-cipher-c'}>
                {sealed ? sealedGlyph(i, tick.current) : c}
            </span>
        );
    });

    const sealedNow = p.current > 0.6;

    return (
        <div className="vl-cipher-card" ref={rootRef}>
            <Corners />
            <div className="vl-cipher-head">
                <span>MESSAGE #4471</span>
                <span className={sealedNow ? 'vl-cipher-state is-sealed' : 'vl-cipher-state'}>
                    {sealedNow ? '● SEALED' : '○ PLAINTEXT'}
                </span>
            </div>
            <p className="vl-cipher-text">{chars}</p>
            <div className="vl-cipher-foot">
                <span className="vl-cipher-spec">
                    {sealedNow ? 'AES-256-GCM · IV 96-bit · TAG VERIFIED' : 'VISIBLE ONLY WHILE YOU HOLD'}
                </span>
                <button
                    className={holding ? 'vl-hold-btn is-holding' : 'vl-hold-btn'}
                    onPointerDown={() => hold(true)}
                    onPointerUp={() => hold(false)}
                    onPointerLeave={() => hold(false)}
                    onPointerCancel={() => hold(false)}
                    onKeyDown={(e) => {
                        if ((e.key === 'Enter' || e.key === ' ') && !e.repeat) hold(true);
                    }}
                    onKeyUp={(e) => {
                        if (e.key === 'Enter' || e.key === ' ') hold(false);
                    }}
                    onContextMenu={(e) => e.preventDefault()}
                >
                    {holding ? 'DECRYPTING…' : 'HOLD TO DECRYPT'}
                </button>
            </div>
        </div>
    );
};

const CipherSection = () => (
    <section className="vl-section" id="cipher">
        <SectionHead index="02" label="CIPHER" />
        <div className="vl-split vl-split--reverse">
            <div className="vl-split-copy">
                <Reveal>
                    <h2 className="vl-h2">
                        Sealed before it<br />
                        <em>leaves your hand.</em>
                    </h2>
                </Reveal>
                <Reveal delay={0.1}>
                    <p className="vl-prose">
                        Encryption isn't a feature toggle — it's the transport itself. Keys are
                        derived on-device from a secret only you hold; the network, the relays,
                        even Vibe itself only ever see noise.
                    </p>
                </Reveal>
                <Reveal delay={0.18}>
                    <div className="vl-chips">
                        <span className="vl-chip">AES-256-GCM</span>
                        <span className="vl-chip">RSA-4096 IDENTITY</span>
                        <span className="vl-chip">FORWARD SECRECY</span>
                    </div>
                </Reveal>
            </div>
            <Reveal delay={0.12} className="vl-split-stage">
                <CipherDemo />
            </Reveal>
        </div>
    </section>
);

/* ------------------------------------------------------------------ */
/* 03 — passage (censorship route board)                               */
/* ------------------------------------------------------------------ */

interface PassagePhase {
    path: 'direct' | 'front' | 'tunnel';
    dur: number;
    cut?: number;
    log: string;
    ok: boolean;
}

const PHASES: PassagePhase[] = [
    { path: 'direct', dur: 1150, cut: 0.5, log: 'DIRECT ROUTE ··· RST injected at filter ✕', ok: false },
    { path: 'front', dur: 1750, log: 'DOMAIN FRONT · cdn edge ··· delivered ✓', ok: true },
    { path: 'tunnel', dur: 1750, log: 'V2RAY TLS TUNNEL ··· delivered ✓', ok: true },
];

const PassageBoard = () => {
    const rootRef = useRef<HTMLDivElement>(null);
    const packetRef = useRef<SVGCircleElement>(null);
    const burstRef = useRef<SVGGElement>(null);
    const pathRefs = {
        direct: useRef<SVGPathElement>(null),
        front: useRef<SVGPathElement>(null),
        tunnel: useRef<SVGPathElement>(null),
    };
    const [logs, setLogs] = useState<Array<{ text: string; ok: boolean; id: number }>>([]);

    useEffect(() => {
        const root = rootRef.current;
        if (!root) return;
        const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

        if (reduced) {
            setLogs(PHASES.map((ph, i) => ({ text: ph.log, ok: ph.ok, id: i })).reverse());
            return;
        }

        let raf = 0;
        let running = false;
        let inView = false;
        let phaseIdx = 0;
        let phaseStart = 0;
        let logged = false;
        let logId = 0;

        const PACKET_COLORS: Record<PassagePhase['path'], string> = {
            direct: '#f0716d',
            front: '#63e2d9',
            tunnel: '#9c8cff',
        };

        const loop = (now: number) => {
            if (!running) return;
            if (!phaseStart) phaseStart = now;
            const phase = PHASES[phaseIdx % PHASES.length];
            const el = pathRefs[phase.path].current;
            const packet = packetRef.current;
            const burst = burstRef.current;
            const elapsed = now - phaseStart;
            const HOLD = 1000;

            if (el && packet) {
                if (elapsed < phase.dur) {
                    const t = elapsed / phase.dur;
                    const eased = t * t * (3 - 2 * t);
                    const L = el.getTotalLength() * (phase.cut ?? 1);
                    const pt = el.getPointAtLength(eased * L);
                    packet.setAttribute('cx', String(pt.x));
                    packet.setAttribute('cy', String(pt.y));
                    packet.setAttribute('fill', PACKET_COLORS[phase.path]);
                    packet.setAttribute('opacity', '1');
                } else {
                    packet.setAttribute('opacity', '0');
                    if (!logged) {
                        logged = true;
                        const entry = { text: phase.log, ok: phase.ok, id: logId++ };
                        setLogs((prev) => [entry, ...prev].slice(0, 3));
                        if (!phase.ok && burst) {
                            burst.setAttribute('opacity', '1');
                            window.setTimeout(() => burst.setAttribute('opacity', '0'), 450);
                        }
                    }
                    if (elapsed > phase.dur + HOLD) {
                        phaseIdx++;
                        phaseStart = now;
                        logged = false;
                    }
                }
            }
            raf = requestAnimationFrame(loop);
        };

        const syncRunning = () => {
            const should = inView && !document.hidden;
            if (should && !running) {
                running = true;
                phaseStart = 0;
                raf = requestAnimationFrame(loop);
            } else if (!should && running) {
                running = false;
                cancelAnimationFrame(raf);
            }
        };

        const io = new IntersectionObserver((entries) => {
            inView = entries[0]?.isIntersecting ?? false;
            syncRunning();
        });
        io.observe(root);
        const onVisibility = () => syncRunning();
        document.addEventListener('visibilitychange', onVisibility);

        return () => {
            running = false;
            cancelAnimationFrame(raf);
            io.disconnect();
            document.removeEventListener('visibilitychange', onVisibility);
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    return (
        <div className="vl-passage" ref={rootRef}>
            <div className="vl-stage vl-passage-stage">
                <Corners />
                <svg viewBox="0 0 640 360" className="vl-passage-svg" aria-hidden="true">
                    {/* filter wall */}
                    <g className="vl-wall">
                        <line x1="320" y1="118" x2="320" y2="242" />
                        {Array.from({ length: 8 }, (_, i) => (
                            <line key={i} x1="314" y1={124 + i * 16} x2="326" y2={116 + i * 16} />
                        ))}
                        <text x="332" y="182" className="vl-svg-label vl-svg-label--wall">DPI FILTER</text>
                    </g>

                    {/* routes */}
                    <path ref={pathRefs.direct} className="vl-route vl-route--direct" d="M 60 180 L 580 180" />
                    <path ref={pathRefs.front} className="vl-route vl-route--front" d="M 60 180 C 190 60, 450 60, 580 180" />
                    <path ref={pathRefs.tunnel} className="vl-route vl-route--tunnel" d="M 60 180 C 190 300, 450 300, 580 180" />

                    {/* waypoints */}
                    <circle cx="320" cy="90" r="3" className="vl-waypoint vl-waypoint--front" />
                    <text x="320" y="74" className="vl-svg-label" textAnchor="middle">cdn · front</text>
                    <circle cx="320" cy="270" r="3" className="vl-waypoint vl-waypoint--tunnel" />
                    <text x="320" y="296" className="vl-svg-label" textAnchor="middle">v2ray · tls</text>

                    {/* endpoints */}
                    <circle cx="60" cy="180" r="5" className="vl-endpoint" />
                    <text x="60" y="212" className="vl-svg-label" textAnchor="middle">YOU</text>
                    <circle cx="580" cy="180" r="5" className="vl-endpoint" />
                    <text x="580" y="212" className="vl-svg-label" textAnchor="middle">PEER</text>

                    {/* burst on block */}
                    <g ref={burstRef} opacity="0" className="vl-burst">
                        <line x1="312" y1="172" x2="328" y2="188" />
                        <line x1="328" y1="172" x2="312" y2="188" />
                    </g>

                    <circle ref={packetRef} r="4" opacity="0" className="vl-packet" />
                </svg>
            </div>
            <div className="vl-passage-log" aria-live="polite">
                {logs.map((l) => (
                    <div key={l.id} className={l.ok ? 'vl-log-line is-ok' : 'vl-log-line is-fail'}>
                        {l.text}
                    </div>
                ))}
                {logs.length === 0 && <div className="vl-log-line">AWAITING TRAFFIC…</div>}
            </div>
        </div>
    );
};

const PassageSection = () => (
    <section className="vl-section" id="passage">
        <SectionHead index="03" label="PASSAGE" />
        <div className="vl-split">
            <div className="vl-split-copy">
                <Reveal>
                    <h2 className="vl-h2">
                        When the wall goes up,<br />
                        <em>the route goes around.</em>
                    </h2>
                </Reveal>
                <Reveal delay={0.1}>
                    <p className="vl-prose">
                        Deep-packet inspection kills the direct line — so Vibe never insists on one.
                        Traffic reshapes itself as ordinary CDN requests or slips through V2Ray-patterned
                        TLS tunnels until something gets through. Something always gets through.
                    </p>
                </Reveal>
                <Reveal delay={0.18}>
                    <div className="vl-chips">
                        <span className="vl-chip">DOMAIN FRONTING</span>
                        <span className="vl-chip">V2RAY</span>
                        <span className="vl-chip">SHADOWSOCKS</span>
                        <span className="vl-chip">SNOWFLAKE</span>
                    </div>
                </Reveal>
            </div>
            <Reveal delay={0.12} className="vl-split-stage">
                <PassageBoard />
            </Reveal>
        </div>
    </section>
);

/* ------------------------------------------------------------------ */
/* 04 — agents (auto-typing terminal)                                  */
/* ------------------------------------------------------------------ */

interface TermLine {
    kind: 'cmd' | 'sys' | 'tool' | 'ok';
    text: string;
}

const SCRIPT: TermLine[] = [
    { kind: 'cmd', text: 'you ▸ @claude the login screen crashes on iPhone — fix it' },
    { kind: 'sys', text: 'claude · connected to MacBook-Pro · repo vibe/ios' },
    { kind: 'tool', text: '⏺ Grep   "session restore" — 14 hits' },
    { kind: 'tool', text: '⏺ Read   ChatEngine.swift' },
    { kind: 'tool', text: '⏺ Edit   ChatEngine.swift  +12 −3' },
    { kind: 'tool', text: '⏺ Build  succeeded · 0 warnings' },
    { kind: 'ok', text: 'claude ▸ Fixed — race in session restore. Diff attached to this chat.' },
    { kind: 'cmd', text: 'you ▸ run it on my phone' },
    { kind: 'ok', text: 'claude ▸ Installed on iPhone 16 Pro Max ✓' },
];

const AgentTerminal = () => {
    const rootRef = useRef<HTMLDivElement>(null);
    const [cursor, setCursor] = useState<{ line: number; chars: number }>({ line: -1, chars: 0 });

    useEffect(() => {
        const root = rootRef.current;
        if (!root) return;

        if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            setCursor({ line: SCRIPT.length, chars: 0 });
            return;
        }

        const timers: number[] = [];
        let started = false;
        const schedule = (fn: () => void, ms: number) => {
            timers.push(window.setTimeout(fn, ms));
        };

        const run = () => {
            setCursor({ line: -1, chars: 0 });
            let acc = 500;
            SCRIPT.forEach((line, li) => {
                if (line.kind === 'cmd') {
                    for (let c = 1; c <= line.text.length; c++) {
                        schedule(() => setCursor({ line: li, chars: c }), acc);
                        acc += 22;
                    }
                    acc += 550;
                } else {
                    schedule(() => setCursor({ line: li, chars: line.text.length }), acc);
                    acc += line.kind === 'tool' ? 540 : 850;
                }
            });
            schedule(() => setCursor({ line: SCRIPT.length, chars: 0 }), acc);
            schedule(run, acc + 4500);
        };

        const io = new IntersectionObserver(
            (entries) => {
                if (entries[0]?.isIntersecting && !started) {
                    started = true;
                    run();
                    io.disconnect();
                }
            },
            { threshold: 0.35 }
        );
        io.observe(root);

        return () => {
            io.disconnect();
            timers.forEach((t) => window.clearTimeout(t));
        };
    }, []);

    return (
        <div className="vl-terminal" ref={rootRef}>
            <Corners />
            <div className="vl-terminal-bar">
                <span className="vl-term-dots" aria-hidden="true"><i /><i /><i /></span>
                <span className="vl-term-title">vibe · agent bridge</span>
                <span className="vl-term-status">● LIVE</span>
            </div>
            <div className="vl-terminal-body">
                {SCRIPT.map((line, li) => {
                    if (li > cursor.line) return null;
                    const partial = li === cursor.line;
                    const text = partial ? line.text.slice(0, cursor.chars) : line.text;
                    return (
                        <div key={li} className={`vl-term-line vl-term-line--${line.kind}`}>
                            {text}
                            {partial && line.kind === 'cmd' && <span className="vl-term-caret" />}
                        </div>
                    );
                })}
                {cursor.line >= SCRIPT.length && (
                    <div className="vl-term-line vl-term-line--cmd">
                        you ▸ <span className="vl-term-caret" />
                    </div>
                )}
            </div>
        </div>
    );
};

const AgentsSection = () => (
    <section className="vl-section" id="agents">
        <SectionHead index="04" label="AGENTS" />
        <div className="vl-split vl-split--reverse">
            <div className="vl-split-copy">
                <Reveal>
                    <h2 className="vl-h2">
                        Your repo,<br />
                        <em>in your pocket.</em>
                    </h2>
                </Reveal>
                <Reveal delay={0.1}>
                    <p className="vl-prose">
                        Claude and Codex are first-class citizens of your chats. Agents run on your
                        own machine, stream every tool call to your phone end-to-end encrypted, and
                        wait for your approval before anything ships. DM one — or put both in a group
                        and let them race.
                    </p>
                </Reveal>
                <Reveal delay={0.18}>
                    <a className="vl-textlink" href="/docs/agents">
                        Agent bridge documentation <span aria-hidden="true">↗</span>
                    </a>
                </Reveal>
            </div>
            <Reveal delay={0.12} className="vl-split-stage">
                <AgentTerminal />
            </Reveal>
        </div>
    </section>
);

/* ------------------------------------------------------------------ */
/* join + footer                                                       */
/* ------------------------------------------------------------------ */

const JoinSection = () => {
    const navigate = useNavigate();
    return (
        <section className="vl-join" id="join">
            <Reveal>
                <p className="vl-kicker">[ NO PHONE NUMBER · NO EMAIL · ONE KEY ]</p>
            </Reveal>
            <Reveal delay={0.08}>
                <h2 className="vl-display vl-display--join">
                    Own the key.<br /><em>Own the conversation.</em>
                </h2>
            </Reveal>
            <Reveal delay={0.16}>
                <div className="vl-cta-row vl-cta-row--center">
                    <button className="vl-btn vl-btn--primary" onClick={() => navigate('/app')}>
                        Generate my key
                        <span className="vl-btn-arrow" aria-hidden="true">→</span>
                    </button>
                    <button className="vl-btn vl-btn--ghost" onClick={() => navigate('/app')}>
                        I already have one
                    </button>
                </div>
            </Reveal>
            <Reveal delay={0.24}>
                <p className="vl-join-fine">
                    A 256-bit secret, generated on your device. We never see it — and never can.
                </p>
            </Reveal>
        </section>
    );
};

const Footer = () => (
    <footer className="vl-footer">
        <div className="vl-footer-word" aria-hidden="true">VIBE</div>
        <div className="vl-footer-grid">
            <div className="vl-footer-col">
                <span className="vl-footer-head">PROTOCOL</span>
                <a href="/#network">Mesh network</a>
                <a href="/#cipher">Encryption</a>
                <a href="/#passage">Censorship passage</a>
            </div>
            <div className="vl-footer-col">
                <span className="vl-footer-head">BUILD</span>
                <a href="/docs/agents">Agent bridge</a>
                <a href="/docs/agents/config">Configuration</a>
                <a href="/docs/agents/examples">Examples</a>
            </div>
            <div className="vl-footer-col">
                <span className="vl-footer-head">ENTER</span>
                <a href="/app">Open Vibe</a>
                <a href="/app">Create a key</a>
            </div>
        </div>
        <div className="vl-footer-bottom">
            <span>© 2026 VIBE — BUILT FOR THE SOVEREIGN EDGE</span>
            <span>v0.1.0-ALPHA · 36.77°N 3.05°E · SIGNAL GOOD</span>
        </div>
    </footer>
);

/* ------------------------------------------------------------------ */
/* page                                                                */
/* ------------------------------------------------------------------ */

const Home = () => (
    <div className="vl-root">
        <ContourField className="vl-shader" />
        <Header />
        <main className="vl-main">
            <Hero />
            <Ticker />
            <MeshSection />
            <CipherSection />
            <PassageSection />
            <AgentsSection />
            <JoinSection />
        </main>
        <Footer />
    </div>
);

export default Home;
