# Contributing Guide

We welcome contributions from developers of all skill levels! This guide will help you get started.

## Code of Conduct

- Be respectful and inclusive
- Welcome diverse perspectives
- Focus on the code, not the person
- Help others learn and grow

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork**: `git clone https://github.com/YOUR_USERNAME/Vibe.git`
3. **Add upstream**: `git remote add upstream https://github.com/Vibe-source/Vibe.git`
4. **Create a branch**: `git checkout -b feature/your-feature`
5. **Make changes** and test locally
6. **Push to your fork**: `git push origin feature/your-feature`
7. **Create a Pull Request** on GitHub

---

## Development Setup

See [Getting Started](getting-started.md) for detailed setup instructions.

Quick check:
```bash
# Backend
cd server && mix test

# Web
cd client && npm test

# iOS
cd ios && xcodebuild test -scheme Vibe

# Android
cd android && ./gradlew test
```

---

## Commit Guidelines

### Message Format

```
type(scope): brief description

Longer explanation if needed.
Explain WHY, not WHAT.

Fixes #123
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `style`: Code style (formatting, missing semicolons)
- `refactor`: Code restructuring
- `perf`: Performance improvement
- `test`: Adding/updating tests
- `chore`: Build, dependencies, maintenance

**Scope**: Component affected (e.g., `auth`, `messages`, `calls`)

**Examples**:
```
feat(messages): add message reactions
fix(auth): prevent token expiration on refresh
docs(api): document WebSocket events
```

### Commit Best Practices

- One logical change per commit
- Keep commits focused and small
- Write clear, descriptive messages
- Don't include unrelated changes
- Test before committing

---

## Pull Request Process

### Before Submitting

1. **Sync with upstream**:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Test all changes**:
   ```bash
   # Run relevant tests
   mix test          # Backend
   npm test          # Web
   ```

3. **Code quality**:
   ```bash
   mix credo         # Elixir
   npm run lint      # TypeScript
   swiftlint         # Swift
   ktlint            # Kotlin
   ```

4. **Update documentation** if needed

### PR Description

```markdown
## Description
Briefly describe the changes.

## Type of Change
- [ ] New feature
- [ ] Bug fix
- [ ] Documentation update

## Testing
How was this tested?

## Checklist
- [ ] Tests pass locally
- [ ] Code follows style guide
- [ ] Documentation updated
- [ ] No breaking changes
```

### Review Process

- Maintainers review within 48 hours
- Address feedback promptly
- Discuss disagreements respectfully
- Request re-review after changes

### Merge Requirements

- ✅ All tests passing
- ✅ Code review approval
- ✅ No conflicts with main
- ✅ Commits squashed if needed

---

## Coding Standards

### Elixir

```elixir
# Good: Descriptive names, proper formatting
defmodule Vibe.Users.Service do
  def authenticate(email, password) do
    user = Repo.get_by(User, email: email)
    
    case Argon2.check_pass(user, password) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, "Invalid credentials"}
    end
  end
end
```

Guidelines:
- Use descriptive function names
- Keep functions small and focused
- Test all edge cases
- Add @doc when needed

### TypeScript/React

```typescript
// Good: Types, error handling, clear intent
interface UserState {
  id: string
  email: string
  loading: boolean
}

async function fetchUser(id: string): Promise<User> {
  try {
    const response = await api.get(`/users/${id}`)
    return response.data
  } catch (error) {
    console.error('Failed to fetch user:', error)
    throw error
  }
}
```

Guidelines:
- Always use TypeScript types
- Handle errors explicitly
- Keep components under 300 lines
- Use functional components

### Swift

```swift
// Good: Clear syntax, proper error handling
struct ChatViewModel {
    @State private var messages: [Message] = []
    @State private var isLoading = false
    
    func loadMessages() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            messages = try await chatService.fetchMessages()
        } catch {
            print("Error loading messages: \(error)")
        }
    }
}
```

Guidelines:
- Use modern Swift concurrency (async/await)
- Proper error handling
- MARK comments for organization
- Follow Apple's style guide

### Kotlin

```kotlin
// Good: Null safety, proper scope functions
class ChatViewModel : ViewModel() {
    private val _messages = MutableStateFlow<List<Message>>(emptyList())
    val messages: StateFlow<List<Message>> = _messages.asStateFlow()
    
    fun loadMessages() {
        viewModelScope.launch {
            try {
                val msgs = chatService.fetchMessages()
                _messages.value = msgs
            } catch (e: Exception) {
                Log.e("ChatViewModel", "Failed to load messages", e)
            }
        }
    }
}
```

Guidelines:
- Use Kotlin coroutines
- Leverage null safety features
- Follow official style guide
- Use appropriate scope functions

---

## Testing

### Test Structure

```
backend:        server/test/
web:            client/src/**/*.test.ts
ios:            ios/Tests/
android:        android/app/src/test/
```

### Test Requirements

- Minimum 80% coverage for new code
- Unit tests for business logic
- Integration tests for APIs
- UI tests for important flows

### Running Tests

```bash
# Backend
cd server
mix test                        # All tests
mix test --cover               # With coverage
mix test test/path_test.exs    # Specific file

# Web
npm test                        # All tests
npm test -- --coverage         # With coverage
npm test -- --watch            # Watch mode

# iOS
xcodebuild test -scheme Vibe

# Android
./gradlew test
./gradlew connectedAndroidTest
```

---

## Documentation

### When to Update

- New features
- API changes
- Important fixes
- Setup/installation changes

### Style

- Clear, concise language
- Code examples for technical content
- Link to related docs
- Update table of contents

### File Structure

```
docs/
├── README.md           # Overview
├── getting-started.md  # Setup guide
├── architecture.md     # System design
├── api.md              # API reference
├── security.md         # Security info
└── contributing.md     # This file
```

---

## Reporting Issues

### Bug Reports

Include:
- Clear description
- Steps to reproduce
- Expected behavior
- Actual behavior
- System info (OS, version, etc.)

### Feature Requests

Include:
- Clear motivation
- Use case examples
- Proposed solution (optional)
- Alternative approaches (if applicable)

---

## Questions?

- 📖 Check docs first
- 🔍 Search closed issues
- 💬 Start a discussion
- 📧 Email security@vibegram.app (security issues)

---

## Recognition

Contributors will be:
- Added to CONTRIBUTORS.md
- Mentioned in release notes
- Recognized in annual report

Thank you for contributing to Vibe! 🎉
