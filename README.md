# 💬 Vibe

> **Privacy-first decentralized chat platform with end-to-end encryption, native mobile apps, and peer-to-peer connectivity**

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/Vibe-source/Vibe?style=flat-square)](https://github.com/Vibe-source/Vibe)
[![GitHub License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android%20%7C%20Web-blue?style=flat-square)](#)

[Features](#features) • [Quick Start](#quick-start) • [Documentation](#documentation) • [Contributing](#contributing)

</div>

---

## Features

🔐 **Military-Grade Encryption** — End-to-end encrypted messaging with zero server-side access  
📱 **Native Mobile Apps** — iOS (Swift) and Android (Kotlin) with push notifications & calls  
🌐 **Cross-Platform** — Seamless experience on iOS, Android, and Web  
🔗 **Private & Secure** — Optional Tor integration, no analytics or tracking  
⚡ **Real-Time** — Instant messaging, voice/video calls, and live presence  
📎 **Rich Media** — GIF search, encrypted file transfers, and reactions  

---

## Quick Start

### Prerequisites
- **Elixir** 1.14+ & Erlang 25+
- **PostgreSQL** 14+
- **Node.js** 18+
- **Xcode** 14+ (iOS)
- **Android Studio** (Android)

### Backend
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

### iOS
```bash
cd ios
xcodegen generate      # Generates .xcodeproj from project.yml
pod install
open Vibe.xcworkspace
```

### Android
```bash
cd android
./gradlew assembleDebug
```

---

## Documentation

- **[Architecture](docs/architecture.md)** — System design, data flow, security
- **[Getting Started](docs/getting-started.md)** — Detailed setup guide for all platforms
- **[Deployment](docs/deployment.md)** — Docker, Railway, self-hosted options
- **[Contributing](docs/contributing.md)** — Development workflow and guidelines
- **[API Reference](docs/api.md)** — REST & WebSocket endpoints
- **[Security](docs/security.md)** — Encryption, key management, privacy

---

## Project Structure

```
vibe/
├── android/              # Android Kotlin app
├── ios/                  # iOS Swift app
├── server/               # Elixir/Phoenix backend
├── client/               # React web app
├── scripts/              # Build utilities
├── docs/                 # Documentation
└── README.md
```

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **iOS** | Swift 5.9, SwiftUI |
| **Android** | Kotlin, Jetpack Compose |
| **Web** | React 18, TypeScript |
| **Backend** | Elixir 1.14, Phoenix 1.7 |
| **Database** | PostgreSQL 14 |
| **Real-time** | WebSocket (Phoenix Channels) |
| **Encryption** | TweetNaCl.js / libsodium |

---

## Security & Privacy

🔒 **End-to-End Encryption** — All messages encrypted client-side  
🔐 **Zero Knowledge** — Server cannot access plaintext messages  
📊 **No Telemetry** — Zero analytics, tracking, or data collection  
🛡️ **Auditable** — All cryptography is open-source  
🌐 **Optional Tor** — Network-level anonymity available  

---

## Contributing

We welcome contributions! See [Contributing Guide](docs/contributing.md) for details.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit with clear messages
4. Push and create a Pull Request

---

## License

MIT License - see [LICENSE](LICENSE) file

---

## Support

- 📖 **Docs:** See `/docs` directory
- 🐛 **Issues:** [GitHub Issues](https://github.com/Vibe-source/Vibe/issues)
- 💬 **Discussions:** [GitHub Discussions](https://github.com/Vibe-source/Vibe/discussions)

---

**⭐ Star us on GitHub if you find Vibe useful!**

Built with ❤️ by the Vibe team.
