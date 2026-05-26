# Security & Privacy

## Core Principles

1. **End-to-End Encryption** — Messages encrypted on client, server never sees plaintext
2. **Zero Knowledge** — Server cannot access or decrypt user data
3. **Open Source** — All cryptography is auditable and verifiable
4. **No Tracking** — Zero analytics, no telemetry, no user profiling
5. **Privacy First** — Minimal data collection, maximum user control

---

## Encryption

### Message Encryption

**Algorithm**: TweetNaCl Box (Public-Key Cryptography)
- **Encryption**: XSalsa20
- **Authentication**: Poly1305
- **Key Exchange**: Curve25519

**Flow**:
```
User A wants to send message to User B:
1. Fetch User B's public key from server
2. Generate ephemeral key pair
3. Encrypt message using User B's public key
4. Send encrypted blob to server
5. Server stores encrypted data (cannot decrypt)
6. User B receives notification
7. Fetch encrypted message from server
8. Decrypt using private key (only User B can)
```

### Key Management

**Derivation**:
- User password → Argon2 (128 iterations, 64MB memory)
- Derived key used to unlock local private keys
- Keys never sent to server

**Storage**:
- **iOS**: Keychain (hardware-backed when available)
- **Android**: Android Keystore (hardware-backed when available)
- **Web**: IndexedDB with encryption layer
- **Server**: Never stores user private keys

### File Encryption

All uploaded media encrypted:
- **Algorithm**: AES-256-GCM
- **Key**: Derived from user's master key
- **IV**: Random per file
- **Auth Tag**: Prevents tampering

---

## Authentication

### Session Management

**JWT Tokens**:
- Access token: 15 minutes validity
- Refresh token: 7 days validity
- Automatic rotation on refresh
- Secure, HttpOnly cookies

**Flow**:
```
1. User login with email + password
2. Server verifies credentials (bcrypt + Argon2)
3. Issues JWT access + refresh tokens
4. Client stores tokens securely
5. Each request includes access token
6. Expired? Use refresh token to get new access token
7. Refresh token expired? Re-authenticate
```

### Password Security

- **Hashing**: bcrypt + Argon2 (double hashing)
- **Minimum**: 12 characters
- **Validation**: Server enforces NIST guidelines
- **Reset**: Email-based verification link (1 hour validity)
- **2FA**: Optional TOTP support

---

## Transport Security

### HTTPS/TLS

- **Minimum Version**: TLS 1.3
- **Certificates**: Let's Encrypt or CA-signed
- **HSTS**: Enabled (1 year)
- **Certificate Pinning**: Optional (iOS/Android)

### Certificate Validation

- **Client**: Verifies server certificate
- **Server**: Verifies client (optional mTLS)
- **Pinning**: Available for high-security deployments

---

## Data Protection

### Data Minimization

**Collected**:
- Email address
- Display name
- Public key
- Message timestamps

**Not Collected**:
- IP addresses (unless logging)
- Device identifiers
- Location data
- Usage analytics
- Behavioral data

### Data Retention

- **Deleted Messages**: Permanently removed from server
- **Accounts**: 30-day grace period before deletion
- **Logs**: Rotated after 30 days
- **Backups**: Encrypted, 7-day retention

### GDPR/Privacy Compliance

- ✅ Right to access data export
- ✅ Right to deletion
- ✅ Right to data portability
- ✅ Privacy policy included
- ✅ Terms of service provided

---

## Optional Privacy Features

### Tor Integration

Connect via Tor for network-level anonymity:

```bash
# Server configuration
TOR_ENABLED=true
TOR_SOCKS_PORT=9050
```

**Benefits**:
- Hide IP address
- Bypass regional blocks
- Prevent ISP monitoring
- Protect against traffic analysis

**Trade-offs**:
- Slower connection (2-3x latency)
- Some features may be limited

### Ephemeral Messages

Messages that auto-delete:
- Duration: User-configurable (5s to 24h)
- Server: Deletes after expiry
- Client: Clears from memory
- No screenshots possible (in future)

---

## Code Security

### Dependencies

- **Auditing**: `npm audit`, `mix audit`
- **Updates**: Regular security patches
- **Transparency**: CHANGELOG tracks changes
- **Pinning**: Exact versions locked (no auto-update)

### Input Validation

- **Client**: Frontend validation (UX only)
- **Server**: Strict validation on all inputs
- **Sanitization**: HTML escaping, SQL parameterization
- **Rate Limiting**: Prevent brute force attacks

### Error Handling

- **Generic Messages**: Don't leak internal details
- **Logging**: Sensitive data redacted
- **Monitoring**: Security alerts on anomalies
- **Incident Response**: Clear escalation procedure

---

## Attack Prevention

| Attack | Mitigation |
|--------|-----------|
| **Brute Force** | Rate limiting + account lockout |
| **SQL Injection** | Parameterized queries + input validation |
| **XSS** | Content Security Policy + escaping |
| **CSRF** | CSRF tokens on state-changing requests |
| **Man-in-the-Middle** | HTTPS + certificate pinning optional |
| **Side-Channel** | Constant-time comparisons for auth |

---

## Deployment Security

### Server Hardening

```bash
# Minimal services running
# Firewall rules (whitelist approach)
# SSH key-based auth only
# Fail2ban for attack prevention
# SELinux or AppArmor enabled
```

### Database Security

- **Backups**: Encrypted at rest
- **Replication**: TLS between servers
- **Access Control**: Least privilege
- **Audit Logging**: All data access tracked

### Secrets Management

- **API Keys**: Rotated quarterly
- **Certificates**: Renewed before expiry
- **Passwords**: Never in code/config
- **Environment**: `.env` files never committed

---

## Security Audit

### Self-Assessment

- ✅ Encryption reviewed
- ✅ Authentication tested
- ✅ Dependencies audited
- ✅ Code reviewed for vulnerabilities

### Third-Party Audits

Planned audits:
- [ ] Cryptography review (professional firm)
- [ ] Penetration testing (Q3 2026)
- [ ] Code audit (independent auditor)

### Bug Bounty

Report security issues to: security@vibegram.app

**Responsible Disclosure**:
1. Email security team
2. Allow 90 days for fix
3. Credit in announcement (if desired)
4. Bounty rewards available

---

## User Responsibilities

Users should:
- ✅ Use strong, unique passwords
- ✅ Keep devices updated
- ✅ Enable 2FA when available
- ✅ Verify contact information
- ✅ Report suspicious activity

---

## Transparency

We believe in security through transparency:
- Code is open source
- Security practices documented
- Vulnerability disclosures public (after fix)
- Annual security report published
