# Contributing to Toj

Thanks for looking. Toj is a product codebase that is developed in the open so
that the way it handles people's messages can be inspected rather than taken on
trust.

## What we are looking for

| | |
| --- | --- |
| **Security reports** | Very welcome. Follow the [security policy](SECURITY.md) — privately, not as an issue. |
| **Bug reports** | Welcome. Open an issue with the steps you took and what happened instead. |
| **Correctness and design feedback** | Welcome. Open an issue; a good argument about the data model or the network behaviour is genuinely useful. |
| **Unsolicited pull requests** | Generally not merged. See below. |

Toj is pre-launch, and the areas that look most inviting to contribute to —
crypto, sync, transport — are the ones where an unreviewed change is most
expensive. We would rather discuss a problem in an issue first and then decide
who writes the fix. If you want to send code anyway, open an issue first so the
work is not wasted.

## Running the project

Build and test instructions are in the [README](../README.md#getting-started).
The short version:

```bash
scripts/fetch-webrtc-xcframework.sh   # pinned, checksum- and provenance-verified
pod install
open Toj.xcworkspace                  # scheme: Toj
```

```bash
cd server && bun install && createdb toj_dev && bun run migrate
```

The backend suite needs its own migrated `toj_test` database and runs one file
at a time — a single parallel `bun test` is not reliable. The exact commands are
in the [README](../README.md#tests).

## Engineering conventions

These are the rules the codebase is held to. A change that breaks one of them
will not pass review.

**Offline-first.** The encrypted on-device store is the UI's source of truth.
The UI renders from local data instantly and never blocks on the network.

**Never block the main thread.** All I/O, cryptography and networking is
asynchronous and cancellable. Assume the connection drops mid-operation, because
on the target network it does. Sends are optimistic: the message appears
immediately and is confirmed later.

**Never roll your own crypto.** Standard AEAD and KMS primitives for data at
rest; [libsignal](https://github.com/signalapp/libsignal) for end-to-end.

**Treat all message content as secret.** Never log plaintext, keys, or full
phone numbers. Be deliberate about what crosses to the server at all.

**Row absence is load-bearing.** Any table whose *missing* row changes a
security or rate-limit decision must carry a comment naming that dependency and
a test pinning both directions — row present and row absent. This includes TTL
constants: when you set an expiry, state what happens to a client that comes
back *after* it on a 100–500 kbps congested link. If that outcome is
destructive, the expiry is wrong.

**Match the surrounding style.** Keep views small and push logic out of views
into testable types.

**Check the docs, do not guess the API.** SwiftUI 26, LibSignalClient and
LiveKit all move; verify against current documentation rather than memory.

## Tests

New behaviour needs tests. New test files must be registered with the Xcode
project — `TojTests` is a classic group and does not pick files up
automatically:

```bash
GEM_HOME=$(brew --prefix cocoapods)/libexec \
  $(brew --prefix ruby)/bin/ruby scripts/add_test_files.rb
```

The app's `Toj/` folder is a synchronized group and does pick up new files
automatically.

## Pull requests

If a maintainer has asked you for a PR:

- Keep it to one reviewable change.
- Make sure all three CI jobs pass — backend, iOS, and repository policy.
- GitHub Actions must be referenced by full commit SHA. CI fails the build
  otherwise.
- Write the description for someone who was not in the conversation that
  produced the change.

**Get it right before pushing.** This repository is public. A force-push does
not remove the old commit — GitHub keeps the object and publishes the previous
SHA in the pull request timeline, and editing a description only hides the
earlier revision behind an "edited" marker. Anything sensitive enough that you
would want to amend it out is sensitive enough that amending will not be enough.

## Code of conduct

Be straightforward and civil. Argue with the code, not the person. Maintainers
may close or block anything that turns the project into an unpleasant place to
work.
