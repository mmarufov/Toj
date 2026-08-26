import type { SQL } from "bun";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { Client } from "pg";
import { tokenHashCandidates, tokenHashIndex } from "./crypto";
import {
  deleteAccount as deleteAuthAccount,
  requireActiveDevice,
  revokeDevice as revokeAuthDevice,
} from "./auth";
import { sendMessage, type Push } from "./sync";
import { lockAccountMutations, lockMutationKeys } from "./locks";
import {
  CallVersionCapabilityError,
  normalizeCallVersionCapabilities as normalizeVersionCapabilities,
} from "./call-versions";
import { handoffOwnedGroupsForDeletedAccount } from "./groups";
import { purgeAccountDraftState } from "./drafts";
import {
  requireGroupCallSFUBarrierApplied,
  revokeGroupCallAccountTx,
  revokeGroupCallDeviceTx,
  type GroupCallSFUControl,
} from "./group-calls";
import {
  publishPresenceSessionRevocation,
  revokeAccountPresence,
  revokeDevicePresence,
  type PresenceBroadcast,
} from "./presence";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CURRENT_PROTOCOL = 1;
const SUPPORTED_PROTOCOLS = [1] as const;
const SUPPORTED_MEDIA_PROFILES = [1, 2] as const;
const MAX_SIGNAL_BYTES = 64 * 1024 + 28; // 64 KiB plaintext plus ChaChaPoly nonce/tag overhead.
const MAX_CANDIDATE_SIGNAL_BYTES = 8 * 1024;
const MAX_CONTROL_SIGNAL_BYTES = 2 * 1024;
const SIGNAL_BUDGET_WINDOW_SECONDS = 60;
const MAX_SIGNAL_EVENTS_PER_WINDOW = 120;
const MAX_SIGNAL_BYTES_PER_WINDOW = 512 * 1024;
const MAX_NEGOTIATION_EVENTS_PER_WINDOW = 12;
const RING_SECONDS = 30;
const KEY_EXCHANGE_SECONDS = 10;
// Active calls renew this short lease with encrypted control heartbeats. A crashed/deleted client can
// therefore strand a call for at most two minutes instead of the former 24-hour hard timeout.
const ACTIVE_SECONDS = 120;
const HISTORY_CLAIM_TIMEOUT_SECONDS = 30;

// Call telemetry is deliberately low-cardinality and PII-free. Only values drawn from these
// pinned enumerations are ever accepted or logged; anything else is rejected. This keeps
// operational metrics useful while guaranteeing no keys, SDP, candidates, phone numbers, or
// raw measurements can be smuggled through the reporting endpoint.
const TELEMETRY_ROUTE_CLASSES = new Set(["direct", "reflexive", "relay_udp", "relay_tcp", "relay_tls", "unknown"]);
const TELEMETRY_OUTCOMES = new Set([
  "completed", "declined", "cancelled", "unanswered", "busy", "answered_elsewhere",
  "network_lost", "security_error", "permission_denied", "failed", "remote_ended",
]);
const TELEMETRY_TIME_BUCKETS = new Set(["le_1s", "le_2s", "le_3s", "le_5s", "gt_5s", "none"]);
const TELEMETRY_RTT_BUCKETS = new Set(["le_100", "le_200", "le_400", "le_800", "gt_800", "none"]);
const TELEMETRY_LOSS_BUCKETS = new Set(["le_1", "le_5", "le_10", "le_20", "gt_20", "none"]);
const TELEMETRY_JITTER_BUCKETS = new Set(["le_10", "le_30", "le_60", "gt_60", "none"]);
const TELEMETRY_BITRATE_BUCKETS = new Set(["le_16", "le_24", "le_32", "le_48", "gt_48", "none"]);
const TELEMETRY_PRIVACY_MODES = new Set(["fastest_route", "relay_only"]);

function pickEnum(value: unknown, allowed: Set<string>, field: string, optional = false): string | null {
  if (value == null) {
    if (optional) return null;
    throw new CallError(`${field} is required`, "invalid_request");
  }
  if (typeof value !== "string" || !allowed.has(value)) {
    throw new CallError(`${field} is invalid`, "invalid_request");
  }
  return value;
}

function clampCount(value: unknown, max: number): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.max(0, Math.min(max, Math.trunc(parsed)));
}

export type CallState = "requested" | "accepted" | "key_exchange" | "active" | "ended";
export type CallInitialKind = "voice" | "video";
export type CallViewKind = "full" | "invitation" | "lifecycle";

export class CallError extends Error {
  constructor(
    message: string,
    public readonly code: string,
    public readonly status = 400,
    public readonly details: Record<string, unknown> = {},
    public readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "CallError";
  }
}

export type CallSnapshot = {
  view: CallViewKind;
  id: string;
  dialogId: string;
  callerAccountId: string;
  callerDeviceId: string;
  calleeAccountId: string;
  state: CallState;
  offeredProtocolVersions: number[];
  offeredMediaProfileVersions: number[];
  selectableMediaProfileVersions: number[];
  initialKind: CallInitialKind;
  protocolVersion: number | null;
  mediaProfileVersion: number | null;
  callerCommitment: string | null;
  calleeCommitment: string | null;
  callerFingerprint: string | null;
  acceptedDeviceId: string | null;
  calleePublicKey: string | null;
  calleeNonce: string | null;
  calleeFingerprint: string | null;
  callerPublicKey: string | null;
  callerNonce: string | null;
  createdAt: string;
  expiresAt: string;
  acceptedAt: string | null;
  confirmedAt: string | null;
  endedAt: string | null;
  endReason: string | null;
  localRingStatus: string | null;
  latestEventSeq: number;
};

export type CallEventDTO = {
  eventSeq: number;
  type: "requested" | "accepted" | "revealed" | "confirmed" | "encrypted" | "ended";
  senderAccountId: string | null;
  senderDeviceId: string | null;
  senderSequence: number | null;
  version: number | null;
  kind: "offer" | "answer" | "ice_candidate" | "ice_restart" | "hangup" | "control" | null;
  expiresAtMilliseconds: number | null;
  ciphertext: string | null;
  data: Record<string, unknown> | null;
  createdAt: string;
  expiresAt: string;
};

export type CallHint = {
  accountId: string;
  deviceId: string;
  callId: string;
  latestEventSeq: number;
};

export type CallWakeup = { callId: string; latestEventSeq: number };

export type CallRow = Record<string, any>;
type MutationResult = { call: CallSnapshot; hints: CallHint[]; syncPushes?: Push[] };

const iso = (value: unknown): string => value instanceof Date ? value.toISOString() : String(value);
const nullableIso = (value: unknown): string | null => value == null ? null : iso(value);
const base64 = (value: unknown): string | null => value == null ? null : Buffer.from(value as Uint8Array).toString("base64");
// Bun's PostgreSQL driver returns INT4[] columns as Int32Array. Calling `.map(Number)`
// preserves that typed-array shape, which JSON encodes as an object instead of an array.
// Normalize at the database boundary so public DTOs and version comparisons always use
// ordinary JavaScript arrays.
const numericArray = (value: unknown, fallback: number[] = []): number[] =>
  Array.from((value ?? fallback) as ArrayLike<unknown>, Number);

function decodeBase64(value: unknown, field: string, exactBytes?: number): Buffer {
  if (typeof value !== "string" || value.length === 0 || value.length > 100_000
    || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    throw new CallError(`${field} must be base64`, "invalid_request");
  }
  const decoded = Buffer.from(value, "base64");
  if (exactBytes !== undefined && decoded.length !== exactBytes) {
    throw new CallError(`${field} must decode to ${exactBytes} bytes`, "invalid_request");
  }
  return decoded;
}

function requireUUID(value: unknown, field: string): string {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new CallError(`${field} must be a UUID`, "invalid_request");
  }
  return value.toLowerCase();
}

export function normalizeCallVersionCapabilities(value: unknown, fallback: number[] = [1]): number[] {
  try {
    return normalizeVersionCapabilities(value, fallback);
  } catch (error) {
    if (error instanceof CallVersionCapabilityError) {
      throw new CallError(error.message, "invalid_request");
    }
    throw error;
  }
}

function requireProtocolOffer(value: unknown): number[] {
  if (value == null) throw new CallError("protocol offer is required", "invalid_request");
  const protocols = normalizeCallVersionCapabilities(value);
  if (!protocols.some((entry) => SUPPORTED_PROTOCOLS.includes(entry as 1))) {
    throw new CallError("no supported protocol", "unsupported_protocol", 409);
  }
  return protocols;
}

function requireMediaOffer(value: unknown): number[] {
  if (value == null) throw new CallError("media profile offer is required", "invalid_request");
  const profiles = normalizeCallVersionCapabilities(value);
  if (profiles.some((entry) => !SUPPORTED_MEDIA_PROFILES.includes(entry as 1 | 2))
    || !(["1", "1,2", "2"] as string[]).includes(profiles.join(","))) {
    throw new CallError("unsupported media profile offer", "unsupported_media_profile", 409);
  }
  return profiles;
}

export type CallCommitmentContextV1 = {
  callId: string;
  dialogId: string;
  callerAccountId: string;
  callerDeviceId: string;
  calleeAccountId: string;
  offeredProtocolVersions: number[];
  offeredMediaProfileVersions: number[];
};

export type CallKeyMaterialV1 = { publicKey: Buffer; nonce: Buffer; fingerprint: Buffer };

class CanonicalCallEncoder {
  private readonly chunks: Buffer[] = [];

  bytes(value: Buffer): this {
    const length = Buffer.allocUnsafe(4);
    length.writeUInt32BE(value.length);
    this.chunks.push(length, value);
    return this;
  }

  string(value: string): this { return this.bytes(Buffer.from(value, "utf8")); }

  uint16(value: number): this {
    const encoded = Buffer.allocUnsafe(2);
    encoded.writeUInt16BE(value);
    this.chunks.push(encoded);
    return this;
  }

  result(): Buffer { return Buffer.concat(this.chunks); }
}

function appendParty(encoder: CanonicalCallEncoder, accountId: string, deviceId: string): void {
  encoder.string(accountId).string(deviceId);
}

function appendCommitmentContext(encoder: CanonicalCallEncoder, context: CallCommitmentContextV1): void {
  encoder.string(context.callId).string(context.dialogId);
  appendParty(encoder, context.callerAccountId, context.callerDeviceId);
  encoder.string(context.calleeAccountId).uint16(context.offeredProtocolVersions.length);
  for (const version of context.offeredProtocolVersions) encoder.uint16(version);
  encoder.uint16(context.offeredMediaProfileVersions.length);
  for (const version of context.offeredMediaProfileVersions) encoder.uint16(version);
}

function appendKeyMaterial(encoder: CanonicalCallEncoder, material: CallKeyMaterialV1): void {
  encoder.bytes(material.publicKey).bytes(material.nonce).bytes(material.fingerprint);
}

export function callerCommitmentV1(context: CallCommitmentContextV1, material: CallKeyMaterialV1): Buffer {
  const encoder = new CanonicalCallEncoder().string("toj-call-v1/caller-commitment");
  appendCommitmentContext(encoder, context);
  appendKeyMaterial(encoder, material);
  return createHash("sha256").update(encoder.result()).digest();
}

export function calleeCommitmentV1(context: CallCommitmentContextV1, callerCommitment: Buffer,
  calleeDeviceId: string, selectedProtocolVersion: number, selectedMediaProfileVersion: number,
  material: CallKeyMaterialV1): Buffer {
  const encoder = new CanonicalCallEncoder().string("toj-call-v1/callee-commitment");
  appendCommitmentContext(encoder, context);
  encoder.bytes(callerCommitment);
  appendParty(encoder, context.calleeAccountId, calleeDeviceId);
  encoder.uint16(selectedProtocolVersion).uint16(selectedMediaProfileVersion);
  appendKeyMaterial(encoder, material);
  return createHash("sha256").update(encoder.result()).digest();
}

function commitmentContext(row: CallRow): CallCommitmentContextV1 {
  return {
    callId: row.id,
    dialogId: row.dialog_id,
    callerAccountId: row.caller_account_id,
    callerDeviceId: row.caller_device_id,
    calleeAccountId: row.callee_account_id,
    offeredProtocolVersions: numericArray(row.supported_protocols),
    offeredMediaProfileVersions: numericArray(row.offered_media_profiles),
  };
}

function snapshot(
  row: CallRow,
  view: CallViewKind = "full",
  localRingStatus: string | null = null,
  selectableMediaOverride: number[] | null = null,
  localRespondedAt: unknown | null = null,
): CallSnapshot {
  const exposesInvitation = view === "full" || view === "invitation";
  const exposesSetup = view === "full";
  const lifecycle = view === "lifecycle";
  const lifecycleEndReason = localRingStatus === "expired"
    ? "unanswered"
    : localRingStatus === "ended"
      ? row.end_reason ?? "local_ended"
      : localRingStatus;
  const invitationExpiresAt = new Date(new Date(row.created_at).getTime() + RING_SECONDS * 1_000);
  return {
    view,
    id: row.id,
    dialogId: row.dialog_id,
    callerAccountId: row.caller_account_id,
    callerDeviceId: row.caller_device_id,
    calleeAccountId: row.callee_account_id,
    // A losing target's local call is over. Do not expose whether the winning devices are in
    // acceptance, key exchange, or active media setup.
    state: lifecycle ? "ended" : row.state,
    offeredProtocolVersions: exposesInvitation ? numericArray(row.supported_protocols) : [],
    offeredMediaProfileVersions: exposesInvitation ? numericArray(row.offered_media_profiles) : [],
    selectableMediaProfileVersions: exposesInvitation
      ? numericArray(selectableMediaOverride ?? row.selectable_media_profiles, [1]) : [],
    initialKind: row.initial_kind === "video" ? "video" : "voice",
    protocolVersion: exposesSetup && row.protocol_version != null ? Number(row.protocol_version) : null,
    mediaProfileVersion: exposesSetup && row.media_profile_version != null ? Number(row.media_profile_version) : null,
    callerCommitment: exposesInvitation ? base64(row.caller_commitment) : null,
    calleeCommitment: exposesSetup ? base64(row.callee_commitment) : null,
    callerFingerprint: exposesSetup ? base64(row.caller_fingerprint) : null,
    acceptedDeviceId: exposesSetup ? row.accepted_device_id ?? null : null,
    calleePublicKey: exposesSetup ? base64(row.callee_public_key) : null,
    calleeNonce: exposesSetup ? base64(row.callee_nonce) : null,
    calleeFingerprint: exposesSetup ? base64(row.callee_fingerprint) : null,
    callerPublicKey: exposesSetup ? base64(row.caller_public_key) : null,
    callerNonce: exposesSetup ? base64(row.caller_nonce) : null,
    createdAt: iso(row.created_at),
    // Lifecycle views retain the immutable invitation deadline instead of the active call lease,
    // which changes during key exchange, heartbeats, and ICE recovery.
    expiresAt: lifecycle ? invitationExpiresAt.toISOString() : iso(row.expires_at),
    acceptedAt: exposesSetup ? nullableIso(row.accepted_at) : null,
    confirmedAt: exposesSetup ? nullableIso(row.confirmed_at) : null,
    endedAt: lifecycle ? nullableIso(localRespondedAt) : nullableIso(row.ended_at),
    endReason: lifecycle ? lifecycleEndReason : row.end_reason ?? null,
    localRingStatus,
    // Lifecycle clients reconcile exclusively from this projection. A zero cursor prevents the
    // encrypted signaling count from becoming a side channel after first-answer-wins.
    latestEventSeq: lifecycle ? 0 : Number(row.latest_event_seq),
  };
}

function eventDTO(row: Record<string, any>): CallEventDTO {
  return {
    eventSeq: Number(row.event_seq),
    type: row.event_type,
    senderAccountId: row.sender_account_id ?? null,
    senderDeviceId: row.sender_device_id ?? null,
    senderSequence: row.sender_sequence == null ? null : Number(row.sender_sequence),
    version: row.signal_version == null ? null : Number(row.signal_version),
    kind: row.signal_kind ?? null,
    expiresAtMilliseconds: row.envelope_expires_at == null ? null : new Date(row.envelope_expires_at).getTime(),
    ciphertext: base64(row.ciphertext),
    data: row.data == null ? null : typeof row.data === "string" ? JSON.parse(row.data) : row.data,
    createdAt: iso(row.created_at),
    expiresAt: iso(row.expires_at),
  };
}

async function hints(sql: SQL, row: CallRow, includeLosingTargets = false): Promise<CallHint[]> {
  const targets = await sql`
    SELECT d.account_id, d.id AS device_id,
      CASE
        WHEN d.id = ${row.caller_device_id} OR d.id = ${row.accepted_device_id}
          OR (${row.accepted_device_id == null && row.state === "requested"} AND rt.status = 'ringing')
          THEN ${Number(row.latest_event_seq)}
        ELSE 0
      END AS projected_event_seq
    FROM devices d
    LEFT JOIN call_ring_targets rt ON rt.call_id = ${row.id} AND rt.device_id = d.id
    WHERE d.revoked_at IS NULL AND (
      (d.account_id = ${row.caller_account_id} AND d.id = ${row.caller_device_id})
      OR (d.account_id = ${row.callee_account_id} AND d.id = ${row.accepted_device_id})
      OR EXISTS (
        SELECT 1 FROM call_ring_targets eligible_rt
        WHERE eligible_rt.call_id = ${row.id} AND eligible_rt.device_id = d.id AND (
          (${row.accepted_device_id == null && row.state === "requested"} AND eligible_rt.status = 'ringing')
          OR (${row.accepted_device_id == null && row.state === "ended"}
            AND eligible_rt.status IN ('ended', 'expired'))
          OR (${includeLosingTargets} AND eligible_rt.status = 'answered_elsewhere')
        )
      )
    )`;
  return targets.map((target: { account_id: string; device_id: string; projected_event_seq: number }) => ({
    accountId: target.account_id,
    deviceId: target.device_id,
    callId: row.id,
    latestEventSeq: Number(target.projected_event_seq),
  }));
}

async function hintsForRows(sql: SQL, rows: CallRow[]): Promise<CallHint[]> {
  const result: CallHint[] = [];
  for (const row of rows) result.push(...await hints(sql, row));
  return result;
}

async function callAccess(sql: SQL, row: CallRow, accountId: string, deviceId: string): Promise<{
  view: CallViewKind;
  localRingStatus: string | null;
  selectableMediaProfiles: number[] | null;
  localRespondedAt: unknown | null;
}> {
  if (row.caller_account_id === accountId && row.caller_device_id === deviceId) {
    return { view: "full", localRingStatus: null, selectableMediaProfiles: null, localRespondedAt: null };
  }
  if (row.callee_account_id !== accountId) {
    throw new CallError("call not found", "not_found", 404);
  }
  const target = (await sql`
    SELECT status, selectable_media_profiles, responded_at
    FROM call_ring_targets WHERE call_id = ${row.id} AND device_id = ${deviceId}`)[0];
  if (!target) throw new CallError("call not found", "not_found", 404);
  const selectableMediaProfiles = numericArray(target.selectable_media_profiles, [1]);
  if (row.accepted_device_id === deviceId) {
    return {
      view: "full", localRingStatus: target.status, selectableMediaProfiles,
      localRespondedAt: target.responded_at,
    };
  }
  if (row.state === "requested" && target.status === "ringing") {
    return {
      view: "invitation", localRingStatus: target.status, selectableMediaProfiles,
      localRespondedAt: target.responded_at,
    };
  }
  return {
    view: "lifecycle", localRingStatus: target.status, selectableMediaProfiles: [],
    localRespondedAt: target.responded_at,
  };
}

async function scopedSnapshot(
  sql: SQL,
  row: CallRow,
  accountId: string,
  deviceId: string,
): Promise<CallSnapshot> {
  const access = await callAccess(sql, row, accountId, deviceId);
  return snapshot(
    row,
    access.view,
    access.localRingStatus,
    access.selectableMediaProfiles,
    access.localRespondedAt,
  );
}

export async function resolveCallHintTargets(
  sql: SQL,
  wakeup: CallWakeup,
  localDeviceIds: string[],
): Promise<CallHint[]> {
  if (!UUID_PATTERN.test(wakeup.callId) || !Number.isSafeInteger(wakeup.latestEventSeq)
    || wakeup.latestEventSeq < 0 || localDeviceIds.length === 0) return [];
  const rows = await sql`
    SELECT d.account_id, d.id AS device_id,
      CASE
        WHEN d.id = c.caller_device_id OR d.id = c.accepted_device_id
          OR (c.accepted_device_id IS NULL AND c.state = 'requested' AND rt.status = 'ringing')
          THEN ${wakeup.latestEventSeq}
        ELSE 0
      END AS projected_event_seq
    FROM calls c
    JOIN call_events wake ON wake.call_id = c.id AND wake.event_seq = ${wakeup.latestEventSeq}
    JOIN devices d ON d.id = ANY(${sql.array(localDeviceIds, "UUID")}) AND d.revoked_at IS NULL
    LEFT JOIN call_ring_targets rt ON rt.call_id = c.id AND rt.device_id = d.id
    WHERE c.id = ${wakeup.callId} AND (
      (d.id = c.caller_device_id)
      OR (d.id = c.accepted_device_id)
      OR (c.accepted_device_id IS NULL AND c.state = 'requested' AND rt.status = 'ringing')
      OR (c.accepted_device_id IS NULL AND wake.event_type = 'ended'
        AND rt.status IN ('ended', 'expired'))
      OR (rt.status = 'answered_elsewhere' AND wake.event_type = 'accepted')
    )`;
  return rows.map((row: { account_id: string; device_id: string; projected_event_seq: number }) => ({
    accountId: row.account_id,
    deviceId: row.device_id,
    callId: wakeup.callId,
    latestEventSeq: Number(row.projected_event_seq),
  }));
}

async function lockedCall(sql: SQL, callId: string): Promise<CallRow> {
  const row = (await sql`
    SELECT *, expires_at <= now() AS deadline_elapsed
    FROM calls WHERE id = ${callId} FOR UPDATE`)[0];
  if (!row) throw new CallError("call not found", "not_found", 404);
  return row;
}

function requireUnexpired(row: CallRow): void {
  const elapsed = row.deadline_elapsed == null
    ? new Date(row.expires_at).getTime() <= Date.now()
    : row.deadline_elapsed === true;
  if (row.state !== "ended" && elapsed) {
    throw new CallError("call has expired", "expired", 410);
  }
}

function requireOwningDevice(row: CallRow, accountId: string, deviceId: string): void {
  const ownsCaller = row.caller_account_id === accountId && row.caller_device_id === deviceId;
  const ownsCallee = row.callee_account_id === accountId && row.accepted_device_id === deviceId;
  if (!ownsCaller && !ownsCallee) {
    throw new CallError("only the active call device may perform this action", "invalid_device", 403);
  }
}

async function appendControlEvent(
  sql: SQL,
  row: CallRow,
  eventType: Exclude<CallEventDTO["type"], "encrypted">,
  senderAccountId: string | null,
  senderDeviceId: string | null,
  data: Record<string, unknown>,
): Promise<CallRow> {
  const updated = (await sql`
    UPDATE calls SET latest_event_seq = latest_event_seq + 1
    WHERE id = ${row.id} RETURNING *`)[0];
  const eventSeq = Number(updated.latest_event_seq);
  await sql`
    INSERT INTO call_events
      (call_id, event_seq, event_type, sender_account_id, sender_device_id, data)
    VALUES (${row.id}, ${eventSeq}, ${eventType}, ${senderAccountId}, ${senderDeviceId},
      ${JSON.stringify(data)}::jsonb)`;
  await notify(sql, updated);
  return updated;
}

async function notify(sql: SQL, row: CallRow): Promise<void> {
  const payload = JSON.stringify({
    callId: row.id,
    latestEventSeq: Number(row.latest_event_seq),
  });
  await sql`SELECT pg_notify('toj_call_events', ${payload})`;
}

async function finishCallTx(sql: SQL, row: CallRow, reason: string, actorAccountId: string | null,
  actorDeviceId: string | null): Promise<CallRow> {
  if (row.state === "ended") return row;
  const ended = (await sql`
    UPDATE calls SET state = 'ended', ended_at = now(), end_reason = ${reason}, expires_at = now()
    WHERE id = ${row.id} RETURNING *`)[0];
  await sql`DELETE FROM call_participant_leases WHERE call_id = ${row.id}`;
  await sql`
    UPDATE call_ring_targets SET
      status = CASE WHEN status = 'ringing' THEN ${reason === "unanswered" ? "expired" : "ended"} ELSE status END,
      responded_at = COALESCE(responded_at, now())
    WHERE call_id = ${row.id}`;
  await sql`
    UPDATE voip_push_deliveries SET status = 'dead', claimed_at = NULL,
      last_error = COALESCE(last_error, 'call ended')
    WHERE call_id = ${row.id} AND status IN ('pending','sending')`;
  const finalized = await appendControlEvent(sql, ended, "ended", actorAccountId, actorDeviceId, { reason });
  await sql`
    UPDATE call_events SET expires_at = LEAST(expires_at, now() + interval '9 minutes 30 seconds')
    WHERE call_id = ${row.id}`;
  await sql`
    INSERT INTO call_history_outbox
      (call_id, dialog_id, caller_account_id, initial_kind, outcome, duration_seconds)
    VALUES (${finalized.id}, ${finalized.dialog_id}, ${finalized.caller_account_id}, ${finalized.initial_kind},
      ${historyOutcome(finalized)}, ${historyDurationSeconds(finalized)})
    ON CONFLICT (call_id) DO NOTHING`;
  return finalized;
}

function historyOutcome(row: CallRow): string {
  if (row.end_reason === "declined") return "declined";
  if (["unanswered", "expired"].includes(row.end_reason)) return "missed";
  if (row.end_reason === "busy") return "busy";
  if (["cancelled", "caller_cancelled"].includes(row.end_reason)) return "cancelled";
  if (row.confirmed_at) return "completed";
  return "failed";
}

function historyDurationSeconds(row: CallRow): number {
  const confirmed = row.confirmed_at == null ? null : new Date(row.confirmed_at).getTime();
  const ended = row.ended_at == null ? Date.now() : new Date(row.ended_at).getTime();
  return confirmed == null ? 0 : Math.max(0, Math.floor((ended - confirmed) / 1_000));
}

type ClaimedCallHistory = {
  call_id: string;
  history_client_msg_id: string;
  dialog_id: string;
  caller_account_id: string;
  initial_kind: CallInitialKind;
  outcome: string;
  duration_seconds: number;
  attempts: number;
};

async function claimCallHistory(sql: SQL, limit: number, onlyCallId?: string): Promise<ClaimedCallHistory[]> {
  if (onlyCallId) {
    await sql`
      UPDATE call_history_outbox SET status = 'pending', claimed_at = NULL
      WHERE call_id = ${onlyCallId} AND status = 'sending'
        AND claimed_at < now() - (${HISTORY_CLAIM_TIMEOUT_SECONDS} * interval '1 second')`;
    return await sql`
      WITH picked AS (
        SELECT call_id FROM call_history_outbox
        WHERE call_id = ${onlyCallId} AND status = 'pending' AND available_at <= now()
        FOR UPDATE SKIP LOCKED
      )
      UPDATE call_history_outbox o SET status = 'sending', claimed_at = now()
      FROM picked p WHERE o.call_id = p.call_id
      RETURNING o.call_id, o.history_client_msg_id, o.dialog_id, o.caller_account_id, o.initial_kind, o.outcome,
        o.duration_seconds, o.attempts` as ClaimedCallHistory[];
  }

  await sql`
    UPDATE call_history_outbox SET status = 'pending', claimed_at = NULL
    WHERE status = 'sending'
      AND claimed_at < now() - (${HISTORY_CLAIM_TIMEOUT_SECONDS} * interval '1 second')`;
  return await sql`
    WITH picked AS (
      SELECT call_id FROM call_history_outbox
      WHERE status = 'pending' AND available_at <= now()
      ORDER BY available_at, created_at
      FOR UPDATE SKIP LOCKED LIMIT ${limit}
    )
    UPDATE call_history_outbox o SET status = 'sending', claimed_at = now()
    FROM picked p WHERE o.call_id = p.call_id
    RETURNING o.call_id, o.history_client_msg_id, o.dialog_id, o.caller_account_id, o.initial_kind, o.outcome,
      o.duration_seconds, o.attempts` as ClaimedCallHistory[];
}

/** Durable, idempotent call-history delivery. Safe to run concurrently in requests and workers. */
export async function processCallHistoryOutbox(sql: SQL, limit = 50, onlyCallId?: string): Promise<{
  processed: number; pushes: Push[];
}> {
  const claimed = await claimCallHistory(sql, Math.max(1, Math.min(500, limit)), onlyCallId);
  const pushes: Push[] = [];
  let processed = 0;
  for (const row of claimed) {
    try {
      const result = await sendMessage(sql, {
        senderAccountId: row.caller_account_id,
        senderDeviceId: null,
        dialogId: row.dialog_id,
        clientMsgId: row.history_client_msg_id,
        kind: "service",
        internalService: true,
        body: JSON.stringify({
          v: 1,
          type: row.initial_kind === "video" ? "video_call" : "voice_call",
          callId: row.call_id,
          callerAccountId: row.caller_account_id,
          outcome: row.outcome,
          durationSeconds: Number(row.duration_seconds),
        }),
      });
      const delivered = await sql`
        UPDATE call_history_outbox SET status = 'delivered', delivered_at = now(),
          claimed_at = NULL, last_error = NULL
        WHERE call_id = ${row.call_id} AND status = 'sending'
        RETURNING call_id`;
      if (delivered.length) {
        processed += 1;
        pushes.push(...result.pushes);
      }
    } catch (error) {
      const attempts = Number(row.attempts) + 1;
      const delaySeconds = Math.min(5 * 60, 2 ** Math.min(attempts, 8));
      const message = (error instanceof Error ? error.message : String(error))
        .replace(/[\r\n]+/g, " ").slice(0, 500);
      await sql`
        UPDATE call_history_outbox SET status = 'pending', attempts = ${attempts},
          available_at = now() + (${delaySeconds} * interval '1 second'),
          claimed_at = NULL, last_error = ${message}
        WHERE call_id = ${row.call_id} AND status = 'sending'`;
    }
  }
  return { processed, pushes };
}

async function flushCallHistory(sql: SQL, rows: CallRow[]): Promise<Push[]> {
  const pushes: Push[] = [];
  for (const row of rows) {
    const result = await processCallHistoryOutbox(sql, 1, row.id);
    pushes.push(...result.pushes);
  }
  return pushes;
}

/** Used by cross-domain account lifecycle transactions such as moderation bans. */
export async function terminateCallsForAccountTx(
  sql: SQL,
  accountId: string,
  reason = "account_deleted",
): Promise<CallRow[]> {
  return await terminateMatchingCallsTx(sql, "account", accountId, undefined, reason);
}

export async function flushTerminatedCallHistory(sql: SQL, rows: CallRow[]): Promise<Push[]> {
  return await flushCallHistory(sql, rows);
}

export async function createCall(sql: SQL, p: {
  callerAccountId: string;
  callerDeviceId: string;
  callId: unknown;
  dialogId: unknown;
  callerCommitment: unknown;
  supportedProtocolVersions: unknown;
  offeredMediaProfileVersions: unknown;
  networkKey?: string | null;
  videoEnabled?: boolean;
  videoRolloutReady?: boolean;
}): Promise<MutationResult & { ringTargetCount: number }> {
  const callId = requireUUID(p.callId, "callId");
  const dialogId = requireUUID(p.dialogId, "dialogId");
  const callerCommitment = decodeBase64(p.callerCommitment, "callerCommitment", 32);
  const protocols = requireProtocolOffer(p.supportedProtocolVersions);
  const mediaProfiles = requireMediaOffer(p.offeredMediaProfileVersions);
  const initialKind: CallInitialKind = mediaProfiles.length === 1 && mediaProfiles[0] === 2
    ? "video" : "voice";
  const callerVideoEnabled = p.videoEnabled ?? videoCallsEnabledForAccount(p.callerAccountId);
  await expireStaleCalls(sql, p.callerAccountId, 10);

  return await sql.begin(async (tx) => {
    // A call UUID is the idempotency key. Serialize before the first lookup so a concurrent retry
    // observes the winner's committed row instead of falling through into busy/unique failures.
    await lockMutationKeys(tx, [`call-id:${callId}`]);
    await requireActiveDevice(tx, p.callerAccountId, p.callerDeviceId);
    const duplicate = (await tx`SELECT * FROM calls WHERE id = ${callId} FOR UPDATE`)[0];
    if (duplicate) {
      const sameProtocols = JSON.stringify(Array.from(duplicate.supported_protocols ?? [], Number))
        === JSON.stringify(protocols);
      const sameMediaProfiles = JSON.stringify(Array.from(duplicate.offered_media_profiles ?? [], Number))
        === JSON.stringify(mediaProfiles);
      if (duplicate.caller_account_id !== p.callerAccountId || duplicate.caller_device_id !== p.callerDeviceId
        || duplicate.dialog_id !== dialogId || !Buffer.from(duplicate.caller_commitment).equals(callerCommitment)
        || !sameProtocols || !sameMediaProfiles) {
        throw new CallError("callId is already in use", "idempotency_conflict", 409);
      }
      const ringTargetCount = Number((await tx`
        SELECT count(*) AS count FROM call_ring_targets WHERE call_id = ${callId}`)[0].count);
      return { call: snapshot(duplicate), ringTargetCount, hints: [] };
    }

    // Discover the immutable direct pair without taking row locks, then acquire the shared
    // account-mutation boundary before locking membership rows. Blocking takes that advisory
    // boundary first, so reversing the order here can deadlock (membership -> advisory versus
    // advisory -> membership) when a new call races a block.
    const candidatePair = (await tx`
      SELECT account_low, account_high
      FROM direct_dialog_pairs
      WHERE dialog_id = ${dialogId}
        AND (${p.callerAccountId}::uuid = account_low OR ${p.callerAccountId}::uuid = account_high)`)[0];
    if (!candidatePair) throw new CallError("eligible direct dialog required", "ineligible", 403);
    const calleeAccountId = candidatePair.account_low === p.callerAccountId
      ? candidatePair.account_high
      : candidatePair.account_low;
    const participants = [p.callerAccountId, calleeAccountId].sort();
    await lockAccountMutations(tx, participants);

    // Revalidate membership and account status while locked. Anchor the query to the discovered
    // pair so an unexpected concurrent replacement fails closed instead of changing lock scope.
    const pair = (await tx`
      SELECT pair.account_low, pair.account_high
      FROM direct_dialog_pairs pair
      JOIN dialog_members low_member ON low_member.dialog_id = pair.dialog_id
        AND low_member.account_id = pair.account_low AND low_member.left_at IS NULL
      JOIN dialog_members high_member ON high_member.dialog_id = pair.dialog_id
        AND high_member.account_id = pair.account_high AND high_member.left_at IS NULL
      JOIN accounts low_account ON low_account.id = pair.account_low AND low_account.status IN ('active','limited')
      JOIN accounts high_account ON high_account.id = pair.account_high AND high_account.status IN ('active','limited')
      WHERE pair.dialog_id = ${dialogId}
        AND pair.account_low = ${candidatePair.account_low}
        AND pair.account_high = ${candidatePair.account_high}
        AND (${p.callerAccountId}::uuid = pair.account_low OR ${p.callerAccountId}::uuid = pair.account_high)
      FOR SHARE`)[0];
    if (!pair) throw new CallError("eligible direct dialog required", "ineligible", 403);
    // Both accounts must be inside an account-scoped rollout. Direct unit callers can omit
    // `videoRolloutReady` and provide an explicit videoEnabled value for deterministic fixtures.
    const recipientVideoEnabled = p.videoRolloutReady == null
      ? callerVideoEnabled
      : videoCallsEnabledForAccount(calleeAccountId, p.videoRolloutReady);
    const videoEnabled = callerVideoEnabled && recipientVideoEnabled;
    const selectableMediaProfiles = mediaProfiles.filter((profile) => profile === 1 || videoEnabled);
    // Rollout policy is sampled only for a genuinely new call. The duplicate path above retains
    // the call's persisted creation-time selection even if either account leaves the rollout.
    if (initialKind === "video" && !videoEnabled) {
      throw new CallError("video calls are unavailable", "video_unavailable", 409);
    }
    if (selectableMediaProfiles.length === 0) {
      throw new CallError("video calls are unavailable", "video_unavailable", 409);
    }
    const blocked = await tx`
      SELECT 1 FROM account_blocks
      WHERE (blocker_account_id = ${p.callerAccountId} AND blocked_account_id = ${calleeAccountId})
         OR (blocker_account_id = ${calleeAccountId} AND blocked_account_id = ${p.callerAccountId})
      LIMIT 1`;
    if (blocked.length) throw new CallError("calls are blocked", "blocked", 403);

    const reciprocal = (await tx`
      SELECT
        EXISTS (
          SELECT 1 FROM messages
          WHERE dialog_id = ${dialogId} AND sender_account_id = ${p.callerAccountId}
            AND state = 'visible' AND kind <> 'service'
            AND (expires_at IS NULL OR expires_at > now())
          LIMIT 1
        ) AS caller_spoke,
        EXISTS (
          SELECT 1 FROM messages
          WHERE dialog_id = ${dialogId} AND sender_account_id = ${calleeAccountId}
            AND state = 'visible' AND kind <> 'service'
            AND (expires_at IS NULL OR expires_at > now())
          LIMIT 1
        ) AS callee_spoke`)[0];
    if (!reciprocal?.caller_spoke || !reciprocal?.callee_spoke) {
      throw new CallError("recipient must have replied before calls are allowed", "ineligible", 403);
    }

    const networkInput = p.networkKey ? `call-network|${p.networkKey}` : null;
    const networkIndex = networkInput ? tokenHashIndex(networkInput) : null;
    const networkHash = networkIndex?.digest ?? null;
    const networkHashes = networkInput
      ? tokenHashCandidates(networkInput).map((candidate) => candidate.digest)
      : [];
    await lockMutationKeys(tx, [
      `call-rate-caller:${p.callerAccountId}`,
      `call-rate-callee:${calleeAccountId}`,
      ...networkHashes.map((hash) => `call-rate-network:${hash.toString("hex")}`),
    ]);
    const rates = (await tx`
      SELECT
        (SELECT count(*) FROM call_invite_attempts
          WHERE caller_account_id = ${p.callerAccountId} AND created_at > now() - interval '10 minutes') AS caller_count,
        (SELECT count(*) FROM call_invite_attempts
          WHERE callee_account_id = ${calleeAccountId} AND created_at > now() - interval '1 minute') AS callee_count,
        (SELECT count(*) FROM call_invite_attempts
          WHERE ${networkHash}::bytea IS NOT NULL
            AND network_hash IN (
              SELECT decode(value, 'hex') FROM unnest(
                ${tx.array(networkHashes.map((hash) => hash.toString("hex")), "text")}::text[]
              ) AS candidate(value)
            )
            AND created_at > now() - interval '10 minutes') AS network_count`)[0];
    if (Number(rates.caller_count) >= 10 || Number(rates.callee_count) >= 5 || Number(rates.network_count) >= 30) {
      throw new CallError("too many call attempts", "rate_limited", 429, {}, 60);
    }
    await tx`
      INSERT INTO call_invite_attempts
        (caller_account_id, callee_account_id, caller_device_id, network_hash, network_key_id)
      VALUES (${p.callerAccountId}, ${calleeAccountId}, ${p.callerDeviceId},
              ${networkHash}, ${networkIndex?.keyId ?? null})`;

    await tx`DELETE FROM call_participant_leases WHERE expires_at <= now()`;
    const busy = (await tx`
      SELECT l.call_id, c.caller_account_id, c.callee_account_id
      FROM call_participant_leases l JOIN calls c ON c.id = l.call_id
      WHERE l.account_id = ANY(${tx.array(participants, "UUID")})
      ORDER BY l.call_id LIMIT 1`)[0];
    if (busy) {
      const maySeeExistingCall = busy.caller_account_id === p.callerAccountId
        || busy.callee_account_id === p.callerAccountId;
      throw new CallError("an account is already in a call", "busy", 409,
        maySeeExistingCall ? { existingCallId: busy.call_id } : {});
    }

    const candidateTargets = await tx`
      SELECT id, voip_push_token_hash, supported_call_protocol_versions,
        supported_call_media_profile_versions, call_view_version
      FROM devices
      WHERE account_id = ${calleeAccountId} AND platform = 'ios' AND revoked_at IS NULL
        AND (
          (voip_push_token_hash IS NOT NULL
            AND voip_push_token_ciphertext IS NOT NULL
            AND voip_push_token_nonce IS NOT NULL
            AND voip_push_token_key_id IS NOT NULL
            AND voip_push_environment IS NOT NULL)
          OR EXISTS (
            SELECT 1 FROM push_account_bindings binding
            JOIN push_installations installation USING (installation_id)
            WHERE binding.device_id = devices.id AND binding.account_id = devices.account_id
              AND binding.active AND binding.voip_enabled
              AND installation.voip_token_ciphertext IS NOT NULL
          )
        )
      ORDER BY id FOR SHARE`;
    const targets = candidateTargets.flatMap((target: CallRow) => {
      const targetProtocols = numericArray(target.supported_call_protocol_versions, [1]);
      const targetMedia = numericArray(target.supported_call_media_profile_versions, [1]);
      const viewVersion = Number(target.call_view_version ?? 1);
      const selectableProtocols = protocols.filter((version) =>
        SUPPORTED_PROTOCOLS.includes(version as 1) && targetProtocols.includes(version));
      const selectableForTarget = selectableMediaProfiles.filter((profile) =>
        targetMedia.includes(profile) && (profile !== 2 || viewVersion >= 2));
      if (!selectableProtocols.length || !selectableForTarget.length) return [];
      if (initialKind === "video" && (!selectableForTarget.includes(2) || viewVersion < 2)) return [];
      return [{ ...target, selectableProtocols, selectableMediaProfiles: selectableForTarget, viewVersion }];
    });
    if (!targets.length) throw new CallError("recipient has no eligible device", "callee_unavailable", 409);

    let row = (await tx`
      INSERT INTO calls
        (id, dialog_id, caller_account_id, caller_device_id, callee_account_id,
         supported_protocols, offered_media_profiles, initial_kind, selectable_media_profiles,
         caller_commitment, expires_at)
      VALUES (${callId}, ${dialogId}, ${p.callerAccountId}, ${p.callerDeviceId}, ${calleeAccountId},
        ${tx.array(protocols, "INT4")}, ${tx.array(mediaProfiles, "INT4")}, ${initialKind},
        ${tx.array(selectableMediaProfiles, "INT4")}, ${callerCommitment},
        now() + (${RING_SECONDS} * interval '1 second'))
      RETURNING *`)[0];
    for (const accountId of participants) {
      await tx`
        INSERT INTO call_participant_leases (account_id, call_id, expires_at)
        VALUES (${accountId}, ${callId}, ${row.expires_at})`;
    }
    for (const target of targets) {
      await tx`
        INSERT INTO call_ring_targets
          (call_id, device_id, selectable_protocols, selectable_media_profiles, call_view_version)
        VALUES (${callId}, ${target.id}, ${tx.array(target.selectableProtocols, "INT4")},
          ${tx.array(target.selectableMediaProfiles, "INT4")}, ${target.viewVersion})`;
      await tx`
        INSERT INTO voip_push_deliveries
          (call_id, caller_account_id, initial_kind, device_id, expires_at)
        VALUES (${callId}, ${p.callerAccountId}, ${initialKind}, ${target.id}, ${row.expires_at})`;
    }
    row = await appendControlEvent(tx, row, "requested", p.callerAccountId, p.callerDeviceId, {
      callerCommitment: callerCommitment.toString("base64"),
      supportedProtocolVersions: protocols,
      offeredMediaProfileVersions: mediaProfiles,
      initialKind,
    });
    return { call: snapshot(row), ringTargetCount: targets.length, hints: await hints(tx, row) };
  });
}

export async function acceptCall(sql: SQL, p: {
  accountId: string; deviceId: string; callId: unknown;
  calleeCommitment: unknown; protocolVersion: unknown; selectedMediaProfileVersion: unknown;
}): Promise<MutationResult> {
  const callId = requireUUID(p.callId, "callId");
  const calleeCommitment = decodeBase64(p.calleeCommitment, "calleeCommitment", 32);
  const protocolVersion = Number(p.protocolVersion);
  const mediaProfileVersion = Number(p.selectedMediaProfileVersion);
  if (!Number.isSafeInteger(protocolVersion)
    || !SUPPORTED_PROTOCOLS.includes(protocolVersion as 1)) {
    throw new CallError("unsupported protocol", "unsupported_protocol", 409);
  }
  if (!Number.isSafeInteger(mediaProfileVersion)
    || !SUPPORTED_MEDIA_PROFILES.includes(mediaProfileVersion as 1 | 2)) {
    throw new CallError("unsupported media profile", "unsupported_media_profile", 409);
  }
  await expireStaleCalls(sql, p.accountId, 10);
  return await sql.begin(async (tx) => {
    await requireActiveDevice(tx, p.accountId, p.deviceId);
    let row = await lockedCall(tx, callId);
    await callAccess(tx, row, p.accountId, p.deviceId);
    requireUnexpired(row);
    if (row.callee_account_id !== p.accountId) throw new CallError("only the recipient can accept", "invalid_state", 409);
    if (row.accepted_device_id) {
      if (row.accepted_device_id !== p.deviceId) {
        throw new CallError("call answered on another device", "answered_elsewhere", 409);
      }
      if (!Buffer.from(row.callee_commitment).equals(calleeCommitment)
        || Number(row.protocol_version) !== protocolVersion
        || Number(row.media_profile_version) !== mediaProfileVersion) {
        throw new CallError("accept parameters changed on retry", "idempotency_conflict", 409);
      }
      return { call: snapshot(row), hints: [] };
    }
    if (row.state !== "requested") throw new CallError("call cannot be accepted", "invalid_state", 409);
    if (!numericArray(row.supported_protocols).includes(protocolVersion)
      || !numericArray(row.offered_media_profiles).includes(mediaProfileVersion)) {
      throw new CallError("selected versions were not offered", "downgrade_detected", 409);
    }
    if (!numericArray(row.selectable_media_profiles, [1]).includes(mediaProfileVersion)) {
      throw new CallError("media profile is unavailable for this call", "video_unavailable", 409);
    }
    const target = (await tx`
      SELECT rt.*, d.supported_call_protocol_versions, d.supported_call_media_profile_versions,
        rt.call_view_version AS ring_call_view_version,
        d.call_view_version AS device_call_view_version
      FROM call_ring_targets rt JOIN devices d ON d.id = rt.device_id
      WHERE rt.call_id = ${callId} AND rt.device_id = ${p.deviceId}
      FOR UPDATE OF rt, d`)[0];
    if (!target) throw new CallError("device was not rung", "not_ring_target", 403);
    if (target.status !== "ringing") {
      throw new CallError("device is no longer ringing", "invalid_state", 409);
    }
    const registeredProtocols = numericArray(target.supported_call_protocol_versions, [1]);
    const registeredMedia = numericArray(target.supported_call_media_profile_versions, [1]);
    const targetProtocols = numericArray(target.selectable_protocols, [1]);
    const targetMedia = numericArray(target.selectable_media_profiles, [1]);
    if (!registeredProtocols.includes(protocolVersion) || !targetProtocols.includes(protocolVersion)
      || !registeredMedia.includes(mediaProfileVersion) || !targetMedia.includes(mediaProfileVersion)
      || (mediaProfileVersion === 2
        && (Number(target.ring_call_view_version ?? 1) < 2
          || Number(target.device_call_view_version ?? 1) < 2))) {
      throw new CallError("device did not advertise the selected media profile", "unsupported_media_profile", 409);
    }
    row = (await tx`
      UPDATE calls SET state = 'accepted', protocol_version = ${protocolVersion},
        media_profile_version = ${mediaProfileVersion},
        accepted_device_id = ${p.deviceId}, callee_commitment = ${calleeCommitment}, accepted_at = now(),
        expires_at = now() + (${KEY_EXCHANGE_SECONDS} * interval '1 second')
      WHERE id = ${callId} RETURNING *`)[0];
    await tx`
      UPDATE call_participant_leases SET expires_at = ${row.expires_at} WHERE call_id = ${callId}`;
    await tx`
      UPDATE call_ring_targets SET
        status = CASE
          WHEN device_id = ${p.deviceId} THEN 'accepted'
          WHEN status = 'ringing' THEN 'answered_elsewhere'
          ELSE status
        END,
        responded_at = CASE
          WHEN device_id = ${p.deviceId} OR status = 'ringing' THEN now()
          ELSE responded_at
        END
      WHERE call_id = ${callId}`;
    await tx`
      UPDATE voip_push_deliveries SET status = 'dead', claimed_at = NULL,
        last_error = CASE WHEN device_id = ${p.deviceId} THEN 'answered' ELSE 'answered elsewhere' END
      WHERE call_id = ${callId} AND status IN ('pending','sending')`;
    row = await appendControlEvent(tx, row, "accepted", p.accountId, p.deviceId, {
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion,
      selectedMediaProfileVersion: mediaProfileVersion,
    });
    return { call: snapshot(row), hints: await hints(tx, row, true) };
  });
}

export async function revealCallKey(sql: SQL, p: {
  accountId: string; deviceId: string; callId: unknown;
  publicKey: unknown; nonce: unknown; fingerprint: unknown; confirmation?: unknown;
}): Promise<MutationResult> {
  const callId = requireUUID(p.callId, "callId");
  const publicKey = decodeBase64(p.publicKey, "publicKey", 32);
  const nonce = decodeBase64(p.nonce, "nonce", 32);
  const fingerprint = decodeBase64(p.fingerprint, "fingerprint", 32);
  await expireStaleCalls(sql, p.accountId, 10);
  return await sql.begin(async (tx) => {
    await requireActiveDevice(tx, p.accountId, p.deviceId);
    let row = await lockedCall(tx, callId);
    await callAccess(tx, row, p.accountId, p.deviceId);
    requireUnexpired(row);
    const callerRole = row.caller_account_id === p.accountId;
    if (callerRole && row.caller_device_id !== p.deviceId) {
      throw new CallError("only the initiating caller device can reveal", "invalid_device", 403);
    }
    if (!callerRole && (row.callee_account_id !== p.accountId || row.accepted_device_id !== p.deviceId)) {
      throw new CallError("only the accepting recipient device can reveal", "invalid_device", 403);
    }
    if (callerRole) {
      if (row.caller_public_key) {
        if (!Buffer.from(row.caller_public_key).equals(publicKey) || !Buffer.from(row.caller_nonce).equals(nonce)
          || !Buffer.from(row.caller_fingerprint).equals(fingerprint)) {
          throw new CallError("reveal parameters changed on retry", "idempotency_conflict", 409);
        }
        return { call: snapshot(row), hints: [] };
      }
      if (row.state !== "accepted") throw new CallError("call is not awaiting caller reveal", "invalid_state", 409);
      const expected = callerCommitmentV1(commitmentContext(row), { publicKey, nonce, fingerprint });
      if (!expected.equals(Buffer.from(row.caller_commitment))) {
        throw new CallError("caller reveal does not match its commitment", "invalid_commitment", 409);
      }
      row = (await tx`
        UPDATE calls SET state = 'key_exchange', caller_public_key = ${publicKey}, caller_nonce = ${nonce},
          caller_fingerprint = ${fingerprint}, expires_at = now() + (${KEY_EXCHANGE_SECONDS} * interval '1 second')
        WHERE id = ${callId} RETURNING *`)[0];
    } else {
      const confirmation = decodeBase64(p.confirmation, "confirmation", 32);
      if (row.callee_public_key) {
        if (!Buffer.from(row.callee_public_key).equals(publicKey) || !Buffer.from(row.callee_nonce).equals(nonce)
          || !Buffer.from(row.callee_fingerprint).equals(fingerprint)
          || !Buffer.from(row.callee_confirmation).equals(confirmation)) {
          throw new CallError("reveal parameters changed on retry", "idempotency_conflict", 409);
        }
        return { call: snapshot(row), hints: [] };
      }
      if (row.state !== "key_exchange" || !row.caller_public_key) {
        throw new CallError("call is not awaiting recipient reveal", "invalid_state", 409);
      }
      const expected = calleeCommitmentV1(
        commitmentContext(row), Buffer.from(row.caller_commitment), row.accepted_device_id,
        Number(row.protocol_version), Number(row.media_profile_version), { publicKey, nonce, fingerprint },
      );
      if (!expected.equals(Buffer.from(row.callee_commitment))) {
        throw new CallError("recipient reveal does not match its commitment", "invalid_commitment", 409);
      }
      row = (await tx`
        UPDATE calls SET callee_public_key = ${publicKey}, callee_nonce = ${nonce},
          callee_fingerprint = ${fingerprint}, callee_confirmation = ${confirmation},
          expires_at = now() + (${KEY_EXCHANGE_SECONDS} * interval '1 second')
        WHERE id = ${callId} RETURNING *`)[0];
    }
    await tx`UPDATE call_participant_leases SET expires_at = ${row.expires_at} WHERE call_id = ${callId}`;
    row = await appendControlEvent(tx, row, "revealed", p.accountId, p.deviceId, {
      role: callerRole ? "caller" : "callee",
      publicKey: publicKey.toString("base64"),
      nonce: nonce.toString("base64"),
      fingerprint: fingerprint.toString("base64"),
      ...(callerRole ? {} : { confirmation: Buffer.from(row.callee_confirmation).toString("base64") }),
    });
    return { call: snapshot(row), hints: await hints(tx, row) };
  });
}

export async function confirmCallKey(sql: SQL, p: {
  accountId: string; deviceId: string; callId: unknown; confirmation: unknown;
}): Promise<MutationResult> {
  const callId = requireUUID(p.callId, "callId");
  const confirmation = decodeBase64(p.confirmation, "confirmation", 32);
  await expireStaleCalls(sql, p.accountId, 10);
  return await sql.begin(async (tx) => {
    await requireActiveDevice(tx, p.accountId, p.deviceId);
    let row = await lockedCall(tx, callId);
    await callAccess(tx, row, p.accountId, p.deviceId);
    requireUnexpired(row);
    if (row.caller_account_id !== p.accountId || row.caller_device_id !== p.deviceId) {
      throw new CallError("only the initiating caller device can confirm", "invalid_state", 409);
    }
    if (row.caller_confirmation) {
      if (!Buffer.from(row.caller_confirmation).equals(confirmation)) {
        throw new CallError("confirmation changed on retry", "idempotency_conflict", 409);
      }
      return { call: snapshot(row), hints: [] };
    }
    if (row.state !== "key_exchange" || !row.callee_public_key || !row.callee_confirmation) {
      throw new CallError("call is not awaiting caller confirmation", "invalid_state", 409);
    }
    row = (await tx`
      UPDATE calls SET state = 'active', caller_confirmation = ${confirmation}, confirmed_at = now(),
        expires_at = now() + (${ACTIVE_SECONDS} * interval '1 second')
      WHERE id = ${callId} RETURNING *`)[0];
    await tx`UPDATE call_participant_leases SET expires_at = ${row.expires_at} WHERE call_id = ${callId}`;
    row = await appendControlEvent(tx, row, "confirmed", p.accountId, p.deviceId, {
      confirmation: confirmation.toString("base64"),
    });
    return { call: snapshot(row), hints: await hints(tx, row) };
  });
}

export async function sendEncryptedCallEvent(sql: SQL, p: {
  accountId: string; deviceId: string; callId: unknown; senderSequence: unknown; ciphertext: unknown;
  kind: unknown; expiresAtMilliseconds: unknown; version: unknown;
}): Promise<{ event: CallEventDTO; hints: CallHint[]; syncPushes?: Push[] }> {
  const callId = requireUUID(p.callId, "callId");
  const senderSequence = Number(p.senderSequence);
  if (!Number.isSafeInteger(senderSequence) || senderSequence <= 0) {
    throw new CallError("senderSequence must be a positive integer", "invalid_request");
  }
  const ciphertext = decodeBase64(p.ciphertext, "ciphertext");
  if (ciphertext.length === 0 || ciphertext.length > MAX_SIGNAL_BYTES) {
    throw new CallError("ciphertext is too large", "payload_too_large", 413);
  }
  const version = Number(p.version);
  if (version !== CURRENT_PROTOCOL) throw new CallError("unsupported signal version", "unsupported_protocol", 409);
  const kinds = new Set(["offer", "answer", "ice_candidate", "ice_restart", "hangup", "control"]);
  if (typeof p.kind !== "string" || !kinds.has(p.kind)) {
    throw new CallError("signal kind is invalid", "invalid_request");
  }
  const signalKind = p.kind as "offer" | "answer" | "ice_candidate" | "ice_restart" | "hangup" | "control";
  const kindByteLimit = signalKind === "ice_candidate"
    ? MAX_CANDIDATE_SIGNAL_BYTES
    : (signalKind === "hangup" || signalKind === "control")
      ? MAX_CONTROL_SIGNAL_BYTES
      : MAX_SIGNAL_BYTES;
  if (ciphertext.length > kindByteLimit) {
    throw new CallError("ciphertext is too large for signal kind", "payload_too_large", 413);
  }
  const envelopeExpiresAt = Number(p.expiresAtMilliseconds);
  const now = Date.now();
  if (!Number.isSafeInteger(envelopeExpiresAt) || envelopeExpiresAt < now - 5_000
    || envelopeExpiresAt > now + 5 * 60_000) {
    throw new CallError("signal expiry is invalid", "invalid_request");
  }
  await expireStaleCalls(sql, p.accountId, 10);
  const result = await sql.begin(async (tx) => {
    await requireActiveDevice(tx, p.accountId, p.deviceId);
    let row = await lockedCall(tx, callId);
    await callAccess(tx, row, p.accountId, p.deviceId);
    requireUnexpired(row);
    if (row.caller_account_id === p.accountId && row.caller_device_id !== p.deviceId) {
      throw new CallError("only the initiating caller device may signal", "invalid_device", 403);
    }
    if (row.callee_account_id === p.accountId && row.accepted_device_id !== p.deviceId) {
      throw new CallError("only the accepting recipient device may signal", "invalid_device", 403);
    }
    const existing = (await tx`
      SELECT * FROM call_events
      WHERE call_id = ${callId} AND sender_device_id = ${p.deviceId} AND sender_sequence = ${senderSequence}`)[0];
    if (existing) {
      if (!Buffer.from(existing.ciphertext).equals(ciphertext) || existing.signal_kind !== p.kind
        || Number(existing.signal_version) !== version
        || new Date(existing.envelope_expires_at).getTime() !== envelopeExpiresAt) {
        throw new CallError("sender sequence was reused with different ciphertext", "sequence_reuse", 409);
      }
      return { event: eventDTO(existing), hints: [] as CallHint[], terminal: false, row };
    }
    if (row.state !== "active") throw new CallError("encrypted signaling requires an active call", "invalid_state", 409);
    const isNegotiation = signalKind === "offer" || signalKind === "answer" || signalKind === "ice_restart";
    const budget = (await tx`
      INSERT INTO call_signal_budgets
        (call_id, sender_device_id, window_started_at, event_count, ciphertext_bytes,
         negotiation_event_count)
      VALUES (${callId}, ${p.deviceId}, now(), 1, ${ciphertext.length}, ${isNegotiation ? 1 : 0})
      ON CONFLICT (call_id, sender_device_id) DO UPDATE SET
        window_started_at = CASE
          WHEN call_signal_budgets.window_started_at <= now()
            - (${SIGNAL_BUDGET_WINDOW_SECONDS} * interval '1 second') THEN now()
          ELSE call_signal_budgets.window_started_at END,
        event_count = CASE
          WHEN call_signal_budgets.window_started_at <= now()
            - (${SIGNAL_BUDGET_WINDOW_SECONDS} * interval '1 second') THEN 1
          ELSE call_signal_budgets.event_count + 1 END,
        ciphertext_bytes = CASE
          WHEN call_signal_budgets.window_started_at <= now()
            - (${SIGNAL_BUDGET_WINDOW_SECONDS} * interval '1 second') THEN ${ciphertext.length}
          ELSE call_signal_budgets.ciphertext_bytes + ${ciphertext.length} END,
        negotiation_event_count = CASE
          WHEN call_signal_budgets.window_started_at <= now()
            - (${SIGNAL_BUDGET_WINDOW_SECONDS} * interval '1 second') THEN ${isNegotiation ? 1 : 0}
          ELSE call_signal_budgets.negotiation_event_count + ${isNegotiation ? 1 : 0} END
      RETURNING event_count, ciphertext_bytes, negotiation_event_count,
        GREATEST(1, CEIL(EXTRACT(EPOCH FROM
          (window_started_at + (${SIGNAL_BUDGET_WINDOW_SECONDS} * interval '1 second') - now())
        )))::int AS retry_after`)[0];
    if (Number(budget.event_count) > MAX_SIGNAL_EVENTS_PER_WINDOW
      || Number(budget.ciphertext_bytes) > MAX_SIGNAL_BYTES_PER_WINDOW
      || Number(budget.negotiation_event_count) > MAX_NEGOTIATION_EVENTS_PER_WINDOW) {
      throw new CallError(
        "encrypted signaling budget exceeded",
        "rate_limited",
        429,
        {},
        Math.min(SIGNAL_BUDGET_WINDOW_SECONDS, Math.max(1, Number(budget.retry_after))),
      );
    }
    row = (await tx`
      UPDATE calls SET latest_event_seq = latest_event_seq + 1,
        expires_at = now() + (${ACTIVE_SECONDS} * interval '1 second')
      WHERE id = ${callId} RETURNING *`)[0];
    await tx`UPDATE call_participant_leases SET expires_at = ${row.expires_at} WHERE call_id = ${callId}`;
    const event = (await tx`
      INSERT INTO call_events
        (call_id, event_seq, event_type, sender_account_id, sender_device_id, sender_sequence,
         signal_version, signal_kind, envelope_expires_at, ciphertext, expires_at)
      VALUES (${callId}, ${row.latest_event_seq}, 'encrypted', ${p.accountId}, ${p.deviceId},
        ${senderSequence}, ${version}, ${signalKind}, to_timestamp(${envelopeExpiresAt} / 1000.0),
        ${ciphertext}, to_timestamp(${envelopeExpiresAt} / 1000.0))
      RETURNING *`)[0];
    if (signalKind === "hangup") {
      // A participant is already authorized to end its call. Terminalize in the same transaction
      // as the authenticated outer hangup kind so a hostile peer cannot make the other client stop
      // and then keep both account leases alive with low-rate control traffic.
      row = await finishCallTx(tx, row, "remote_ended", p.accountId, p.deviceId);
    } else {
      await notify(tx, row);
    }
    return { event: eventDTO(event), hints: await hints(tx, row), terminal: signalKind === "hangup", row };
  });
  const history = result.terminal
    ? await processCallHistoryOutbox(sql, 1, result.row.id)
    : { pushes: [] as Push[] };
  return { event: result.event, hints: result.hints, syncPushes: history.pushes };
}

export async function getCallEvents(sql: SQL, accountId: string, deviceId: string, rawCallId: unknown,
  rawAfter: unknown = 0, rawLimit: unknown = 100): Promise<{
    callId: string; events: CallEventDTO[]; latestEventSeq: number; hasMore: boolean;
  }> {
  const callId = requireUUID(rawCallId, "callId");
  const after = Number(rawAfter ?? 0);
  const requestedLimit = Number(rawLimit ?? 100);
  if (!Number.isSafeInteger(after) || after < 0) throw new CallError("after is invalid", "invalid_request");
  const limit = Number.isSafeInteger(requestedLimit) ? Math.max(1, Math.min(200, requestedLimit)) : 100;
  await expireStaleCalls(sql, accountId, 10);
  const row = (await sql`SELECT * FROM calls WHERE id = ${callId}`)[0];
  if (!row) throw new CallError("call not found", "not_found", 404);
  const access = await callAccess(sql, row, accountId, deviceId);
  if (access.view === "lifecycle") {
    return { callId, events: [], latestEventSeq: 0, hasMore: false };
  }
  const allowedTypes = access.view === "full"
    ? ["requested", "accepted", "revealed", "confirmed", "encrypted", "ended"]
    : access.view === "invitation" ? ["requested", "ended"] : ["ended"];
  const events = await sql`
    SELECT * FROM call_events WHERE call_id = ${callId} AND event_seq > ${after}
      AND event_type = ANY(${sql.array(allowedTypes, "TEXT")})
      AND (event_type <> 'encrypted' OR envelope_expires_at > now())
    ORDER BY event_seq LIMIT ${limit + 1}`;
  return {
    callId,
    events: events.slice(0, limit).map(eventDTO),
    latestEventSeq: Number(row.latest_event_seq),
    hasMore: events.length > limit,
  };
}

export async function getActiveCalls(
  sql: SQL,
  accountId: string,
  deviceId: string,
): Promise<{ calls: CallSnapshot[] }> {
  await expireStaleCalls(sql, accountId, 50);
  const rows = await sql`
    SELECT * FROM calls
    WHERE state <> 'ended' AND (
      (caller_account_id = ${accountId} AND caller_device_id = ${deviceId})
      OR (callee_account_id = ${accountId} AND EXISTS (
        SELECT 1 FROM call_ring_targets rt WHERE rt.call_id = calls.id AND rt.device_id = ${deviceId}
      ))
    )
    ORDER BY created_at DESC`;
  const calls: CallSnapshot[] = [];
  for (const row of rows) {
    calls.push(await scopedSnapshot(sql, row, accountId, deviceId));
  }
  return { calls };
}

export async function getCall(
  sql: SQL,
  accountId: string,
  deviceId: string,
  rawCallId: unknown,
): Promise<{ call: CallSnapshot }> {
  const callId = requireUUID(rawCallId, "callId");
  await expireStaleCalls(sql, accountId, 10);
  const row = (await sql`SELECT * FROM calls WHERE id = ${callId}`)[0];
  if (!row) throw new CallError("call not found", "not_found", 404);
  return { call: await scopedSnapshot(sql, row, accountId, deviceId) };
}

async function terminalAction(sql: SQL, p: {
  accountId: string; deviceId: string; callId: unknown; action: "cancel" | "end"; reason?: unknown;
}): Promise<MutationResult> {
  const callId = requireUUID(p.callId, "callId");
  await expireStaleCalls(sql, p.accountId, 10);
  const result = await sql.begin(async (tx) => {
    await requireActiveDevice(tx, p.accountId, p.deviceId);
    const row = await lockedCall(tx, callId);
    await callAccess(tx, row, p.accountId, p.deviceId);
    if (p.action === "cancel" && (row.caller_account_id !== p.accountId || row.caller_device_id !== p.deviceId)) {
      throw new CallError("only the initiating device can cancel", "invalid_state", 409);
    }
    if (p.action === "end") requireOwningDevice(row, p.accountId, p.deviceId);
    if (row.state === "ended") return { row, call: snapshot(row), hints: [] };
    requireUnexpired(row);
    const allowedReasons = new Set([
      "remote_ended", "local_ended", "network_lost", "security_error", "permission_denied", "failed",
    ]);
    const requestedReason = typeof p.reason === "string" && allowedReasons.has(p.reason) ? p.reason : "local_ended";
    const reason = p.action === "cancel" ? "cancelled" : requestedReason;
    const ended = await finishCallTx(tx, row, reason, p.accountId, p.deviceId);
    return { row: ended, call: snapshot(ended), hints: await hints(tx, ended) };
  });
  const history = await processCallHistoryOutbox(sql, 1, result.row.id);
  return { call: result.call, hints: result.hints, syncPushes: history.pushes };
}

export async function declineCall(sql: SQL, p: {
  accountId: string; deviceId: string; callId: unknown; reason?: unknown;
}): Promise<MutationResult> {
  const callId = requireUUID(p.callId, "callId");
  await expireStaleCalls(sql, p.accountId, 10);
  const result = await sql.begin(async (tx) => {
    await requireActiveDevice(tx, p.accountId, p.deviceId);
    let row = await lockedCall(tx, callId);
    await callAccess(tx, row, p.accountId, p.deviceId);
    if (row.callee_account_id !== p.accountId) {
      throw new CallError("only the recipient can decline", "invalid_state", 409);
    }
    const target = (await tx`
      SELECT status FROM call_ring_targets
      WHERE call_id = ${callId} AND device_id = ${p.deviceId} FOR UPDATE`)[0];
    if (!target) throw new CallError("device was not rung", "not_ring_target", 403);
    if (target.status === "declined") {
      return {
        row,
        call: await scopedSnapshot(tx, row, p.accountId, p.deviceId),
        hints: [] as CallHint[],
        terminal: row.state === "ended",
      };
    }
    if (row.state === "ended") {
      return {
        row,
        call: await scopedSnapshot(tx, row, p.accountId, p.deviceId),
        hints: [] as CallHint[],
        terminal: true,
      };
    }
    requireUnexpired(row);
    if (row.state !== "requested" || target.status !== "ringing") {
      throw new CallError("an answered call cannot be declined", "invalid_state", 409);
    }
    await tx`
      UPDATE call_ring_targets SET status = 'declined', responded_at = now()
      WHERE call_id = ${callId} AND device_id = ${p.deviceId}`;
    await tx`
      UPDATE voip_push_deliveries SET status = 'dead', claimed_at = NULL,
        last_error = COALESCE(last_error, 'declined on device')
      WHERE call_id = ${callId} AND device_id = ${p.deviceId}
        AND status IN ('pending','sending')`;
    const remaining = await tx`
      SELECT 1 FROM call_ring_targets
      WHERE call_id = ${callId} AND status = 'ringing' LIMIT 1`;
    if (remaining.length) {
      return {
        row,
        call: await scopedSnapshot(tx, row, p.accountId, p.deviceId),
        hints: [] as CallHint[],
        terminal: false,
      };
    }
    row = await finishCallTx(tx, row, "declined", p.accountId, p.deviceId);
    return {
      row,
      call: await scopedSnapshot(tx, row, p.accountId, p.deviceId),
      hints: await hints(tx, row),
      terminal: true,
    };
  });
  const history = result.terminal
    ? await processCallHistoryOutbox(sql, 1, result.row.id)
    : { pushes: [] as Push[] };
  return { call: result.call, hints: result.hints, syncPushes: history.pushes };
}

export const cancelCall = (sql: SQL, p: Omit<Parameters<typeof terminalAction>[1], "action">) =>
  terminalAction(sql, { ...p, action: "cancel" });
export const endCall = (sql: SQL, p: Omit<Parameters<typeof terminalAction>[1], "action">) =>
  terminalAction(sql, { ...p, action: "end" });

async function terminateMatchingCallsTx(sql: SQL, where: "device" | "account", accountId: string,
  deviceId?: string, accountReason = "account_deleted"): Promise<CallRow[]> {
  const rows = where === "device"
    ? await sql`
        SELECT * FROM calls
        WHERE state <> 'ended' AND (
          (caller_account_id = ${accountId} AND caller_device_id = ${deviceId!})
          OR (callee_account_id = ${accountId} AND accepted_device_id = ${deviceId!})
        )
        ORDER BY id FOR UPDATE`
    : await sql`
        SELECT * FROM calls
        WHERE state <> 'ended' AND (caller_account_id = ${accountId} OR callee_account_id = ${accountId})
        ORDER BY id FOR UPDATE`;
  const result: CallRow[] = [];
  const reason = where === "device" ? "device_revoked" : accountReason;
  for (const row of rows) result.push(await finishCallTx(sql, row, reason, null, null));
  return result;
}

async function terminateMatchingCalls(sql: SQL, where: "device" | "account", accountId: string,
  deviceId?: string): Promise<{ hints: CallHint[]; syncPushes: Push[] }> {
  const ended = await sql.begin((tx) => terminateMatchingCallsTx(tx, where, accountId, deviceId));
  const syncPushes = await flushCallHistory(sql, ended);
  return { hints: await hintsForRows(sql, ended), syncPushes };
}

export function terminateCallsForDevice(sql: SQL, accountId: string, deviceId: string) {
  return terminateMatchingCalls(sql, "device", accountId, deviceId);
}

export function terminateCallsForAccount(sql: SQL, accountId: string) {
  return terminateMatchingCalls(sql, "account", accountId);
}

/** Device credentials and their owned calls commit or roll back as one unit. */
export async function revokeDeviceAndTerminateCalls(
  sql: SQL,
  accountId: string,
  deviceId: string,
  groupCallSFUControl?: GroupCallSFUControl,
): Promise<{
  revoked: true;
  hints: CallHint[];
  syncPushes: Push[];
  presenceBroadcasts: PresenceBroadcast[];
}> {
  let ended: CallRow[] = [];
  let affectedGroupCallIds: string[] = [];
  let presenceBroadcasts: PresenceBroadcast[] = [];
  const revoked = await revokeAuthDevice(sql, accountId, deviceId, {
    beforeCommit: async (tx) => {
      ended = await terminateMatchingCallsTx(tx, "device", accountId, deviceId);
      affectedGroupCallIds = await revokeGroupCallDeviceTx(tx, accountId, deviceId);
      presenceBroadcasts = await revokeDevicePresence(tx, accountId, deviceId);
      // PostgreSQL delivers NOTIFY only after commit, so remote WebSocket nodes cannot observe a
      // revocation before it is durable and cannot miss the signal after a successful response.
      await publishPresenceSessionRevocation(tx, accountId, deviceId, "device_revoked");
    },
  });
  if (affectedGroupCallIds.length) {
    await requireGroupCallSFUBarrierApplied(sql, affectedGroupCallIds, groupCallSFUControl);
  }
  const syncPushes = await flushCallHistory(sql, ended);
  return {
    ...revoked,
    hints: await hintsForRows(sql, ended),
    syncPushes,
    presenceBroadcasts,
  };
}

/** Account status, device revocation, and call termination commit or roll back as one unit. */
export async function deleteAccountAndTerminateCalls(
  sql: SQL,
  accountId: string,
  code: string,
  groupCallSFUControl?: GroupCallSFUControl,
): Promise<{
  deleted: true; hints: CallHint[]; syncPushes: Push[];
  presenceBroadcasts: PresenceBroadcast[];
}> {
  let ended: CallRow[] = [];
  let affectedGroupCallIds: string[] = [];
  let presenceBroadcasts: PresenceBroadcast[] = [];
  const deleted = await deleteAuthAccount(sql, accountId, code, {
    beforeCleanup: async (tx) => {
      presenceBroadcasts = await revokeAccountPresence(tx, accountId);
    },
    beforeCommit: async (tx) => {
      ended = await terminateMatchingCallsTx(tx, "account", accountId);
      affectedGroupCallIds = await revokeGroupCallAccountTx(tx, accountId);
      await handoffOwnedGroupsForDeletedAccount(tx, accountId);
      await purgeAccountDraftState(tx, accountId);
      await publishPresenceSessionRevocation(tx, accountId, null, "account_deleted");
    },
  });
  if (affectedGroupCallIds.length) {
    await requireGroupCallSFUBarrierApplied(sql, affectedGroupCallIds, groupCallSFUControl);
  }
  const syncPushes = await flushCallHistory(sql, ended);
  return {
    ...deleted,
    hints: await hintsForRows(sql, ended),
    syncPushes,
    presenceBroadcasts,
  };
}

export async function getIceConfig(sql: SQL, accountId: string, deviceId: string, rawCallId: unknown): Promise<{
  ttlSeconds: number;
  iceServers: Array<{ urls: string[]; username?: string; credential?: string }>;
}> {
  const callId = requireUUID(rawCallId, "callId");
  const turnUrls = (process.env.TOJ_TURN_URLS ?? "").split(",").map((v) => v.trim()).filter(Boolean);
  const stunUrls = (process.env.TOJ_STUN_URLS ?? "").split(",").map((v) => v.trim()).filter(Boolean);
  const secret = process.env.TOJ_TURN_SHARED_SECRET;
  const credentialTTLSeconds = 60 * 60;
  const username = await sql.begin(async (tx) => {
    await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`turn:${callId}:${accountId}`}, 0))`;
    await requireActiveDevice(tx, accountId, deviceId);
    const row = (await tx`
      SELECT *, expires_at <= now() AS deadline_elapsed
      FROM calls WHERE id = ${callId} FOR SHARE`)[0];
    if (!row) throw new CallError("call not found", "not_found", 404);
    await callAccess(tx, row, accountId, deviceId);
    // Authorization precedes every global lifecycle/configuration check so a losing ring target
    // cannot poll this endpoint to learn whether the winning call is still active or TURN is up.
    requireOwningDevice(row, accountId, deviceId);
    if (row.state === "ended") throw new CallError("call has ended", "expired", 410);
    requireUnexpired(row);
    if (!turnUrls.length || !secret) throw new CallError("TURN is unavailable", "turn_unavailable", 503);
    const existing = (await tx`
      SELECT username FROM turn_allocations
      WHERE call_id = ${callId} AND account_id = ${accountId}
        AND expires_at > now() + interval '15 minutes'
      ORDER BY expires_at DESC LIMIT 1 FOR UPDATE`)[0];
    if (existing) return existing.username as string;
    const active = Number((await tx`
      SELECT count(*) AS count FROM turn_allocations
      WHERE account_id = ${accountId} AND expires_at > now()`)[0].count);
    if (active >= 4) throw new CallError("too many active TURN credentials", "turn_quota", 429, {}, 60);
    const expires = Math.floor(Date.now() / 1_000) + credentialTTLSeconds;
    const opaqueAllocationId = randomBytes(16).toString("hex");
    const nextUsername = `${expires}:${opaqueAllocationId}`;
    await tx`
      INSERT INTO turn_allocations (id, call_id, account_id, username, expires_at)
      VALUES (${crypto.randomUUID()}, ${callId}, ${accountId}, ${nextUsername}, to_timestamp(${expires}))`;
    return nextUsername;
  });
  const credential = createHmac("sha1", secret).update(username).digest("base64");
  const ttlSeconds = Math.max(1, Number(username.split(":", 1)[0]) - Math.floor(Date.now() / 1_000));
  return {
    ttlSeconds,
    iceServers: [
      ...(stunUrls.length ? [{ urls: stunUrls }] : []),
      { urls: turnUrls, username, credential },
    ],
  };
}

/**
 * Accepts one privacy-preserving telemetry report per call from a participant device and emits it
 * as a low-cardinality structured log. Only pinned bucket/enumeration values survive validation, so
 * the reporting boundary can never carry keys, SDP, candidates, phone numbers, or raw audio metrics.
 */
export async function recordCallTelemetry(sql: SQL, p: {
  accountId: string; deviceId: string; callId: unknown;
  outcome: unknown; role?: unknown; routeClass?: unknown; privacyMode?: unknown;
  setupBucket?: unknown; recoveryBucket?: unknown; rttBucket?: unknown; lossBucket?: unknown;
  jitterBucket?: unknown; bitrateBucket?: unknown; recoveryCount?: unknown;
  appVersion?: unknown; region?: unknown;
}): Promise<{ recorded: true }> {
  const callId = requireUUID(p.callId, "callId");
  const outcome = pickEnum(p.outcome, TELEMETRY_OUTCOMES, "outcome")!;
  const routeClass = pickEnum(p.routeClass, TELEMETRY_ROUTE_CLASSES, "routeClass", true);
  const privacyMode = pickEnum(p.privacyMode, TELEMETRY_PRIVACY_MODES, "privacyMode", true);
  const setupBucket = pickEnum(p.setupBucket, TELEMETRY_TIME_BUCKETS, "setupBucket", true);
  const recoveryBucket = pickEnum(p.recoveryBucket, TELEMETRY_TIME_BUCKETS, "recoveryBucket", true);
  const rttBucket = pickEnum(p.rttBucket, TELEMETRY_RTT_BUCKETS, "rttBucket", true);
  const lossBucket = pickEnum(p.lossBucket, TELEMETRY_LOSS_BUCKETS, "lossBucket", true);
  const jitterBucket = pickEnum(p.jitterBucket, TELEMETRY_JITTER_BUCKETS, "jitterBucket", true);
  const bitrateBucket = pickEnum(p.bitrateBucket, TELEMETRY_BITRATE_BUCKETS, "bitrateBucket", true);
  const recoveryCount = clampCount(p.recoveryCount, 100);
  const appVersion = p.appVersion == null ? null
    : typeof p.appVersion === "string" && /^[0-9]{1,3}(\.[0-9]{1,4}){0,3}$/.test(p.appVersion) ? p.appVersion
    : (() => { throw new CallError("appVersion is invalid", "invalid_request"); })();
  const region = p.region == null ? null
    : typeof p.region === "string" && /^[a-z0-9-]{1,32}$/.test(p.region) ? p.region
    : (() => { throw new CallError("region is invalid", "invalid_request"); })();

  const telemetry = await sql.begin(async (tx) => {
    await requireActiveDevice(tx, p.accountId, p.deviceId);
    const row = (await tx`SELECT * FROM calls WHERE id = ${callId} FOR SHARE`)[0];
    if (!row) throw new CallError("call not found", "not_found", 404);
    await callAccess(tx, row, p.accountId, p.deviceId);
    const ownsCall = row.caller_account_id === p.accountId && row.caller_device_id === p.deviceId
      || row.callee_account_id === p.accountId && row.accepted_device_id === p.deviceId;
    const wasRingTarget = ownsCall ? true : (await tx`
      SELECT 1 FROM call_ring_targets
      WHERE call_id = ${callId} AND device_id = ${p.deviceId}`
    ).length > 0;
    if (!wasRingTarget) {
      throw new CallError("only a call device may report telemetry", "invalid_device", 403);
    }
    const claimed = await tx`
      INSERT INTO call_telemetry_reports (call_id, device_id)
      VALUES (${callId}, ${p.deviceId})
      ON CONFLICT DO NOTHING RETURNING call_id`;
    return {
      shouldLog: claimed.length > 0,
      role: pickEnum(p.role, new Set(["caller", "callee"]), "role", true)
        ?? (row.caller_account_id === p.accountId ? "caller" : "callee"),
    };
  });

  if (telemetry.shouldLog) {
    console.log(JSON.stringify({
      ts: new Date().toISOString(), event: "call.telemetry",
      role: telemetry.role, outcome, routeClass, privacyMode, setupBucket, recoveryBucket,
      rttBucket, lossBucket, jitterBucket, bitrateBucket, recoveryCount, appVersion, region,
    }));
  }
  return { recorded: true };
}

export async function blockAccount(sql: SQL, blockerAccountId: string, rawBlockedAccountId: unknown): Promise<{
  blocked: true; hints: CallHint[]; syncPushes: Push[];
}> {
  const blockedAccountId = requireUUID(rawBlockedAccountId, "accountId");
  if (blockedAccountId === blockerAccountId) throw new CallError("cannot block yourself", "invalid_request");
  const ended = await sql.begin(async (tx) => {
    await lockAccountMutations(tx, [blockerAccountId, blockedAccountId]);
    const peer = await tx`SELECT 1 FROM accounts WHERE id = ${blockedAccountId} AND status <> 'deleted'`;
    if (!peer.length) throw new CallError("account not found", "not_found", 404);
    await tx`
      INSERT INTO account_blocks (blocker_account_id, blocked_account_id)
      VALUES (${blockerAccountId}, ${blockedAccountId}) ON CONFLICT DO NOTHING`;
    const rows: CallRow[] = await tx`
      SELECT * FROM calls
      WHERE state <> 'ended' AND (
        (caller_account_id = ${blockerAccountId} AND callee_account_id = ${blockedAccountId})
        OR (caller_account_id = ${blockedAccountId} AND callee_account_id = ${blockerAccountId})
      )
      ORDER BY id FOR UPDATE`;
    const terminated: CallRow[] = [];
    for (const row of rows) {
      terminated.push(await finishCallTx(tx, row, "blocked", blockerAccountId, null));
    }
    return terminated;
  });
  const syncPushes = await flushCallHistory(sql, ended);
  return { blocked: true, hints: await hintsForRows(sql, ended), syncPushes };
}

export async function unblockAccount(sql: SQL, blockerAccountId: string, rawBlockedAccountId: unknown): Promise<{
  blocked: false;
}> {
  const blockedAccountId = requireUUID(rawBlockedAccountId, "accountId");
  await sql.begin(async (tx) => {
    await lockAccountMutations(tx, [blockerAccountId, blockedAccountId]);
    await tx`
      DELETE FROM account_blocks
      WHERE blocker_account_id = ${blockerAccountId} AND blocked_account_id = ${blockedAccountId}`;
  });
  return { blocked: false };
}

export async function expireStaleCalls(sql: SQL, accountId?: string, limit = 100): Promise<number> {
  const rows: CallRow[] = await sql.begin(async (tx) => {
    const stale = accountId
      ? await tx`
          SELECT * FROM calls WHERE state <> 'ended' AND expires_at <= now()
            AND (caller_account_id = ${accountId} OR callee_account_id = ${accountId})
          ORDER BY expires_at FOR UPDATE SKIP LOCKED LIMIT ${limit}`
      : await tx`
          SELECT * FROM calls WHERE state <> 'ended' AND expires_at <= now()
          ORDER BY expires_at FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
    const ended: CallRow[] = [];
    for (const row of stale) {
      ended.push(await finishCallTx(tx, row, row.state === "requested" ? "unanswered" : "network_lost", null, null));
    }
    return ended;
  });
  await flushCallHistory(sql, rows);
  return rows.length;
}

export async function cleanupCallData(sql: SQL, limit = 1_000): Promise<{
  expiredCalls: number; history: number; events: number; attempts: number;
  deliveries: number; allocations: number; calls: number;
}> {
  const expiredCalls = await expireStaleCalls(sql, undefined, limit);
  const history = await processCallHistoryOutbox(sql, limit);
  const events = await sql`
    WITH doomed AS (SELECT call_id, event_seq FROM call_events WHERE expires_at <= now()
      ORDER BY expires_at LIMIT ${limit})
    DELETE FROM call_events e USING doomed d
    WHERE e.call_id = d.call_id AND e.event_seq = d.event_seq RETURNING e.call_id`;
  const attempts = await sql`
    WITH doomed AS (SELECT id FROM call_invite_attempts WHERE created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${limit})
    DELETE FROM call_invite_attempts WHERE id IN (SELECT id FROM doomed) RETURNING id`;
  const deliveries = await sql`
    WITH doomed AS (SELECT id FROM voip_push_deliveries
      WHERE status IN ('sent','dead') AND created_at < now() - interval '7 days'
      ORDER BY created_at LIMIT ${limit})
    DELETE FROM voip_push_deliveries WHERE id IN (SELECT id FROM doomed) RETURNING id`;
  const allocations = await sql`
    WITH doomed AS (SELECT id FROM turn_allocations WHERE expires_at <= now()
      ORDER BY expires_at LIMIT ${limit})
    DELETE FROM turn_allocations WHERE id IN (SELECT id FROM doomed) RETURNING id`;
  const calls = await sql`
    WITH doomed AS (
      SELECT c.id FROM calls c
      WHERE c.state = 'ended' AND c.ended_at < now() - interval '30 days'
        AND NOT EXISTS (
          SELECT 1 FROM call_history_outbox o
          WHERE o.call_id = c.id AND o.status <> 'delivered'
        )
      ORDER BY c.ended_at LIMIT ${limit}
    )
    DELETE FROM calls WHERE id IN (SELECT id FROM doomed) RETURNING id`;
  return {
    expiredCalls, history: history.processed, events: events.length, attempts: attempts.length,
    deliveries: deliveries.length, allocations: allocations.length, calls: calls.length,
  };
}

export function startCallCleanupWorker(sql: SQL, intervalMs = 30_000): () => void {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      await cleanupCallData(sql);
    } catch (error) {
      console.error(JSON.stringify({
        ts: new Date().toISOString(), event: "call.cleanup.error",
        errorType: error instanceof Error ? error.name : "UnknownError",
      }));
    } finally {
      running = false;
    }
  };
  void tick();
  const timer = setInterval(() => { void tick(); }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

export function voiceCallsConfigured(pushConfigured = true): boolean {
  const turnUrls = (process.env.TOJ_TURN_URLS ?? "")
    .split(",").map((value) => value.trim()).filter(Boolean);
  const sharedSecret = (process.env.TOJ_TURN_SHARED_SECRET ?? "").trim();
  return process.env.TOJ_VOICE_CALLS_ENABLED === "1"
    && process.env.TOJ_TURN_READY === "1"
    && pushConfigured
    && turnUrls.length > 0
    && sharedSecret.length > 0;
}

export function videoCallsConfigured(voiceReady = voiceCallsConfigured()): boolean {
  return voiceReady
    && process.env.TOJ_VIDEO_CALLS_ENABLED === "1"
    && process.env.TOJ_TURN_VIDEO_READY === "1";
}

/**
 * Stable rollout selection. Internal accounts always win; every other account remains in the
 * same percentage bucket across processes and deploys. Zero is the safe default and rollback.
 */
export function videoCallsEnabledForAccount(
  accountId: string,
  videoReady = videoCallsConfigured(),
): boolean {
  if (!videoReady) return false;
  const normalizedAccountId = accountId.trim().toLowerCase();
  const allowlist = new Set((process.env.TOJ_VIDEO_CALLS_ALLOWLIST ?? "")
    .split(",").map((value) => value.trim().toLowerCase()).filter(Boolean));
  if (allowlist.has(normalizedAccountId)) return true;
  const configuredPercent = Number(process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT ?? "0");
  if (!Number.isFinite(configuredPercent) || configuredPercent <= 0) return false;
  if (configuredPercent >= 100) return true;
  const digest = createHash("sha256").update(`toj-video-rollout-v1|${normalizedAccountId}`).digest();
  const bucket = digest.readUInt32BE(0) / 0x1_0000_0000 * 100;
  return bucket < configuredPercent;
}

/**
 * PostgreSQL NOTIFY is only a wake-up. Durable call_events plus REST catch-up remain authoritative.
 * The listener reconnects forever with bounded backoff; same-process handlers also send hints
 * immediately, so duplicate hints are intentionally harmless.
 */
export function startCallNotificationListener(databaseUrl: string | null,
  onWakeup: (wakeup: CallWakeup) => void | Promise<void>): () => void {
  if (!databaseUrl) return () => {};
  let stopped = false;
  let client: Client | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let attempts = 0;
  const wakeupRetries = new Set<ReturnType<typeof setTimeout>>();

  const schedule = () => {
    if (stopped || retry) return;
    const delay = Math.min(30_000, 500 * 2 ** Math.min(attempts, 6));
    attempts += 1;
    retry = setTimeout(() => { retry = null; void connect(); }, delay);
    retry.unref?.();
  };
  const deliverWakeup = (wakeup: CallWakeup, attempt = 0) => {
    void Promise.resolve()
      .then(() => onWakeup(wakeup))
      .catch(() => {
        if (stopped) return;
        if (attempt >= 2) {
          console.error("call notification wake-up failed after bounded retries");
          return;
        }
        const wakeupRetry = setTimeout(() => {
          wakeupRetries.delete(wakeupRetry);
          deliverWakeup(wakeup, attempt + 1);
        }, 250 * 2 ** attempt);
        wakeupRetry.unref?.();
        wakeupRetries.add(wakeupRetry);
      });
  };
  const connect = async () => {
    if (stopped) return;
    const next = new Client({ connectionString: databaseUrl, application_name: "toj-call-notify" });
    client = next;
    next.on("notification", (notification) => {
      if (notification.channel !== "toj_call_events" || !notification.payload) return;
      try {
        const value = JSON.parse(notification.payload) as CallWakeup;
        if (!UUID_PATTERN.test(value.callId) || !Number.isSafeInteger(value.latestEventSeq)
          || value.latestEventSeq < 0) return;
        deliverWakeup(value);
      } catch { /* an invalid notification is never authoritative */ }
    });
    let handledDisconnect = false;
    const disconnected = () => {
      if (handledDisconnect) return;
      handledDisconnect = true;
      if (client !== next) return;
      client = null;
      schedule();
    };
    next.once("error", disconnected);
    next.once("end", disconnected);
    try {
      await next.connect();
      await next.query("LISTEN toj_call_events");
      attempts = 0;
    } catch {
      try { await next.end(); } catch { /* already closed */ }
      disconnected();
    }
  };
  void connect();
  return () => {
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = null;
    for (const wakeupRetry of wakeupRetries) clearTimeout(wakeupRetry);
    wakeupRetries.clear();
    if (client) void client.end().catch(() => {});
    client = null;
  };
}
