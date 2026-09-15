# Third-party notices

Toj incorporates the third-party software listed below. Each component remains
under its own license, which is not superseded by Toj's [LICENSE](LICENSE).
Licenses were read from the resolved dependencies in this repository —
`Podfile.lock` and `Toj.xcworkspace/xcshareddata/swiftpm/Package.resolved` — not
from memory.

## Linked into the iOS app

| Component | Version | License | Source |
| --- | --- | --- | --- |
| LibSignalClient | 0.96.4 | **AGPL-3.0-only** | [signalapp/libsignal](https://github.com/signalapp/libsignal) |
| GRDB.swift (SQLCipher) | 6.24.1 | MIT | [groue/GRDB.swift](https://github.com/groue/GRDB.swift) |
| SQLCipher | 4.10.0 | BSD-3-Clause (Zetetic LLC) | [sqlcipher/sqlcipher](https://github.com/sqlcipher/sqlcipher) |
| WebRTC (`TojWebRTC`) | pinned build | BSD-3-Clause + IP rights grant | [webrtc.googlesource.com](https://webrtc.googlesource.com/src) |
| LiveKit `client-sdk-swift` | pinned revision | Apache-2.0 | [livekit/client-sdk-swift](https://github.com/livekit/client-sdk-swift) |
| `livekit-uniffi-xcframework` | 0.0.5 | Apache-2.0 | [livekit/livekit-uniffi-xcframework](https://github.com/livekit/livekit-uniffi-xcframework) |
| `webrtc-xcframework` | 144.7559.3 | MIT (wrapper; WebRTC itself BSD-3-Clause) | [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) |
| SwiftProtobuf | 1.38.1 | Apache-2.0 | [apple/swift-protobuf](https://github.com/apple/swift-protobuf) |

Full license texts ship with the built app via the CocoaPods acknowledgements
plist and the vendored `Dependencies/TojWebRTC/LICENSE`.

## Backend

| Component | License | Source |
| --- | --- | --- |
| `pg` | MIT | [brianc/node-postgres](https://github.com/brianc/node-postgres) |
| `sharp` | Apache-2.0 | [lovell/sharp](https://github.com/lovell/sharp) |
| `ipaddr.js` | MIT | [whitequark/ipaddr.js](https://github.com/whitequark/ipaddr.js) |

## Fonts

| Component | License |
| --- | --- |
| Onest | SIL Open Font License 1.1 — [`Toj/Resources/Fonts/OFL-Onest.txt`](Toj/Resources/Fonts/OFL-Onest.txt) |

---

## Open question: AGPL and shipping a closed-source binary

**This is unresolved and needs a decision before Toj is distributed.** It is
recorded here rather than left implicit.

LibSignalClient is **AGPL-3.0-only**, and it is linked into the `Toj` target
today — `Podfile` pulls it unconditionally and `Toj/Core/Crypto/` uses it. The
AGPL is a strong copyleft license whose obligations attach when a combined or
derivative work is *conveyed* to others. Toj has not been distributed, so no
obligation has been triggered yet; publishing a closed-source build to the App
Store is what would raise the question. This is not incidental to Toj's design —
libsignal is the intended engine for Secret Chats.

This is a legal question, not an engineering one, and it should be put to a
lawyer rather than settled in a repository file. The realistic options are:

1. **License Toj's own source under AGPL-3.0** and publish it. This is what
   Signal does for its own iOS client, and it resolves the conflict directly. It
   means competitors may fork Toj.
2. **Remove libsignal** and drop or re-implement Secret Chats on a
   permissively licensed primitive. This keeps the proprietary position but
   gives up the reviewed, audited protocol implementation.
3. **Obtain a commercial license or written exception from Signal.** Preserves
   both the proprietary position and libsignal, and depends entirely on Signal
   agreeing.

Until this is decided, nothing is broken: Toj is pre-launch and undistributed.
The decision should be made before a build leaves the team, not after.
