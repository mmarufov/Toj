import type { SQL } from "bun";
import { requireActiveDevice } from "./auth";
import { DialogAccessError, lockDialogForMutation } from "./dialog-access";
import { fanoutDialogEvent } from "./fanout";
import { lockMutationKeys } from "./locks";
import {
  bodyAAD,
  mediaThumbnailAAD,
  reportActionNoteAAD,
  reportEvidenceAAD,
  requestFingerprintIndex,
  type Sealed,
} from "./crypto";
import {
  CryptoUnavailableError, openForScope, preloadEnvelopeKeys, sealForScope,
} from "./envelope-crypto";
import { notifySyncWakeups } from "./sync-wakeup";
import { notifyAccountSecurityEvent } from "./account-security-events";
import {
  flushTerminatedCallHistory,
  terminateCallsForAccountTx,
  type CallRow,
} from "./calls";
import { handoffOwnedGroupsForDeletedAccount } from "./groups";
import { revokePushBindingsForDevice } from "./push";
import {
  requireGroupCallSFUBarrierApplied,
  revokeGroupCallAccountTx,
} from "./group-calls";
import { revokeAccountPresence } from "./presence";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const REPORT_REASONS = new Set([
  "spam", "scam", "harassment", "violence", "sexual_content", "child_safety", "other",
]);
const MAX_DETAILS_CHARACTERS = 500;
const MAX_EVIDENCE_BYTES = 256 * 1024;
const MAX_EVIDENCE_THUMBNAIL_BYTES = 64 * 1024;
const REPORT_HOURLY_LIMIT = 5;
const REPORT_DAILY_LIMIT = 20;

export type AbuseReportReason =
  | "spam" | "scam" | "harassment" | "violence"
  | "sexual_content" | "child_safety" | "other";

export type AbuseReportSubject =
  | { type: "account"; accountId: string }
  | { type: "message"; msgId: number };

export type SubmitAbuseReportInput = {
  clientReportId: unknown;
  dialogId: unknown;
  subject: unknown;
  reason: unknown;
  details?: unknown;
};

export class ReportError extends Error {
  constructor(
    message: string,
    readonly status = 400,
    readonly code = "invalid_report",
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "ReportError";
  }
}

type NormalizedReport = {
  clientReportId: string;
  dialogId: string;
  subject: AbuseReportSubject;
  reason: AbuseReportReason;
  details: string | null;
  canonical: string;
  fingerprint: Buffer;
  fingerprintKeyId: string;
};

type EvidenceMessage = {
  msgId: number;
  senderAccountId: string;
  kind: string;
  text: string;
  state: string;
  editVersion: number;
  serverTs: string;
  media: null | {
    id: string;
    kind: string;
    contentType: string;
    byteSize: number;
    thumbnailBase64?: string;
  };
};

type EvidenceBundle = {
  version: 1;
  capturedAt: string;
  dialogId: string;
  subject: AbuseReportSubject & { accountId?: string };
  reason: AbuseReportReason;
  details: string | null;
  messages: EvidenceMessage[];
  omittedContextMessages: number;
};

const n = (value: unknown) => Number(value as any);
const buf = (value: Uint8Array) => Buffer.from(value);

function normalizeInput(rawInput: unknown): NormalizedReport {
  if (rawInput === null || typeof rawInput !== "object" || Array.isArray(rawInput)) {
    throw new ReportError("invalid report body");
  }
  const input = rawInput as SubmitAbuseReportInput;
  const clientReportId = typeof input.clientReportId === "string"
    ? input.clientReportId.toLowerCase() : "";
  const dialogId = typeof input.dialogId === "string" ? input.dialogId.toLowerCase() : "";
  if (!UUID_PATTERN.test(clientReportId)) throw new ReportError("invalid client report id");
  if (!UUID_PATTERN.test(dialogId)) throw new ReportError("invalid dialog id");

  const value = input.subject as Record<string, unknown> | null;
  let subject: AbuseReportSubject;
  if (
    value?.type === "account"
    && !("msgId" in value)
    && typeof value.accountId === "string"
    && UUID_PATTERN.test(value.accountId)
  ) {
    subject = { type: "account", accountId: value.accountId.toLowerCase() };
  } else if (value?.type === "message" && !("accountId" in value)) {
    if (typeof value.msgId !== "number") throw new ReportError("invalid message id");
    const msgId = value.msgId;
    if (!Number.isSafeInteger(msgId) || msgId <= 0) throw new ReportError("invalid message id");
    subject = { type: "message", msgId };
  } else {
    throw new ReportError("invalid report subject");
  }

  if (typeof input.reason !== "string" || !REPORT_REASONS.has(input.reason)) {
    throw new ReportError("invalid report reason");
  }
  const reason = input.reason as AbuseReportReason;
  if (input.details != null && typeof input.details !== "string") {
    throw new ReportError("invalid report details");
  }
  const details = typeof input.details === "string" ? input.details.trim() : "";
  const detailsCharacters = [...details].length;
  if (detailsCharacters > MAX_DETAILS_CHARACTERS) {
    throw new ReportError(`report details must be at most ${MAX_DETAILS_CHARACTERS} characters`);
  }
  if (reason === "other" && detailsCharacters < 10) {
    throw new ReportError("other reports require at least 10 characters of detail");
  }

  const canonical = JSON.stringify({ clientReportId, dialogId, subject, reason, details: details || null });
  const fingerprint = requestFingerprintIndex("abuse-report", canonical);
  return {
    clientReportId,
    dialogId,
    subject,
    reason,
    details: details || null,
    canonical,
    fingerprint: fingerprint.digest,
    fingerprintKeyId: fingerprint.keyId,
  };
}

function unavailable(): never {
  throw new ReportError("report subject not found", 404, "report_subject_not_found");
}

async function requireReportDialogAccess(sql: SQL, accountId: string, dialogId: string): Promise<void> {
  try {
    // The dialog row is the message/membership linearization point. Holding it through evidence
    // capture prevents a removal from committing between authorization and the snapshot query.
    await lockDialogForMutation(sql, accountId, dialogId);
  } catch (error) {
    if (error instanceof DialogAccessError) unavailable();
    throw error;
  }
}

async function evidenceMessage(sql: SQL, row: any, includeThumbnail: boolean): Promise<EvidenceMessage> {
  const dialogId = String(row.dialog_id);
  const msgId = n(row.msg_id);
  const senderAccountId = String(row.sender_account_id);
  let text = "";
  if (row.state === "visible") {
    const plaintext = await openForScope(
      sql,
      { kind: "account", accountId: senderAccountId },
      { keyId: row.body_key_id, nonce: buf(row.body_nonce), ciphertext: buf(row.body_ciphertext) },
      bodyAAD(dialogId, msgId, senderAccountId),
    );
    try {
      text = plaintext.toString("utf8");
    } finally {
      plaintext.fill(0);
    }
  }
  const media = row.media_id == null ? null : {
    id: String(row.media_id),
    kind: String(row.media_kind),
    contentType: String(row.media_content_type),
    byteSize: n(row.media_byte_size),
  } as EvidenceMessage["media"];
  if (
    media && includeThumbnail && row.thumbnail_ciphertext != null
    && buf(row.thumbnail_ciphertext).length <= MAX_EVIDENCE_THUMBNAIL_BYTES
  ) {
    try {
      const thumbnail = await openForScope(sql, {
        kind: "account", accountId: String(row.media_owner_account_id),
      }, {
        keyId: row.thumbnail_key_id,
        nonce: buf(row.thumbnail_nonce),
        ciphertext: buf(row.thumbnail_ciphertext),
      }, mediaThumbnailAAD(media.id));
      try {
        if (thumbnail.length <= MAX_EVIDENCE_THUMBNAIL_BYTES) {
          media.thumbnailBase64 = thumbnail.toString("base64");
        }
      } finally {
        thumbnail.fill(0);
      }
    } catch (error) {
      // A retryable provider outage must abort the transaction. A successful idempotent report
      // may never be committed with silently incomplete evidence.
      if (error instanceof CryptoUnavailableError) throw error;
      // A corrupt or concurrently cleaned thumbnail must not prevent a text safety report.
    }
  }
  return {
    msgId,
    senderAccountId,
    kind: String(row.kind),
    text,
    state: String(row.state),
    editVersion: n(row.edit_version),
    serverTs: new Date(row.server_ts).toISOString(),
    media,
  };
}

function serializeBoundedEvidence(bundle: EvidenceBundle, subjectMsgId: number | null): Buffer {
  const encode = () => Buffer.from(JSON.stringify(bundle), "utf8");
  let bytes = encode();
  if (bytes.length <= MAX_EVIDENCE_BYTES) return bytes;

  for (const message of bundle.messages) {
    if (message.media?.thumbnailBase64) delete message.media.thumbnailBase64;
  }
  bytes.fill(0);
  bytes = encode();
  while (bytes.length > MAX_EVIDENCE_BYTES && bundle.messages.length > 1) {
    const removable = bundle.messages.findIndex((message) => message.msgId !== subjectMsgId);
    if (removable < 0) break;
    bundle.messages.splice(removable, 1);
    bundle.omittedContextMessages += 1;
    bytes.fill(0);
    bytes = encode();
  }
  if (bytes.length > MAX_EVIDENCE_BYTES) {
    bytes.fill(0);
    throw new ReportError("report evidence is too large", 413, "report_evidence_too_large");
  }
  return bytes;
}

async function captureEvidence(
  sql: SQL,
  reporterAccountId: string,
  input: NormalizedReport,
): Promise<{ reportedAccountId: string; plaintext: Buffer }> {
  await requireReportDialogAccess(sql, reporterAccountId, input.dialogId);
  let reportedAccountId: string;
  let rows: any[];
  let subjectMsgId: number | null = null;

  if (input.subject.type === "account") {
    if (input.subject.accountId === reporterAccountId) unavailable();
    const member = (await sql`
      SELECT account_id FROM dialog_members
      WHERE dialog_id = ${input.dialogId} AND account_id = ${input.subject.accountId}
        AND left_at IS NULL`)[0];
    if (!member) unavailable();
    reportedAccountId = String(member.account_id);
    rows = await sql`
      SELECT m.dialog_id, m.msg_id, m.sender_account_id, m.kind, m.body_key_id,
             m.body_nonce, m.body_ciphertext, m.state, m.edit_version, m.server_ts,
             media.id AS media_id, media.owner_account_id AS media_owner_account_id,
             media.kind AS media_kind,
             media.content_type AS media_content_type, media.byte_size AS media_byte_size,
             media.thumbnail_key_id, media.thumbnail_nonce, media.thumbnail_ciphertext
      FROM messages m
      LEFT JOIN media_objects media ON media.id = m.media_id AND media.status = 'ready'
      WHERE m.dialog_id = ${input.dialogId}
        AND m.sender_account_id = ${reportedAccountId}
        AND m.state = 'visible' AND m.kind <> 'service'
      ORDER BY m.msg_id DESC LIMIT 10
      FOR SHARE OF m`;
    rows.reverse();
  } else {
    subjectMsgId = input.subject.msgId;
    const subject = (await sql`
      SELECT sender_account_id, kind, state FROM messages
      WHERE dialog_id = ${input.dialogId} AND msg_id = ${subjectMsgId}
      FOR SHARE`)[0];
    if (!subject || subject.state !== "visible" || subject.kind === "service"
      || subject.sender_account_id === reporterAccountId) unavailable();
    reportedAccountId = String(subject.sender_account_id);
    rows = await sql`
      SELECT m.dialog_id, m.msg_id, m.sender_account_id, m.kind, m.body_key_id,
             m.body_nonce, m.body_ciphertext, m.state, m.edit_version, m.server_ts,
             media.id AS media_id, media.owner_account_id AS media_owner_account_id,
             media.kind AS media_kind,
             media.content_type AS media_content_type, media.byte_size AS media_byte_size,
             media.thumbnail_key_id, media.thumbnail_nonce, media.thumbnail_ciphertext
      FROM messages m
      LEFT JOIN media_objects media ON media.id = m.media_id AND media.status = 'ready'
      WHERE m.dialog_id = ${input.dialogId} AND m.msg_id <= ${subjectMsgId}
        AND m.state = 'visible' AND m.kind <> 'service'
      ORDER BY m.msg_id DESC LIMIT 6
      FOR SHARE OF m`;
    rows.reverse();
  }

  await preloadEnvelopeKeys(sql, rows.flatMap((row) => [
    row.body_key_id,
    row.thumbnail_key_id,
  ]).filter(Boolean).map(String));
  const bundle: EvidenceBundle = {
    version: 1,
    capturedAt: new Date().toISOString(),
    dialogId: input.dialogId,
    subject: input.subject.type === "account"
      ? input.subject
      : { ...input.subject, accountId: reportedAccountId },
    reason: input.reason,
    details: input.details,
    messages: await Promise.all(rows.map((row) =>
      evidenceMessage(sql, row, n(row.msg_id) === subjectMsgId)
    )),
    omittedContextMessages: 0,
  };
  return { reportedAccountId, plaintext: serializeBoundedEvidence(bundle, subjectMsgId) };
}

export function abuseReportsConfigured(): boolean {
  return process.env.TOJ_ABUSE_REPORTS_ENABLED === "1"
    && process.env.TOJ_ABUSE_REPORTS_OPERATOR_READY === "1"
    && Boolean(process.env.TOJ_MODERATION_OPERATOR_ID?.trim())
    && process.env.TOJ_ABUSE_REPORTS_ALERTING_READY === "1"
    && Boolean(process.env.TOJ_ABUSE_REPORTS_ESCALATION_CONTACT?.trim());
}

export async function abuseReportSchemaReadiness(sql: SQL): Promise<{ ready: boolean; missing: string[] }> {
  const required: Record<string, string[]> = {
    abuse_reports: [
      "id", "reporter_account_id", "client_report_id", "request_fingerprint",
      "fingerprint_key_id", "dialog_id", "subject_type", "reported_account_id", "msg_id",
      "reason", "priority", "status", "claimed_by", "claimed_at", "resolution",
      "evidence_key_id", "evidence_nonce", "evidence_ciphertext", "evidence_plain_size",
      "created_at", "resolved_at", "evidence_expires_at", "audit_expires_at",
    ],
    abuse_report_actions: [
      "id", "report_id", "actor_kind", "actor_id", "action",
      "note_key_id", "note_nonce", "note_ciphertext", "created_at",
    ],
    abuse_report_submission_budgets: ["id", "reporter_account_id", "accepted_at"],
    content_access_audit: [
      "id", "actor_kind", "actor_id", "account_id", "dialog_id", "msg_id",
      "reason", "request_id", "created_at",
    ],
  };
  const rows = await sql`
    SELECT table_name, column_name, is_nullable FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = ANY(${sql.array(Object.keys(required), "text")}::text[])`;
  const present = new Map(rows.map((row: any) => [
    `${row.table_name}.${row.column_name}`, String(row.is_nullable),
  ]));
  const missing = Object.entries(required).flatMap(([table, columns]) =>
    columns.filter((column) => !present.has(`${table}.${column}`)).map((column) => `${table}.${column}`)
  );
  const requiredNotNull: Record<string, string[]> = {
    abuse_reports: [
      "id", "reporter_account_id", "client_report_id", "request_fingerprint",
      "fingerprint_key_id", "dialog_id", "subject_type", "reported_account_id", "reason",
      "priority", "status", "created_at",
    ],
    abuse_report_actions: ["id", "report_id", "actor_kind", "action", "created_at"],
    abuse_report_submission_budgets: ["id", "reporter_account_id", "accepted_at"],
    content_access_audit: ["id", "actor_kind", "reason", "created_at"],
  };
  for (const [table, columns] of Object.entries(requiredNotNull)) {
    for (const column of columns) {
      if (present.get(`${table}.${column}`) === "YES") {
        missing.push(`${table}.${column}.not_null`);
      }
    }
  }
  const requiredIndexes = [
    "abuse_reports_idempotency_idx", "abuse_reports_open_priority_idx",
    "abuse_reports_open_queue_idx", "abuse_reports_target_history_idx",
    "abuse_reports_evidence_retention_idx", "abuse_reports_audit_retention_idx",
    "abuse_report_submission_budgets_account_idx", "abuse_report_budgets_retention_idx",
    "abuse_report_actions_report_idx", "messages_report_evidence_idx",
    "content_access_audit_abuse_retention_idx",
  ];
  const indexes = await sql`
    SELECT class.relname AS name, index.indisvalid, index.indisready
    FROM pg_index index
    JOIN pg_class class ON class.oid = index.indexrelid
    JOIN pg_namespace namespace ON namespace.oid = class.relnamespace
    WHERE namespace.nspname = current_schema()
      AND class.relname = ANY(${sql.array(requiredIndexes, "text")}::text[])`;
  const readyIndexes = new Set(indexes.filter((row: any) => row.indisvalid && row.indisready)
    .map((row: any) => String(row.name)));
  for (const index of requiredIndexes) {
    if (!readyIndexes.has(index)) missing.push(index);
  }
  const triggers = await sql`
    SELECT trigger.tgname, function.proname, trigger.tgenabled
    FROM pg_trigger trigger
    JOIN pg_proc function ON function.oid = trigger.tgfoid
    WHERE trigger.tgrelid IN (
      to_regclass('abuse_report_actions'), to_regclass('content_access_audit')
    ) AND NOT trigger.tgisinternal`;
  const triggerFunctions = new Map(triggers
    .filter((row: any) => row.tgenabled === "O")
    .map((row: any) => [String(row.tgname), String(row.proname)]));
  if (triggerFunctions.get("abuse_report_actions_append_only")
    !== "toj_abuse_report_actions_append_only_v1") {
    missing.push("abuse_report_actions.append_only_trigger");
  }
  if (triggerFunctions.get("content_access_audit_append_only")
    !== "toj_content_access_audit_append_only_v1") {
    missing.push("content_access_audit.append_only_trigger");
  }
  const cleanupFunction = (await sql`
    SELECT function.prosecdef, function.proconfig
    FROM pg_proc function
    JOIN pg_namespace namespace ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = current_schema()
      AND function.proname = 'toj_cleanup_abuse_reports_v1'
      AND function.pronargs = 1`)[0];
  const cleanupSettings = (cleanupFunction?.proconfig ?? []).map(String);
  if (!cleanupFunction?.prosecdef
    || !cleanupSettings.some((value: string) => value === "search_path=pg_catalog, public")) {
    missing.push("abuse_reports.security_definer_cleanup");
  }
  // A new binary can start before the additive moderation migration reaches this database.
  // Do not let production-only privilege introspection turn an intentional not-ready state into
  // a 500 by casting relations/functions that are not installed yet.
  if (process.env.NODE_ENV === "production" && missing.length === 0) {
    const role = (await sql`
      SELECT current_user AS runtime_role,
        pg_get_userbyid(action_table.relowner) AS action_owner,
        pg_get_userbyid(access_table.relowner) AS access_owner,
        has_function_privilege(
          current_user, 'public.toj_cleanup_abuse_reports_v1(integer)', 'EXECUTE'
        ) AS cleanup_execute,
        has_table_privilege(current_user, 'abuse_reports', 'SELECT') AS report_select,
        has_table_privilege(current_user, 'abuse_reports', 'INSERT') AS report_insert,
        has_table_privilege(current_user, 'abuse_reports', 'UPDATE') AS report_update,
        has_table_privilege(current_user, 'abuse_reports', 'DELETE') AS report_delete,
        has_table_privilege(current_user, 'abuse_reports', 'TRUNCATE') AS report_truncate,
        has_table_privilege(current_user, 'abuse_report_submission_budgets', 'SELECT')
          AS budget_select,
        has_table_privilege(current_user, 'abuse_report_submission_budgets', 'INSERT')
          AS budget_insert,
        has_table_privilege(current_user, 'abuse_report_submission_budgets', 'UPDATE')
          AS budget_update,
        has_table_privilege(current_user, 'abuse_report_submission_budgets', 'DELETE')
          AS budget_delete,
        has_table_privilege(current_user, 'abuse_report_submission_budgets', 'TRUNCATE')
          AS budget_truncate,
        has_table_privilege(current_user, 'abuse_report_actions', 'SELECT') AS action_select,
        has_table_privilege(current_user, 'abuse_report_actions', 'INSERT') AS action_insert,
        has_table_privilege(current_user, 'abuse_report_actions', 'UPDATE') AS action_update,
        has_table_privilege(current_user, 'abuse_report_actions', 'DELETE') AS action_delete,
        has_table_privilege(current_user, 'abuse_report_actions', 'TRUNCATE') AS action_truncate,
        has_table_privilege(current_user, 'content_access_audit', 'INSERT') AS access_insert,
        has_table_privilege(current_user, 'content_access_audit', 'UPDATE') AS access_update,
        has_table_privilege(current_user, 'content_access_audit', 'DELETE') AS access_delete,
        has_table_privilege(current_user, 'content_access_audit', 'TRUNCATE') AS access_truncate
      FROM pg_class action_table, pg_class access_table
      WHERE action_table.oid = 'abuse_report_actions'::regclass
        AND access_table.oid = 'content_access_audit'::regclass`)[0];
    if (!role || role.runtime_role === role.action_owner || role.runtime_role === role.access_owner
      || !role.cleanup_execute
      || !role.report_select || !role.report_insert || !role.report_update
      || role.report_delete || role.report_truncate
      || !role.budget_select || !role.budget_insert
      || role.budget_update || role.budget_delete || role.budget_truncate
      || !role.action_select || !role.action_insert
      || role.action_update || role.action_delete || role.action_truncate
      || !role.access_insert || role.access_update || role.access_delete || role.access_truncate) {
      missing.push("moderation.database_role_separation");
    }
  }
  return { ready: missing.length === 0, missing };
}

export async function submitAbuseReport(
  sql: SQL,
  reporterAccountId: string,
  reporterDeviceId: string,
  rawInput: unknown,
): Promise<{ reportId: string; status: "received"; duplicate: boolean }> {
  const input = normalizeInput(rawInput);
  return await sql.begin(async (tx) => {
    await requireActiveDevice(tx, reporterAccountId, reporterDeviceId);
    await lockMutationKeys(tx, [`abuse-report-submit:${reporterAccountId}`]);

    const existing = (await tx`
      SELECT id, request_fingerprint, fingerprint_key_id FROM abuse_reports
      WHERE reporter_account_id = ${reporterAccountId}
        AND client_report_id = ${input.clientReportId}
      FOR UPDATE`)[0];
    if (existing) {
      const expected = requestFingerprintIndex(
        "abuse-report",
        input.canonical,
        existing.fingerprint_key_id ?? "legacy-v1",
      ).digest;
      if (!Buffer.from(existing.request_fingerprint).equals(expected)) {
        throw new ReportError("client report id already used", 409, "report_idempotency_conflict");
      }
      if (String(existing.fingerprint_key_id ?? "legacy-v1") !== input.fingerprintKeyId) {
        await tx`UPDATE abuse_reports SET request_fingerprint = ${input.fingerprint},
          fingerprint_key_id = ${input.fingerprintKeyId}
          WHERE id = ${existing.id}`;
      }
      return { reportId: String(existing.id), status: "received" as const, duplicate: true };
    }

    const counts = (await tx`
      SELECT
        count(*) FILTER (WHERE accepted_at > now() - interval '1 hour') AS hourly,
        count(*) FILTER (WHERE accepted_at > now() - interval '24 hours') AS daily
      FROM abuse_report_submission_budgets
      WHERE reporter_account_id = ${reporterAccountId}`)[0];
    if (n(counts.hourly) >= REPORT_HOURLY_LIMIT) {
      throw new ReportError("report limit reached; try again later", 429, "report_rate_limited", 3600);
    }
    if (n(counts.daily) >= REPORT_DAILY_LIMIT) {
      throw new ReportError("daily report limit reached; try again later", 429, "report_rate_limited", 86400);
    }

    const { reportedAccountId, plaintext } = await captureEvidence(tx, reporterAccountId, input);
    const reportId = crypto.randomUUID();
    try {
      const encrypted = await sealForScope(
        tx,
        { kind: "service", serviceName: "moderation-evidence" },
        plaintext,
        reportEvidenceAAD(reportId, reporterAccountId),
      );
      const priority = ["child_safety", "violence"].includes(input.reason) ? "urgent" : "standard";
      await tx`
        INSERT INTO abuse_report_submission_budgets (reporter_account_id)
        VALUES (${reporterAccountId})`;
      await tx`
        INSERT INTO abuse_reports (
          id, reporter_account_id, client_report_id, request_fingerprint, fingerprint_key_id, dialog_id,
          subject_type, reported_account_id, msg_id, reason, priority, status,
          evidence_key_id, evidence_nonce, evidence_ciphertext, evidence_plain_size
        ) VALUES (
          ${reportId}, ${reporterAccountId}, ${input.clientReportId}, ${input.fingerprint},
          ${input.fingerprintKeyId}, ${input.dialogId},
          ${input.subject.type}, ${reportedAccountId},
          ${input.subject.type === "message" ? input.subject.msgId : null},
          ${input.reason}, ${priority}, 'open',
          ${encrypted.keyId}, ${encrypted.nonce}, ${encrypted.ciphertext}, ${plaintext.length}
        )`;
      await tx`
        INSERT INTO abuse_report_actions (report_id, actor_kind, actor_id, action)
        VALUES (${reportId}, 'system', ${reporterAccountId}, 'created')`;
      return { reportId, status: "received" as const, duplicate: false };
    } finally {
      plaintext.fill(0);
    }
  });
}

async function decryptEvidence(sql: SQL, row: any): Promise<EvidenceBundle | null> {
  if (!row.evidence_ciphertext || !row.evidence_nonce || !row.evidence_key_id) return null;
  const plaintext = await openForScope(
    sql,
    { kind: "service", serviceName: "moderation-evidence" },
    {
      keyId: row.evidence_key_id,
      nonce: buf(row.evidence_nonce),
      ciphertext: buf(row.evidence_ciphertext),
    }, reportEvidenceAAD(String(row.id), String(row.reporter_account_id)),
  );
  try {
    return JSON.parse(plaintext.toString("utf8"));
  } finally {
    plaintext.fill(0);
  }
}

function abuseReportSummary(row: any): any {
  return {
    id: String(row.id), reporterAccountId: String(row.reporter_account_id),
    reportedAccountId: String(row.reported_account_id), dialogId: String(row.dialog_id),
    subjectType: row.subject_type, msgId: row.msg_id == null ? null : n(row.msg_id),
    reason: row.reason, priority: row.priority, status: row.status,
    claimedBy: row.claimed_by ?? null,
    claimedAt: row.claimed_at ? new Date(row.claimed_at).toISOString() : null,
    resolution: row.resolution ?? null,
    createdAt: new Date(row.created_at).toISOString(),
    resolvedAt: row.resolved_at ? new Date(row.resolved_at).toISOString() : null,
  };
}

function moderationOperatorId(value: string): string {
  const operatorId = value.trim();
  if (!operatorId || operatorId.length > 200 || /[\r\n\0]/.test(operatorId)) {
    throw new ReportError("operator id required");
  }
  return operatorId;
}

async function recordModerationRead(
  sql: SQL,
  operatorId: string,
  operation: "list" | "view" | "view_evidence",
  row?: any,
): Promise<void> {
  await sql`
    INSERT INTO content_access_audit (
      actor_kind, actor_id, account_id, dialog_id, msg_id, reason, request_id
    ) VALUES (
      'moderation', ${operatorId}, ${row?.reported_account_id ?? null},
      ${row?.dialog_id ?? null}, ${row?.msg_id ?? null},
      ${`abuse_report.${operation}`}, ${row?.id ?? null}
    )`;
}

export async function listAbuseReports(
  sql: SQL, operatorIdInput: string, limit = 50,
): Promise<any[]> {
  const operatorId = moderationOperatorId(operatorIdInput);
  const bounded = Math.max(1, Math.min(200, limit));
  return await sql.begin(async (tx) => {
    await recordModerationRead(tx, operatorId, "list");
    return (await tx`
      SELECT id, reporter_account_id, reported_account_id, dialog_id, subject_type, msg_id,
             reason, priority, status, claimed_by, claimed_at, resolution, created_at, resolved_at
      FROM abuse_reports
      WHERE status <> 'resolved'
      ORDER BY (priority = 'urgent') DESC, created_at, id
      LIMIT ${bounded}`).map(abuseReportSummary);
  });
}

async function decryptActionNote(sql: SQL, row: any): Promise<string | null> {
  if (!row.note_key_id || !row.note_nonce || !row.note_ciphertext) return null;
  const plaintext = await openForScope(
    sql,
    { kind: "service", serviceName: "moderation-evidence" },
    {
      keyId: String(row.note_key_id),
      nonce: buf(row.note_nonce),
      ciphertext: buf(row.note_ciphertext),
    },
    reportActionNoteAAD(String(row.report_id), String(row.action), String(row.actor_id ?? "system")),
  );
  try {
    return plaintext.toString("utf8");
  } finally {
    plaintext.fill(0);
  }
}

export async function viewAbuseReport(
  sql: SQL, reportId: string, includeEvidence: boolean, operatorIdInput: string,
): Promise<any> {
  if (!UUID_PATTERN.test(reportId)) throw new ReportError("invalid report id");
  const operatorId = moderationOperatorId(operatorIdInput);
  return await sql.begin(async (tx) => {
    const row = (await tx`SELECT * FROM abuse_reports WHERE id = ${reportId}`)[0];
    if (!row) throw new ReportError("report not found", 404, "report_not_found");
    await recordModerationRead(tx, operatorId, includeEvidence ? "view_evidence" : "view", row);
    const actions = await tx`
      SELECT id, report_id, actor_kind, actor_id, action,
             note_key_id, note_nonce, note_ciphertext, created_at
      FROM abuse_report_actions WHERE report_id = ${reportId} ORDER BY created_at, id`;
    if (includeEvidence) {
      await preloadEnvelopeKeys(tx, actions.map((action: any) => action.note_key_id)
        .filter(Boolean).map(String));
    }
    return {
      ...abuseReportSummary(row),
      evidence: includeEvidence ? await decryptEvidence(tx, row) : undefined,
      actions: await Promise.all(actions.map(async (action: any) => ({
        actorKind: action.actor_kind, actorId: action.actor_id, action: action.action,
        createdAt: new Date(action.created_at).toISOString(),
        ...(includeEvidence ? { note: await decryptActionNote(tx, action) } : {}),
      }))),
    };
  });
}

async function sealedNote(
  sql: SQL, reportId: string, action: string, operatorId: string, note: string | null,
): Promise<Sealed | null> {
  if (!note) return null;
  if (note.length > 4_000) throw new ReportError("operator note is too long");
  return await sealForScope(
    sql,
    { kind: "service", serviceName: "moderation-evidence" },
    note,
    reportActionNoteAAD(reportId, action, operatorId),
  );
}

export async function claimAbuseReport(
  sql: SQL, reportId: string, operatorIdInput: string, note: string | null,
): Promise<{ claimed: true; duplicate: boolean }> {
  if (!UUID_PATTERN.test(reportId)) throw new ReportError("invalid report id");
  const operatorId = moderationOperatorId(operatorIdInput);
  return await sql.begin(async (tx) => {
    const row = (await tx`SELECT status, claimed_by FROM abuse_reports WHERE id = ${reportId} FOR UPDATE`)[0];
    if (!row) throw new ReportError("report not found", 404, "report_not_found");
    if (row.status === "resolved") throw new ReportError("report is already resolved", 409, "report_resolved");
    if (row.status === "in_review") {
      if (row.claimed_by === operatorId) return { claimed: true as const, duplicate: true };
      throw new ReportError("report is already claimed", 409, "report_claimed");
    }
    const encrypted = await sealedNote(tx, reportId, "claimed", operatorId, note);
    await tx`
      UPDATE abuse_reports SET status = 'in_review', claimed_by = ${operatorId}, claimed_at = now()
      WHERE id = ${reportId}`;
    await tx`
      INSERT INTO abuse_report_actions (
        report_id, actor_kind, actor_id, action, note_key_id, note_nonce, note_ciphertext
      ) VALUES (
        ${reportId}, 'moderation', ${operatorId}, 'claimed',
        ${encrypted?.keyId ?? null}, ${encrypted?.nonce ?? null}, ${encrypted?.ciphertext ?? null}
      )`;
    return { claimed: true as const, duplicate: false };
  });
}

async function moderateDeleteMessage(sql: SQL, row: any): Promise<void> {
  if (row.msg_id == null) throw new ReportError("report has no message", 409, "report_has_no_message");
  const message = (await sql`
    SELECT sender_account_id, state, media_id FROM messages
    WHERE dialog_id = ${row.dialog_id} AND msg_id = ${row.msg_id}
    FOR UPDATE`)[0];
  if (!message || message.state !== "visible") return;
  const deleted = await sealForScope(
    sql,
    { kind: "account", accountId: String(message.sender_account_id) },
    "",
    bodyAAD(String(row.dialog_id), n(row.msg_id), String(message.sender_account_id)),
  );
  await sql`
    UPDATE messages SET body_key_id = ${deleted.keyId}, body_nonce = ${deleted.nonce},
      body_ciphertext = ${deleted.ciphertext}, media_id = NULL,
      state = 'deleted_for_all', deleted_at = now()
    WHERE dialog_id = ${row.dialog_id} AND msg_id = ${row.msg_id}`;
  await sql`DELETE FROM link_preview_waiters
    WHERE dialog_id = ${row.dialog_id} AND msg_id = ${row.msg_id}`;
  await sql`DELETE FROM message_link_previews
    WHERE dialog_id = ${row.dialog_id} AND msg_id = ${row.msg_id}`;
  if (message.media_id) {
    await sql`
      DELETE FROM media_objects media WHERE media.id = ${message.media_id}
        AND NOT EXISTS (
          SELECT 1 FROM messages live WHERE live.media_id = media.id AND live.state = 'visible'
        )`;
  }
  const pushes = await fanoutDialogEvent(sql, {
    dialogId: String(row.dialog_id), type: "message.deleted", msgId: n(row.msg_id),
    actorAccountId: String(message.sender_account_id), sourceDeviceId: null,
    alertRecipients: false,
  });
  await notifySyncWakeups(sql, pushes);
}

async function banReportedAccount(sql: SQL, accountId: string): Promise<{
  endedCalls: CallRow[]; affectedGroupCallIds: string[];
}> {
  await sql`UPDATE accounts SET status = 'banned', updated_at = now() WHERE id = ${accountId}`;
  // Keep the account -> presence lock order used by account deletion, then publish the terminal
  // state while this transaction can still identify every authorized direct-chat recipient.
  // PostgreSQL defers NOTIFY delivery until commit, so peers never observe a ban that rolls back.
  await revokeAccountPresence(sql, accountId);
  const endedCalls = await terminateCallsForAccountTx(sql, accountId, "account_banned");
  const affectedGroupCallIds = await revokeGroupCallAccountTx(sql, accountId);
  await handoffOwnedGroupsForDeletedAccount(sql, accountId);
  const revokedDevices = await sql`
    UPDATE devices SET revoked_at = COALESCE(revoked_at, now()),
      auth_token_hash = digest(id::text || gen_random_uuid()::text, 'sha256'),
      auth_token_key_id = 'random-deleted',
      push_token_hash = NULL, push_token_hash_key_id = NULL,
      push_token_ciphertext = NULL, push_token_nonce = NULL,
      push_token_key_id = NULL, push_environment = NULL,
      voip_push_token_hash = NULL, voip_push_token_hash_key_id = NULL,
      voip_push_token_ciphertext = NULL, voip_push_token_nonce = NULL,
      voip_push_token_key_id = NULL, voip_push_environment = NULL
    WHERE account_id = ${accountId}
    RETURNING id`;
  for (const device of revokedDevices) {
    await revokePushBindingsForDevice(sql, String(device.id));
  }
  await sql`
    UPDATE push_deliveries SET status = 'dead', last_error = 'account banned', claimed_at = NULL
    WHERE account_id = ${accountId} AND status IN ('pending','sending')`;
  await sql`
    UPDATE voip_push_deliveries SET status = 'dead', last_error = 'account banned', claimed_at = NULL
    WHERE device_id IN (SELECT id FROM devices WHERE account_id = ${accountId})
      AND status IN ('pending','sending')`;
  await notifyAccountSecurityEvent(sql, { accountId, reason: "banned" });
  return { endedCalls, affectedGroupCallIds };
}

export type ModerationResolution = "resolved" | "dismissed" | "content_removed" | "account_banned";

export async function resolveAbuseReport(
  sql: SQL,
  reportId: string,
  operatorIdInput: string,
  resolution: ModerationResolution,
  note: string | null,
): Promise<{ resolved: true; duplicate: boolean }> {
  if (!UUID_PATTERN.test(reportId)) throw new ReportError("invalid report id");
  const operatorId = moderationOperatorId(operatorIdInput);
  if (!["resolved", "dismissed", "content_removed", "account_banned"].includes(resolution)) {
    throw new ReportError("invalid resolution");
  }
  let banCleanup: { endedCalls: CallRow[]; affectedGroupCallIds: string[] } | null = null;
  const result = await sql.begin(async (tx) => {
    const row = (await tx`SELECT * FROM abuse_reports WHERE id = ${reportId} FOR UPDATE`)[0];
    if (!row) throw new ReportError("report not found", 404, "report_not_found");
    if (row.status === "resolved") {
      if (row.resolution === resolution) return { resolved: true as const, duplicate: true };
      throw new ReportError("report has a different resolution", 409, "report_resolved");
    }
    if (row.claimed_by != null && row.claimed_by !== operatorId) {
      throw new ReportError("report is claimed by another operator", 409, "report_claimed");
    }
    if (resolution === "content_removed") await moderateDeleteMessage(tx, row);
    if (resolution === "account_banned") {
      banCleanup = await banReportedAccount(tx, String(row.reported_account_id));
    }
    const encrypted = await sealedNote(tx, reportId, resolution, operatorId, note);
    await tx`
      UPDATE abuse_reports SET status = 'resolved', resolution = ${resolution},
        claimed_by = COALESCE(claimed_by, ${operatorId}),
        claimed_at = COALESCE(claimed_at, now()), resolved_at = now(),
        evidence_expires_at = now() + interval '90 days',
        audit_expires_at = now() + interval '365 days'
      WHERE id = ${reportId}`;
    await tx`
      INSERT INTO abuse_report_actions (
        report_id, actor_kind, actor_id, action, note_key_id, note_nonce, note_ciphertext
      ) VALUES (
        ${reportId}, 'moderation', ${operatorId}, ${resolution},
        ${encrypted?.keyId ?? null}, ${encrypted?.nonce ?? null}, ${encrypted?.ciphertext ?? null}
      )`;
    return { resolved: true as const, duplicate: false };
  });
  if (banCleanup) {
    if (banCleanup.affectedGroupCallIds.length) {
      await requireGroupCallSFUBarrierApplied(sql, banCleanup.affectedGroupCallIds);
    }
    await flushTerminatedCallHistory(sql, banCleanup.endedCalls);
  }
  return result;
}

export async function escalateAbuseReport(
  sql: SQL, reportId: string, operatorIdInput: string, note: string | null,
): Promise<{ escalated: true }> {
  if (!UUID_PATTERN.test(reportId)) throw new ReportError("invalid report id");
  const operatorId = moderationOperatorId(operatorIdInput);
  return await sql.begin(async (tx) => {
    const row = (await tx`SELECT status FROM abuse_reports WHERE id = ${reportId} FOR UPDATE`)[0];
    if (!row) throw new ReportError("report not found", 404, "report_not_found");
    if (row.status === "resolved") throw new ReportError("report is already resolved", 409, "report_resolved");
    const encrypted = await sealedNote(tx, reportId, "escalated", operatorId, note);
    await tx`
      UPDATE abuse_reports SET status = 'in_review', priority = 'urgent',
        claimed_by = COALESCE(claimed_by, ${operatorId}),
        claimed_at = COALESCE(claimed_at, now()) WHERE id = ${reportId}`;
    await tx`
      INSERT INTO abuse_report_actions (
        report_id, actor_kind, actor_id, action, note_key_id, note_nonce, note_ciphertext
      ) VALUES (
        ${reportId}, 'moderation', ${operatorId}, 'escalated',
        ${encrypted?.keyId ?? null}, ${encrypted?.nonce ?? null}, ${encrypted?.ciphertext ?? null}
      )`;
    return { escalated: true as const };
  });
}

export async function cleanupAbuseReports(sql: SQL, batchSize: number): Promise<{
  evidence: number; reports: number; budgets: number; accessAudits: number;
}> {
  if (!(await abuseReportSchemaReadiness(sql)).ready) {
    return { evidence: 0, reports: 0, budgets: 0, accessAudits: 0 };
  }
  const bounded = Math.max(1, Math.min(10_000, batchSize));
  const row = (await sql`
    SELECT evidence, reports, budgets, access_audits
    FROM public.toj_cleanup_abuse_reports_v1(${bounded})`)[0];
  return {
    evidence: n(row.evidence),
    reports: n(row.reports),
    budgets: n(row.budgets),
    accessAudits: n(row.access_audits),
  };
}

export async function abuseReportMetrics(sql: SQL): Promise<string> {
  const schema = await abuseReportSchemaReadiness(sql);
  if (!schema.ready) return "toj_abuse_report_schema_available 0\n";
  const row = (await sql`
    SELECT count(*) AS submitted,
      count(*) FILTER (WHERE status = 'resolved') AS resolved,
      count(*) FILTER (WHERE status <> 'resolved') AS open,
      COALESCE(EXTRACT(EPOCH FROM now() - min(created_at)
        FILTER (WHERE status <> 'resolved' AND priority = 'urgent')), 0) AS oldest_urgent,
      COALESCE(EXTRACT(EPOCH FROM now() - min(created_at)
        FILTER (WHERE status <> 'resolved' AND priority = 'standard')), 0) AS oldest_standard
    FROM abuse_reports`)[0];
  return [
    "# TYPE toj_abuse_report_schema_available gauge",
    "toj_abuse_report_schema_available 1",
    "# TYPE toj_abuse_reports_stored gauge",
    `toj_abuse_reports_stored ${n(row.submitted)}`,
    "# TYPE toj_abuse_reports_resolved_stored gauge",
    `toj_abuse_reports_resolved_stored ${n(row.resolved)}`,
    "# TYPE toj_abuse_reports_open gauge",
    `toj_abuse_reports_open ${n(row.open)}`,
    `toj_abuse_reports_oldest_seconds{priority=\"urgent\"} ${Math.max(0, n(row.oldest_urgent))}`,
    `toj_abuse_reports_oldest_seconds{priority=\"standard\"} ${Math.max(0, n(row.oldest_standard))}`,
    "",
  ].join("\n");
}
