import { motion } from 'framer-motion';
import {
    Bot,
    KeyRound,
    Link2,
    MessageSquareText,
    SlidersHorizontal,
    Sparkles,
    Workflow,
    Wrench,
} from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { Header } from '../components/layout/Header';
import './Home.css';
import './AgentDocs.css';

const FadeIn = ({ children, delay = 0 }: { children: React.ReactNode; delay?: number }) => (
    <motion.div
        initial={{ opacity: 0, y: 12 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true }}
        transition={{ duration: 0.7, delay, ease: [0.21, 0.45, 0.32, 0.9] }}
    >
        {children}
    </motion.div>
);

const configSections = [
    {
        id: 'identity',
        icon: Bot,
        title: 'Identity',
        items: [
            ['display_name', 'Human-readable agent name shown in Vibe home, chat, and notifications.'],
            ['username', 'Optional public `@handle` used as the stable invoke identifier when present.'],
            ['agent_id', 'Internal UUID-like identifier that always works for API calls and config operations.'],
            ['status', 'Draft, published, archived. Published agents are reachable from external invoke/event endpoints.'],
            ['prompt_status', 'Quick health indicator for whether the system prompt/setup is complete enough to publish.'],
        ],
    },
    {
        id: 'behavior',
        icon: Sparkles,
        title: 'Prompt & Behavior',
        items: [
            ['system_prompt', 'The full operating instruction set for the standalone agent.'],
            ['prompt_preview', 'Condensed preview used in cards and summaries when the full prompt stays hidden.'],
            ['persona', 'Optional stylistic/personality guidance layered into the main prompt.'],
            ['welcome_message', 'Optional greeting used when the agent is first opened or attached.'],
            ['autonomy_mode', 'How safely the agent acts when tools or delivery behaviors need approval.'],
        ],
    },
    {
        id: 'tools',
        icon: Wrench,
        title: 'Tools & Outputs',
        items: [
            ['enabled_tools', 'Subset of registry tools the agent is allowed to call.'],
            ['output_modes', 'Allowed response types such as `text`, `file`, `media`, and `voice`.'],
            ['voice_profile', 'Voice preset used when voice output is enabled.'],
            ['callback_url', 'Optional signed webhook target for outbound invocation/delivery updates.'],
            ['secret_hint', 'Safe suffix-only reference shown in UI when the full secret is hidden.'],
        ],
    },
    {
        id: 'delivery',
        icon: Workflow,
        title: 'Delivery & Inbox Mode',
        items: [
            ['default_destination_chat', 'Primary Vibe destination used by external events when `destinationChatId` is omitted.'],
            ['attached_chats', 'Owner-visible DM/group destinations the agent is already attached to.'],
            ['event_inbox.mode', '`per_event` posts one bubble per event. `batched_summary` stores events and emits summaries on cadence.'],
            ['event_inbox.summary_window_hours', 'Summary cadence for batched mode. Current native UI exposes `4h` and `daily`.'],
            ['relatedMessageIds', 'Optional linked message ids returned by inbox queries so the main chat can jump to underlying bubbles.'],
        ],
    },
    {
        id: 'integration',
        icon: Link2,
        title: 'External Integration',
        items: [
            ['api_base_url', 'Base Vibe API origin used to build all endpoint URLs.'],
            ['invoke_url', 'Signed endpoint for direct request/response agent execution.'],
            ['events_url', 'Structured event ingestion endpoint for threaded external notifications.'],
            ['X-Vibe-Agent-Secret', 'Required auth header for invoke and event ingestion.'],
            ['callback signature', 'Outbound callbacks are signed as `hex(hmac_sha256(secret, "{timestamp}.{rawBody}"))`.'],
        ],
    },
    {
        id: 'operations',
        icon: SlidersHorizontal,
        title: 'Owner Operations',
        items: [
            ['rename', 'Update `display_name` with `PUT /api/agents/:id`.'],
            ['rotate secret', 'Create a fresh invoke secret and invalidate the previous one.'],
            ['publish', 'Move a draft agent into external availability.'],
            ['archive/delete', 'Remove an agent from the active list without exposing it to future use.'],
            ['copy env pack', 'Generated integration pack with API base, identifier, secret, and destination chat guidance.'],
        ],
    },
];

const agentConfigPayload = `{
  "display_name": "Trade Desk",
  "username": "trade_desk",
  "system_prompt": "Review incoming trade events and answer with concise summaries.",
  "enabled_tools": ["query_event_inbox", "configure_event_inbox"],
  "output_modes": ["text", "voice"],
  "approval_rules": {
    "event_inbox": {
      "mode": "batched_summary",
      "summary_window_hours": 4
    }
  },
  "default_destination_chat_id": "73928163c120",
  "callback_url": "https://your-app.example/webhooks/vibe"
}`;

const eventInboxPatch = `PUT /api/agents/:id
Authorization: Bearer <token>
Content-Type: application/json

{
  "approval_rules": {
    "event_inbox": {
      "mode": "batched_summary",
      "summary_window_hours": 24
    }
  }
}`;

const AgentConfigDocs = () => {
    const navigate = useNavigate();

    return (
        <div className="landing-page luxury-light docs-page">
            <Header />

            <section className="docs-hero" id="overview">
                <div className="docs-hero-copy">
                    <FadeIn>
                        <span className="section-label">AGENT_CONFIG</span>
                        <h1 className="docs-title">Detailed reference for every standalone agent config surface.</h1>
                        <p className="docs-subtitle">
                            This page maps the fields exposed across the builder, native config panel, external
                            integration payloads, and inbox-delivery controls so the web client documents the same
                            config model the app now uses.
                        </p>
                        <div className="hero-cta-group">
                            <button className="luxe-button-primary" onClick={() => navigate('/docs/agents')}>
                                General Agent Docs
                            </button>
                            <button
                                className="luxe-button-secondary"
                                onClick={() => document.getElementById('identity')?.scrollIntoView({ behavior: 'smooth', block: 'start' })}
                            >
                                Config Fields
                            </button>
                        </div>
                    </FadeIn>
                </div>

                <FadeIn delay={0.1}>
                    <div className="docs-hero-panel">
                        <div className="docs-status-row">
                            <span>identity</span>
                            <strong>name + username + invoke id</strong>
                        </div>
                        <div className="docs-status-row">
                            <span>delivery</span>
                            <strong>default chat + inbox mode</strong>
                        </div>
                        <div className="docs-status-row">
                            <span>runtime</span>
                            <strong>tools + outputs + callback</strong>
                        </div>
                        <div className="docs-status-row">
                            <span>security</span>
                            <strong>secret hint + rotate + signed webhooks</strong>
                        </div>
                    </div>
                </FadeIn>
            </section>

            <section className="docs-card-grid">
                <FadeIn>
                    <article className="docs-card">
                        <MessageSquareText size={18} />
                        <h2>Native Config Sheet</h2>
                        <p>The iOS config panel now exposes rename, prompt viewing, delivery targets, secret actions, and inbox mode control.</p>
                    </article>
                </FadeIn>
                <FadeIn delay={0.05}>
                    <article className="docs-card">
                        <Workflow size={18} />
                        <h2>Inbox Modes</h2>
                        <p>Choose between event bubbles and batched summaries without leaving the main chat surface.</p>
                    </article>
                </FadeIn>
                <FadeIn delay={0.1}>
                    <article className="docs-card">
                        <KeyRound size={18} />
                        <h2>Safe Integration</h2>
                        <p>Secrets stay owner-only in UI, while config cards and docs expose the rest of the integration pack clearly.</p>
                    </article>
                </FadeIn>
            </section>

            <section className="docs-section docs-alt" id="identity">
                <div className="docs-section-head">
                    <span className="section-label">FIELD_REFERENCE</span>
                    <h2 className="section-title">The agent config model spans identity, behavior, delivery, and external integration.</h2>
                    <p className="section-desc">
                        These are the fields the standalone-agent builder, config panel, and external integration pack currently surface.
                    </p>
                </div>

                <div className="docs-config-grid">
                    {configSections.map((section, index) => {
                        const Icon = section.icon;
                        return (
                            <FadeIn key={section.id} delay={index * 0.04}>
                                <article className="docs-detail-card docs-config-card" id={section.id}>
                                    <div className="docs-config-card-head">
                                        <Icon size={18} />
                                        <h3>{section.title}</h3>
                                    </div>
                                    <div className="docs-config-list">
                                        {section.items.map(([label, description]) => (
                                            <div className="docs-config-row" key={label}>
                                                <code>{label}</code>
                                                <p>{description}</p>
                                            </div>
                                        ))}
                                    </div>
                                </article>
                            </FadeIn>
                        );
                    })}
                </div>
            </section>

            <section className="docs-section" id="delivery">
                <div className="docs-section-head">
                    <span className="section-label">PATCH_EXAMPLE</span>
                    <h2 className="section-title">The same config can be represented in API payloads and in the native panel.</h2>
                    <p className="section-desc">
                        The native `Inbox Mode` row updates the same `approval_rules.event_inbox` structure that external tools and owner APIs use.
                    </p>
                </div>

                <div className="docs-code-grid">
                    <div className="docs-code-card">
                        <div className="docs-code-label">Agent Payload Shape</div>
                        <pre><code>{agentConfigPayload}</code></pre>
                    </div>
                    <div className="docs-code-card">
                        <div className="docs-code-label">Inbox Mode Update</div>
                        <pre><code>{eventInboxPatch}</code></pre>
                    </div>
                </div>
            </section>

            <section className="docs-section" id="automation">
                <div className="docs-section-head">
                    <span className="section-label">OPERATIONS</span>
                    <h2 className="section-title">What owners can change live today.</h2>
                    <p className="section-desc">
                        The config panel and builder chat now cover the main lifecycle operations without requiring a separate management surface.
                    </p>
                </div>

                <div className="docs-customize-grid">
                    <article className="docs-detail-card">
                        <SlidersHorizontal size={18} />
                        <h3>Live Editing</h3>
                        <p>Rename the agent, inspect the full prompt, copy delivery ids, rotate the invoke secret, archive the agent, and switch inbox behavior directly from the owner panel.</p>
                    </article>

                    <article className="docs-detail-card">
                        <Workflow size={18} />
                        <h3>Inbox Workflows</h3>
                        <p>Use `per_event` when every external notification should appear as a bubble, or `batched_summary` when the agent should receive everything but summarize on a cadence like 4 hours or daily.</p>
                    </article>
                </div>
            </section>

            <footer className="luxe-footer docs-footer">
                <div className="footer-inner">
                    <div className="footer-top">
                        <span className="logo-small">vibe</span>
                        <div className="footer-nav">
                            <a href="#overview">Overview</a>
                            <a href="#identity">Config Fields</a>
                            <a href="#delivery">Delivery</a>
                            <a href="#automation">Operations</a>
                        </div>
                    </div>
                    <div className="footer-bottom">
                        <span>Detailed standalone agent configuration reference for Vibe web, native config, and external integrations.</span>
                        <span>AGENT_CONFIG</span>
                    </div>
                </div>
            </footer>
        </div>
    );
};

export default AgentConfigDocs;
