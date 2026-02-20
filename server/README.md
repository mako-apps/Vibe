# Vibe Backend (Elixir/Phoenix)

This is the Elixir port of the Vibe backend.

## Prerequisites
- Elixir 1.14+
- PostgreSQL

## Setup

1. Install dependencies:
   ```bash
   mix deps.get
   ```

2. Setup Database:
   ```bash
   mix ecto.setup
   ```

3. Start Server:
   ```bash
   mix phx.server
   ```

## API Compatibility

The API endpoints have been designed to match the Node.js backend:
- `POST /api/login`
- `POST /api/register`
- `GET /api/user/:id`
- `POST /api/chat`
- ...and others.

## WebSocket Note

The frontend uses `socket.io-client` which is specific to the Node.js `socket.io` library. Phoenix uses `Phoenix Channels` which runs on WebSockets but has a different protocol.

To fully migrate the real-time features, you have two options:
1. **Recommended**: Update the React frontend to use `phoenix.js` client instead of `socket.io-client`.
2. **Alternative**: Use an Elixir Socket.IO adapter (experimental).

Currently, this backend implements standard Phoenix Channels at `ws://localhost:4000/socket`.
