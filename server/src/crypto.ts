import {
  createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual,
} from "node:crypto";
import {
  activeBlindIndex,
  blindIndexCandidates,
  blindIndexForKey,
  type VersionedBlindIndex,
} from "./blind-index";

// Encryption-at-rest for cloud message bodies (Company A: server CAN decrypt, but disk is never
// plaintext). AES-256-GCM, key_id + random 96-bit nonce + MANDATORY AAD binding the ciphertext to
// its (dialog, msg, sender) slot so rows can't be relocated (review S1).
// Legacy dev-v1 compatibility only. Production envelope mode rejects this path for new writes.

const KEY_ID = "dev-v1";
const TAG_LEN = 16;

function requireOrDev(envName: string, devByte: number): Buffer {
  const b64 = process.env[envName];
  if (b64) {
    const key = Buffer.from(b64, "base64");
    if (key.length !== 32) {
      key.fill(0);
      throw new Error(`${envName} must decode to 32 bytes`);
    }
    return key;
  }
  if (process.env.NODE_ENV === "production") throw new Error(`${envName} required in production`);
  return Buffer.alloc(32, devByte); // deterministic dev-only key; NEVER ships to prod
}

let cachedLegacyKey: { signature: string; key: Buffer } | null = null;
let cachedProtocolIdentifierKey: { signature: string; key: Buffer } | null = null;

function legacyMessageKey(): Buffer {
  // Cache invalidation needs an equality token, not another long-lived copy of the raw secret.
  const signature = createHash("sha256").update(JSON.stringify([
    process.env.NODE_ENV ?? "",
    process.env.TOJ_MESSAGE_KEY ?? "",
  ])).digest("hex");
  if (cachedLegacyKey?.signature === signature) return cachedLegacyKey.key;
  const previous = cachedLegacyKey;
  cachedLegacyKey = null;
  previous?.key.fill(0);
  const key = requireOrDev("TOJ_MESSAGE_KEY", 0x07);
  cachedLegacyKey = { signature, key };
  return cachedLegacyKey.key;
}

/** Legacy/canary startup requires this key; final envelope mode loads it only for an actual read. */
export function assertLegacyMessageKeyConfigured(): void {
  void legacyMessageKey();
}

/**
 * Media-group fallback IDs are durable wire-protocol state. Their derivation key is deliberately
 * independent from the rotating blind-index keyring. Before disabling legacy-v1 in production,
 * operators set TOJ_PROTOCOL_ID_KEY to the existing TOJ_HMAC_KEY value to preserve old retry IDs.
 */
function protocolIdentifierKey(): Buffer {
  const signature = createHash("sha256").update(JSON.stringify([
    process.env.NODE_ENV ?? "",
    process.env.TOJ_PROTOCOL_ID_KEY ?? "",
    process.env.TOJ_HMAC_KEY ?? "",
    process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED ?? "",
  ])).digest("hex");
  if (cachedProtocolIdentifierKey?.signature === signature) {
    return cachedProtocolIdentifierKey.key;
  }
  const previous = cachedProtocolIdentifierKey;
  cachedProtocolIdentifierKey = null;
  previous?.key.fill(0);
  const explicit = process.env.TOJ_PROTOCOL_ID_KEY;
  if (!explicit && process.env.NODE_ENV === "production"
    && process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED === "1") {
    throw new Error("TOJ_PROTOCOL_ID_KEY required before disabling the legacy blind-index key");
  }
  const configured = explicit ?? process.env.TOJ_HMAC_KEY;
  const key = configured
    ? Buffer.from(configured, "base64")
    : process.env.NODE_ENV === "production"
      ? (() => { throw new Error("TOJ_HMAC_KEY required in production"); })()
      : Buffer.alloc(32, 0x0b);
  if (key.length !== 32) {
    key.fill(0);
    throw new Error(`${explicit ? "TOJ_PROTOCOL_ID_KEY" : "TOJ_HMAC_KEY"} must decode to 32 bytes`);
  }
  cachedProtocolIdentifierKey = { signature, key };
  return key;
}

export function assertProtocolIdentifierConfiguration(): void {
  void protocolIdentifierKey();
}

export function mediaGroupClientMessageIdDigest(clientGroupId: string, index: number): Buffer {
  return createHmac("sha256", protocolIdentifierKey())
    .update(`toj/request-fingerprint/media-group-client-message-id/v1|${clientGroupId}:${index}`)
    .digest();
}

export type Sealed = { keyId: string; nonce: Buffer; ciphertext: Buffer };

export function seal(plaintext: Buffer | string, aad: Buffer): Sealed {
  const key = legacyMessageKey();
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(aad);
  const pt = typeof plaintext === "string" ? Buffer.from(plaintext, "utf8") : plaintext;
  const enc = Buffer.concat([cipher.update(pt), cipher.final()]);
  return { keyId: KEY_ID, nonce, ciphertext: Buffer.concat([enc, cipher.getAuthTag()]) };
}

export function open(sealed: Sealed, aad: Buffer): Buffer {
  if (sealed.keyId !== KEY_ID) throw new Error(`unknown key_id ${sealed.keyId}`);
  const key = legacyMessageKey();
  const { ciphertext, nonce } = sealed;
  const tag = ciphertext.subarray(ciphertext.length - TAG_LEN);
  const enc = ciphertext.subarray(0, ciphertext.length - TAG_LEN);
  const d = createDecipheriv("aes-256-gcm", key, nonce);
  d.setAAD(aad);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(enc), d.final()]);
}

/** Binds a message body to its exact slot; any mismatch fails GCM verification. */
export function bodyAAD(dialogId: string, msgId: number | bigint, senderId: string): Buffer {
  return Buffer.from(`toj/msg|${dialogId}|${msgId}|${senderId}`, "utf8");
}

/** Poll payloads have a distinct namespace so ciphertext cannot be swapped with message bodies. */
export function pollAAD(dialogId: string, msgId: number | bigint): Buffer {
  return Buffer.from(`toj/poll|${dialogId}|${msgId}`, "utf8");
}

/** Binds an encrypted cloud draft body to one account/dialog server revision. */
export function draftBodyAAD(accountId: string, dialogId: string, revision: number | bigint): Buffer {
  return Buffer.from(`toj/draft|${accountId}|${dialogId}|${revision}`, "utf8");
}

/** Keeps the cached response for an idempotent draft operation encrypted at rest as well. */
export function draftResponseAAD(accountId: string, operationId: string): Buffer {
  return Buffer.from(`toj/draft-response|${accountId}|${operationId}`, "utf8");
}

/** Account-private folder titles remain encrypted even though matching flags are queryable. */
export function chatFolderTitleAAD(accountId: string, folderId: string): Buffer {
  return Buffer.from(`toj/chat-folder-title|${accountId}|${folderId}`, "utf8");
}

/** One sealed scheduled item contains body, reply, mentions, and preview intent. */
export function scheduledItemAAD(
  accountId: string,
  deliveryId: string,
  itemIndex: number,
  clientMsgId: string,
): Buffer {
  return Buffer.from(
    `toj/scheduled-item|${accountId}|${deliveryId}|${itemIndex}|${clientMsgId}`,
    "utf8",
  );
}

/** Link-preview URL and metadata namespaces cannot be swapped between cache/message rows. */
export function linkPreviewURLAAD(scope: "cache" | "message" | "snapshot", id: string): Buffer {
  return Buffer.from(`toj/link-preview-url|${scope}|${id}`, "utf8");
}

export function linkPreviewMetadataAAD(snapshotId: string): Buffer {
  return Buffer.from(`toj/link-preview-metadata|${snapshotId}`, "utf8");
}

export function linkPreviewAssetAAD(assetId: string): Buffer {
  return Buffer.from(`toj/link-preview-asset|${assetId}`, "utf8");
}
export const PHONE_AAD = Buffer.from("toj/phone", "utf8");

/** Binds an APNs device token to the exact authenticated device row. */
export function pushTokenAAD(deviceId: string): Buffer {
  return Buffer.from(`toj/apns-token|${deviceId}`, "utf8");
}

/** Separately binds a PushKit VoIP token so the two APNs token fields cannot be swapped. */
export function voipPushTokenAAD(deviceId: string): Buffer {
  return Buffer.from(`toj/apns-voip-token|${deviceId}`, "utf8");
}

/** Installation-scoped APNs tokens are shared by up to three independently authenticated devices. */
export function installationPushTokenAAD(
  installationId: string,
  kind: "normal" | "voip",
): Buffer {
  return Buffer.from(`toj/apns-installation-${kind}|${installationId}`, "utf8");
}

/** Binds a crash-safe refresh receipt to one device session and rotation request. */
export function sessionRotationAAD(sessionId: string, rotationId: string): Buffer {
  return Buffer.from(`toj/session-rotation|${sessionId}|${rotationId}`, "utf8");
}

/** Binds an encrypted media chunk to its upload and exact plaintext offset. */
export function mediaChunkAAD(mediaId: string, offset: number | bigint): Buffer {
  return Buffer.from(`toj/media|${mediaId}|${offset}`, "utf8");
}

/** Thumbnail bytes use a separate AAD namespace from the original media. */
export function mediaThumbnailAAD(mediaId: string): Buffer {
  return Buffer.from(`toj/media-thumbnail|${mediaId}`, "utf8");
}

/** File names are presentation data, but can contain highly sensitive user information. */
export function mediaFileNameAAD(mediaId: string): Buffer {
  return Buffer.from(`toj/media-filename|${mediaId}`, "utf8");
}

/** Binds a moderation evidence bundle to the report and submitting account. */
export function reportEvidenceAAD(reportId: string, reporterAccountId: string): Buffer {
  return Buffer.from(`toj/report-evidence|${reportId}|${reporterAccountId}`, "utf8");
}

/** Binds an encrypted operator note to one report, action, and operator identity. */
export function reportActionNoteAAD(reportId: string, action: string, operatorId: string): Buffer {
  return Buffer.from(`toj/report-action-note|${reportId}|${action}|${operatorId}`, "utf8");
}

/**
 * Hides raw whole-file and chunk SHA-256 fingerprints from a database-only compromise while
 * preserving constant-time integrity and resumable-upload comparisons.
 */
export function mediaDigestHMAC(digest: Uint8Array): Buffer {
  return mediaDigestIndex(digest).digest;
}
export function mediaDigestIndex(digest: Uint8Array, keyId?: string): VersionedBlindIndex {
  const legacy = Buffer.concat([Buffer.from("toj/media-digest/v1|"), Buffer.from(digest)]);
  return keyId
    ? blindIndexForKey(keyId, "media-digest", digest, legacy)
    : activeBlindIndex("media-digest", digest, legacy);
}

/** Opaque, domain-separated idempotency fingerprint. Database readers cannot test plaintext. */
export function requestFingerprintHMAC(
  domain:
    | "draft-mutation"
    | "message-send"
    | "message-send-v2"
    | "media-group-send"
    | "chat-folder-mutation"
    | "scheduled-delivery-mutation"
    | "abuse-report"
    | "messaging-feature",
  canonicalPayload: Uint8Array | string,
): Buffer {
  return requestFingerprintIndex(domain, canonicalPayload).digest;
}
export function requestFingerprintIndex(
  domain:
    | "draft-mutation"
    | "message-send"
    | "message-send-v2"
    | "media-group-send"
    | "chat-folder-mutation"
    | "scheduled-delivery-mutation"
    | "abuse-report"
    | "messaging-feature",
  canonicalPayload: Uint8Array | string,
  keyId?: string,
): VersionedBlindIndex {
  const payload = typeof canonicalPayload === "string"
    ? Buffer.from(canonicalPayload, "utf8") : Buffer.from(canonicalPayload);
  const legacy = Buffer.concat([
    Buffer.from(`toj/request-fingerprint/${domain}/v1|`),
    payload,
  ]);
  return keyId
    ? blindIndexForKey(keyId, domain, payload, legacy)
    : activeBlindIndex(domain, payload, legacy);
}

/** A keyed lookup lets the queue coalesce URLs without indexing their plaintext. */
export function linkPreviewLookupHMAC(normalizedURL: string): Buffer {
  return linkPreviewLookupIndex(normalizedURL).digest;
}
export function linkPreviewLookupIndex(normalizedURL: string, keyId?: string): VersionedBlindIndex {
  const legacy = Buffer.from(`toj/link-preview-url/v1|${normalizedURL}`, "utf8");
  return keyId
    ? blindIndexForKey(keyId, "link-preview-url", normalizedURL, legacy)
    : activeBlindIndex("link-preview-url", normalizedURL, legacy);
}
export function linkPreviewLookupCandidates(normalizedURL: string): VersionedBlindIndex[] {
  const legacy = Buffer.from(`toj/link-preview-url/v1|${normalizedURL}`, "utf8");
  return blindIndexCandidates("link-preview-url", normalizedURL, legacy);
}

export function linkPreviewAssetDigestHMAC(bytes: Uint8Array): Buffer {
  return linkPreviewAssetDigestIndex(bytes).digest;
}
export function linkPreviewAssetDigestIndex(bytes: Uint8Array, keyId?: string): VersionedBlindIndex {
  const input = Buffer.from(bytes);
  const legacy = Buffer.concat([Buffer.from("toj/link-preview-asset/v1|"), input]);
  return keyId
    ? blindIndexForKey(keyId, "link-preview-asset", input, legacy)
    : activeBlindIndex("link-preview-asset", input, legacy);
}

export function normalizePhone(p: string): string {
  return p.replace(/[^\d+]/g, "");
}
export function phoneLookupHash(e164: string): Buffer {
  return phoneLookupIndex(e164).digest;
}
export function phoneLookupIndex(e164: string, keyId?: string): VersionedBlindIndex {
  const normalized = normalizePhone(e164);
  return keyId
    ? blindIndexForKey(keyId, "phone-lookup", normalized)
    : activeBlindIndex("phone-lookup", normalized);
}
export function phoneLookupCandidates(e164: string): VersionedBlindIndex[] {
  return blindIndexCandidates("phone-lookup", normalizePhone(e164));
}
export function codeHash(code: string, salt?: Uint8Array): Buffer {
  return codeHashIndex(code, salt).digest;
}
export function codeHashIndex(code: string, salt?: Uint8Array, keyId?: string): VersionedBlindIndex {
  const input = Buffer.concat([salt ? Buffer.from(salt) : Buffer.alloc(0), Buffer.from(code)]);
  return keyId
    ? blindIndexForKey(keyId, "otp-code", input)
    : activeBlindIndex("otp-code", input);
}
export function hashToken(token: string): Buffer {
  return tokenHashIndex(token).digest;
}
export function tokenHashIndex(token: string, keyId?: string): VersionedBlindIndex {
  return keyId
    ? blindIndexForKey(keyId, "opaque-token", token)
    : activeBlindIndex("opaque-token", token);
}
export function tokenHashCandidates(token: string): VersionedBlindIndex[] {
  return blindIndexCandidates("opaque-token", token);
}
export function constantTimeEqual(a: Buffer, b: Buffer): boolean {
  return a.length === b.length && timingSafeEqual(a, b);
}
