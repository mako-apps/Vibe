# Vibe

A privacy-first, decentralized chat and communication platform with end-to-end encryption, native mobile apps, and peer-to-peer connectivity.

## Features

- **End-to-End Encrypted Messaging** — All communications encrypted with no server-side access
- **Native Mobile Apps** — iOS and Android with call screens, push notifications, and offline support
- **Decentralized Architecture** — Optional Tor integration for enhanced privacy
- **Real-time Communication** — WebSocket-based chat, calls, and notifications
- **Media Sharing** — GIF search, image uploads, and encrypted file transfers
- **Cross-Platform** — Web client, iOS app, and Android app with unified experience

## Architecture

```
Vibe/
├── android/                    # Android native app (Kotlin)
│   ├── app/                   # Main app module
│   └── chat-module/           # Chat native module
├── ios/                        # iOS native app (Swift)
│   ├── ChatModule/            # Chat implementation
│   └── Sources/               # App structure
├── server/                     # Backend (Elixir/Phoenix)
│   ├── lib/
│   │   ├── vibe/              # Core business logic
│   │   └── vibe_web/          # API controllers & sockets
│   └── priv/repo/             # Database migrations
├── client/                     # Web client (TypeScript/React)
├── mobile/                     # React Native mobile (legacy)
└── scripts/                    # Build and deployment utilities
```

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **iOS** | Swift, SwiftUI |
| **Android** | Kotlin, Jetpack Compose |
| **Web** | TypeScript, React |
| **Backend** | Elixir, Phoenix Framework |
| **Database** | PostgreSQL |
| **Messaging** | WebSockets, MQTT |
| **Encryption** | TweetNaCl (nacl.js), libsodium |

## Getting Started

### Prerequisites
- Elixir 1.14+
- PostgreSQL 14+
- Node.js 18+
- Xcode 14+ (for iOS)
- Android Studio (for Android)

### Backend Setup
```bash
cd server
mix deps.get
mix ecto.create
mix ecto.migrate
mix phx.server
```

### Web Client
```bash
cd client
npm install
npm run dev
```

### iOS App
```bash
cd ios
pod install
# Open in Xcode and build
```

### Android App
```bash
cd android
./gradlew :app:assembleDebug
```

## Project Structure

- **`android/`** — Kotlin-based Android application with native modules for chat and calls
- **`ios/`** — SwiftUI-based iOS application with native chat implementation  
- **`server/`** — Elixir/Phoenix backend handling authentication, messaging, and real-time communications
- **`client/`** — TypeScript/React web client
- **`mobile/`** — Legacy React Native codebase (archived)
- **`docs/`** — Project documentation
- **`scripts/`** — Build and deployment helpers

## Security & Privacy

- All messages are end-to-end encrypted using modern cryptography (TweetNaCl)
- Server stores only encrypted content; no access to plaintext messages
- Optional Tor integration for network-level privacy
- Regular security audits and updates
- No analytics, tracking, or telemetry

## Contributing

1. Create a feature branch (`git checkout -b feature/amazing-feature`)
2. Commit changes (`git commit -m 'Add amazing feature'`)
3. Push to branch (`git push origin feature/amazing-feature`)
4. Open a Pull Request

## License

[Add appropriate license]

## Support

For issues, feature requests, or questions:
- GitHub Issues: [Link to issues]
- Documentation: See `docs/` directory
- Email: [Contact email]

---

**Note:** This project is in active development. APIs and features may change.
