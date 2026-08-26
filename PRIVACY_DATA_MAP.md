# Toj Privacy Data Map

This file is the repository source of truth for `PrivacyInfo.xcprivacy`, App Store Connect privacy answers, and the published privacy policy. Every row beginning with an `NSPrivacyCollectedDataType` identifier is machine-checked by `scripts/verify-privacy-manifest.py`.

All listed data is used for app functionality and is not used for tracking. “Linked” means the service can associate the retained data with a Toj account. Retention is bounded by account deletion, message deletion, or the server cleanup policies described below; production policy text must publish the same rules before App Store submission.

| Manifest identifier | Linked | Data and collection point | Destination | Retention and App Store Connect answer |
|---|---:|---|---|---|
| NSPrivacyCollectedDataTypeName | true | Display name supplied during sign-in or profile editing | Toj API and PostgreSQL | Account lifetime; Contact Info / Name / App Functionality |
| NSPrivacyCollectedDataTypePhoneNumber | true | Phone identity supplied for OTP authentication | OTP provider, Toj API, encrypted PostgreSQL value plus blind index | Account lifetime and bounded authentication logs; Contact Info / Phone Number / App Functionality |
| NSPrivacyCollectedDataTypeContacts | true | Individual address-book phone numbers submitted for contact discovery | Toj API; requester-linked, HMAC-protected lookup attempts | Bounded lookup-abuse window; Contacts / App Functionality |
| NSPrivacyCollectedDataTypePreciseLocation | true | One-shot current coordinates selected by the user and inserted into a cloud message as an Apple Maps link | CoreLocation on device, then Toj API and encrypted cloud-message storage when sent | Until the resulting message is deleted; Location / Precise Location / App Functionality |
| NSPrivacyCollectedDataTypeEmailsOrTextMessages | true | Cloud-chat text, captions, replies, drafts, and report evidence | Toj API and encrypted PostgreSQL storage | Until user deletion or applicable safety retention; User Content / Emails or Text Messages / App Functionality |
| NSPrivacyCollectedDataTypePhotosorVideos | true | Profile photos and cloud-chat photo/video uploads | Toj API and encrypted media storage | Until profile replacement, message/media deletion, or account cleanup; User Content / Photos or Videos / App Functionality |
| NSPrivacyCollectedDataTypeAudioData | true | Voice notes uploaded to cloud chats | Toj API and encrypted media storage | Until message/media deletion or account cleanup; User Content / Audio Data / App Functionality |
| NSPrivacyCollectedDataTypeOtherUserContent | true | Files, profile biography, group titles, report reasons/details, and bounded safety evidence | Toj API and PostgreSQL/encrypted media storage | Feature-specific deletion; report evidence is removed 90 days after resolution; User Content / Other User Content / App Functionality |
| NSPrivacyCollectedDataTypeUserID | true | Toj account and dialog membership identifiers | Toj API and PostgreSQL | Account and integrity-record lifetime; Identifiers / User ID / App Functionality |
| NSPrivacyCollectedDataTypeDeviceID | true | Device/session identifiers and APNs/PushKit registrations | Toj API, Apple Push Notification service, PostgreSQL | Until device revocation, token replacement, or account deletion; Identifiers / Device ID / App Functionality |
| NSPrivacyCollectedDataTypeProductInteraction | true | Read state, message activity, presence/typing state, call history/metadata, group activity, and safety-report actions | Toj API and PostgreSQL | Feature and operational retention windows; Usage Data / Product Interaction / App Functionality |
| NSPrivacyCollectedDataTypeOtherDataTypes | true | Optional birthday and profile attributes not covered by another Apple category | Toj API and PostgreSQL | Account lifetime or profile removal; Other Data / App Functionality |
| NSPrivacyCollectedDataTypePerformanceData | false | Sanitized call-quality buckets without message content, keys, SDP, candidates, phone numbers, or raw audio | Toj operational metrics | Short operational retention; Diagnostics / Performance Data / App Functionality |

## Field-level collection map

This table is the human-reviewable release inventory. “None” in the processor column means the data
does not leave Toj-controlled services through that collection path. Authentication, authorization,
rate-limit, and deduplication receipts are covered separately from the de-identified metric payload
they protect.

| Field or flow | Collection point | Toj destination | Third-party or processor | Retention | Linked | Purpose | Manifest / App Store Connect |
|---|---|---|---|---|---:|---|---|
| Display name | Sign-in and profile editor | Account profile in PostgreSQL | None | Account lifetime or profile edit | true | App Functionality | Name / Contact Info |
| Profile biography and birthday | Profile editor | Account profile in PostgreSQL | None | Account lifetime or field removal | true | App Functionality | OtherDataTypes / Other Data |
| Profile photo | Profile editor upload | Encrypted Toj media storage and profile reference | None | Replacement, explicit removal, or account cleanup | true | App Functionality | PhotosorVideos / User Content |
| E.164 phone number | OTP sign-in and account-deletion verification | Envelope-encrypted identity plus versioned blind index | Configured SMS delivery processor receives the number and one-time code | Account lifetime; OTP delivery and abuse records follow their bounded windows | true | App Functionality | PhoneNumber / Contact Info |
| OTP code, salted verifier, and request fingerprint | Authentication flow | Short-lived PostgreSQL challenge and abuse-control records | Configured SMS delivery processor receives the one-time code | Challenge expiry and bounded security-log window | true | App Functionality | OtherDataTypes / Other Data |
| Selected contact phone number | Explicit contact discovery | Versioned blind-index lookup and requester-linked abuse receipt | None; the address book itself is not uploaded | Bounded lookup-abuse window | true | App Functionality | Contacts / Contacts |
| Selected contact card attachment | Explicit contact-share picker | Encrypted message media | None | Until message/media deletion or account cleanup | true | App Functionality | OtherUserContent / User Content |
| Current latitude and longitude | Explicit Location attachment action via CoreLocation | Rendered into an Apple Maps URL inside an encrypted cloud-message body | Apple provides the on-device location service; opening the resulting link is a separate Apple Maps action | Until the message is deleted | true | App Functionality | PreciseLocation / Location |
| Cloud message body, caption, reply, mention, and edit | Composer and message actions | Envelope-encrypted message row and sync events | Apple receives only opaque push notification transport when enabled | Until message deletion or account/message retention cleanup | true | App Functionality | EmailsOrTextMessages / User Content |
| Cloud draft text and attachment references | Composer autosave and cross-device draft sync | Envelope-encrypted draft and bounded encrypted idempotency response | None | Until send, clear, replacement, or account cleanup | true | App Functionality | EmailsOrTextMessages / User Content |
| Photos and videos | Profile/chat camera or photo picker | Encrypted Toj media objects, thumbnails, and chunks | Apple photo/camera frameworks provide local selection/capture; APNs carries no media payload | Until reference deletion or account cleanup | true | App Functionality | PhotosorVideos / User Content |
| Voice-note audio | Chat recorder | Encrypted Toj media objects and chunks | None | Until message/media deletion or account cleanup | true | App Functionality | AudioData / User Content |
| Files and file names | File/contact attachment picker | Encrypted Toj media bytes and encrypted file-name metadata | Source document provider chosen by the user | Until message/media deletion or account cleanup | true | App Functionality | OtherUserContent / User Content |
| Group title and profile metadata | Group creation/profile editor | Encrypted title where applicable plus membership metadata | None | Group lifetime or explicit change/deletion | true | App Functionality | OtherUserContent / User Content |
| Safety reason and optional details | Report form | Abuse report workflow row; details exist only inside encrypted evidence | None | Unresolved until resolution; content evidence removed 90 days after resolution | true | App Functionality | OtherUserContent / User Content |
| Server-selected safety evidence | `POST /v1/reports` after membership/subject authorization | Moderation-service envelope-encrypted snapshot and encrypted operator notes | None | Unresolved until resolution; content removed after 90 days; non-content audit metadata after 365 days | true | App Functionality | EmailsOrTextMessages, PhotosorVideos, AudioData, OtherUserContent / User Content |
| Account, dialog, message, and membership identifiers | Authentication and messaging APIs | PostgreSQL identity, authorization, sync, and integrity rows | Apple receives device-scoped opaque push delivery identifiers where push is enabled | Account/feature lifetime and integrity-retention windows | true | App Functionality | UserID / Identifiers |
| Device/session ID and bearer-token blind index | Sign-in and device management | Device/session rows and versioned opaque-token index | None | Until revocation, replacement, or account deletion | true | App Functionality | DeviceID / Identifiers |
| APNs and PushKit tokens | Apple registration callbacks | Envelope-encrypted token plus versioned digest | Apple Push Notification service | Until replacement, device revocation, ban, or account deletion | true | App Functionality | DeviceID / Identifiers |
| Online presence, last-seen timestamp, and typing activity | Authenticated foreground and conversation activity | Short presence leases, account presence revision/state, and ephemeral authorized typing broadcasts | None | Typing expires within seconds; leases expire after missed heartbeats; last-seen state remains until newer activity or account cleanup | true | App Functionality | ProductInteraction / Usage Data |
| Read state, message mutations, call history, group activity, and safety workflow state | Normal feature use | PostgreSQL sync, lifecycle, budget, and audit rows | Apple receives only the push delivery needed to wake an eligible device | Feature-specific retention; call metadata 30 days; report audit metadata 365 days after resolution | true | App Functionality | ProductInteraction / Usage Data |
| Sanitized call outcome and quality buckets | One terminal call telemetry submission | Low-cardinality operational log without call, account, device, phone, SDP, candidate, key, or media identifiers | Operational logging/metrics processor only if configured under the same no-tracking contract | Short operational metrics window | false | App Functionality | PerformanceData / Diagnostics |
| Call telemetry authorization/deduplication receipt | Authenticated telemetry ingress | Call/device receipt used only to authorize one submission | None | Call lifecycle/cleanup window | true | App Functionality | ProductInteraction and DeviceID / Usage Data and Identifiers |

## Explicit exclusions in the current release

- Coarse-only location as a separate collection category: location sharing can receive precise coordinates, so the more protective precise-location declaration is used.
- Search history: message search is performed and stored locally on the device.
- Advertising and tracking: Toj has no advertising or cross-company tracking path; `NSPrivacyTracking` is false.
- Crash data: no crash-reporting SDK is currently shipped.
- Live call media: call audio/video is handled in real time and is not retained as collected call content. Uploaded voice notes and chat media are declared separately above.

Any change that adds one of these flows must update this map, the manifest, App Store Connect answers, and the public privacy policy in the same release.
