# Architecture

## System Overview

Vibe is built on a **layered architecture** with clear separation of concerns between clients, transport, business logic, and data layers.

```
┌─────────────────────────────────────────────────────────┐
│                    CLIENT LAYER                          │
├──────────────────────┬──────────────────────┬────────────┤
│   iOS (Swift)        │  Android (Kotlin)    │  Web (TS)  │
│  - Native UI         │  - Native UI         │ - React    │
│  - Local Storage     │  - Local Storage     │ - SQLite   │
│  - Call Engine       │  - Call Engine       │ - WebRTC   │
└──────────────────────┴──────────────────────┴────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              TRANSPORT & SECURITY LAYER                  │
├─────────────────────────────────────────────────────────┤
│  WebSocket (realtime) │  HTTPS (REST) │ TweetNaCl (E2EE) │
│  Message Serialization│ Auth Tokens   │ Key Exchange      │
└─────────────────────────────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│                  API & BUSINESS LOGIC                    │
│              (Elixir/Phoenix Framework)                  │
├──────────────────┬──────────────┬──────────────────────┤
│  User Management │ Message Ops  │ Call Signaling       │
│  Auth (JWT)      │ Encryption   │ Media Upload         │
│  Profile Mgmt    │ Notifications│ Presence Tracking    │
└──────────────────┴──────────────┴──────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              DATA PERSISTENCE LAYER                      │
├──────────────────────┬──────────────────────────────────┤
│   PostgreSQL DB      │  File Storage (Encrypted)        │
│  - User Data        │  - Media Uploads                   │
│  - Chat History     │  - Backups                         │
│  - Relationships    │  - Keys & Secrets                  │
└──────────────────────┴──────────────────────────────────┘
```

## Components

### Frontend Layer

**iOS** (`/ios`)
- SwiftUI-based native app
- ChatModule for messaging
- Call engine for voice/video
- Push notification handling
- Offline message queuing

**Android** (`/android`)
- Kotlin with Jetpack Compose
- Native chat implementation
- Real-time call screens
- Firebase Cloud Messaging
- Local message storage

**Web** (`/client`)
- React 18 TypeScript SPA
- Vite for fast builds
- WebSocket support
- Local database (SQLite)

### Backend Layer

**Elixir/Phoenix** (`/server`)
- High-concurrency message broker
- Real-time WebSocket channels
- RESTful API endpoints
- Background job processing
- Encrypted storage layer
- Authentication (JWT)
- Media upload handling

### Data Layer

**PostgreSQL**
- User accounts & profiles
- Encrypted messages
- Chat history
- Relationships & blocks

**File Storage**
- Encrypted media uploads
- User backups
- Key management

## Data Flow

### Sending a Message

```
1. User A types message → Client encrypts with recipient's public key
2. Client sends encrypted message via WebSocket
3. Phoenix receives → validates user → stores encrypted blob
4. If recipient offline → message queued in Redis
5. When recipient comes online → system sends push notification
6. Recipient receives notification → fetches message
7. Client decrypts with private key → user sees plaintext
8. Server never sees unencrypted content
```

### Real-Time Updates

```
Phoenix Channel subscription
├── User A → User B (open chat)
├── System broadcasts typing indicator
├── Recipient sees "User A is typing..."
└── Message sent → instant delivery notification
```

## Security Architecture

### Encryption

- **Algorithm**: TweetNaCl Box (Curve25519 + XSalsa20 + Poly1305)
- **Key Exchange**: Elliptic curve Diffie-Hellman
- **Storage**: Keys derived from passwords using Argon2

### Authentication

- **Method**: JWT tokens with refresh rotation
- **Transport**: HTTPS/TLS for all connections
- **Session**: Redis-backed session management

### Data Protection

- **At Rest**: AES-256-GCM for encrypted storage
- **In Transit**: TLS 1.3 minimum
- **User Data**: Server cannot access plaintext messages

## Deployment Architecture

```
┌──────────────┐
│ Load Balancer│
│ (HTTPS/TLS)  │
└────────┬─────┘
         │
    ┌────┴────────────┬────────────┐
    │                 │            │
┌───▼────┐      ┌─────▼────┐  ┌──▼───┐
│Phoenix  │──┬───┤PostgreSQL│  │Redis │
│Server 1 │  │   │Database  │  │Cache │
└────┬────┘  │   └──────────┘  └──────┘
     │       │
┌────▼────┐  │
│Phoenix  │  │
│Server 2 │──┘
└────┬────┘
     │
┌────▼──────────────┐
│File Storage       │
│(Encrypted Uploads)│
└───────────────────┘
```

## Scalability

- **Horizontal**: Multiple Phoenix instances behind load balancer
- **Caching**: Redis for session & message caching
- **Database**: PostgreSQL with read replicas
- **Media**: S3-compatible object storage
- **Real-time**: Phoenix PubSub with distributed mode

## Performance Optimization

- WebSocket connection pooling
- Message batching for bulk operations
- Database query optimization with indexes
- Client-side caching with offline support
- CDN for static assets
- Asset compression (gzip/brotli)
