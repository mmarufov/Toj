# iPhone staging run

Open `Toj.xcworkspace`, select the shared **Toj Staging** scheme, select a test
iPhone (iOS 26 or newer), and Run. Signing and Developer Mode must already be
available on that device. This scheme runs the existing Debug app with
`TOJ_CLOUD_BASE_URL=https://api.tojchat.tech`; REST routes are `/v1/...` and the
socket is `wss://api.tojchat.tech/v1/ws`. Do not append `/cloud`.

## Device/data boundary

This is a run scheme, **not a separately installed staging app**. It uses the
existing bundle ID, local database, and Keychain services. Use a dedicated test
device/simulator with no existing Toj data; do not install it over a real-use
copy or switch a signed-in installation between servers. Do not delete existing
data to make this work. A separately isolated app identity would require additional
signing, entitlements, extension, and storage configuration.

The endpoint persists after the first Xcode launch, so force-quit/reopen tests
keep using staging. It also remains in Debug preferences when changing schemes;
returning to the ordinary Debug scheme alone does not reset it. For a disposable
local-development installation, explicitly launch with the desired development
endpoint. Release still uses its unchanged bundled production endpoint, but that
does not isolate account data: keep production and staging on different devices.

## Login and verification

Use only the synthetic identities already configured in Render's exact OTP
allowlist. The existing login flow fills the code returned for those identities;
no SMS is sent and no real phone ownership is verified. Do not add real-user
numbers to this bypass or put tokens/keys/codes into the scheme or logs.

On two test devices, verify login, send/receive, offline catch-up, force-quit and
reopen, and history sync. These physical-device checks are separate from backend
smoke tests. Real SMS OTP must be integrated and tested before real-user admission.
Push and call infrastructure are not enabled by this scheme.

For the optional Telegram pilot, first deploy/configure the backend as described in
`server/STAGING.md`. On the staging login screen, explicitly enable **Receive my code
in Telegram** and use the approved owner's number. The code is entered manually from
Telegram; no SMS is sent and the server must have `TOJ_RETURN_OTP=0`. The toggle starts
off on a new app process and is absent from Release. Synthetic login stops working
while the Telegram pilot has disabled returned test codes. Security-change/account-deletion
OTP flows are not part of this login-only pilot.

The toggle appears whenever the configured endpoint's host is `api.tojchat.tech`. Exhausting the
request budget answers with a full-day retry hint; the resend countdown caps that at one hour and
switches to minutes, so the button is never parked for a day. If no code arrives, read the
server's `auth.otp.telegram_failed` tag described in `server/STAGING.md` — the client's generic
failure message deliberately says nothing about the provider.

The scheme does not pass its live endpoint to unit tests and has no Archive or
Profile action. Use the existing **Toj** scheme for production workflows. Neither
the original scheme nor the Debug/Release build settings are changed.
