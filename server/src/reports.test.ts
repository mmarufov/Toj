import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { Client } from "pg";
import { checkVerification, startVerification } from "./auth";
import { createCall } from "./calls";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import {
  CryptoUnavailableError,
  registerKeyEncryptionProvider,
  resetEnvelopeCryptoInstancesForTests,
  unregisterKeyEncryptionProvider,
  type KeyEncryptionProvider,
} from "./envelope-crypto";
import {
  processVoIPPushBatch,
  registerInstallationPushToken,
  registerVoIPPushToken,
  type APNsSendRequest,
  type APNsSendResult,
  type PushSender,
} from "./push";
import {
  abuseReportMetrics,
  abuseReportSchemaReadiness,
  claimAbuseReport,
  cleanupAbuseReports,
  listAbuseReports,
  ReportError,
  resolveAbuseReport,
  submitAbuseReport,
  viewAbuseReport,
} from "./reports";
import { setPresenceActivity, startPresenceNotificationListener } from "./presence";
import { deleteMessage, editMessage, getOrCreateDirectDialog, sendMessage } from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb(): Promise<void> {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
  delete process.env.TOJ_BLIND_INDEX_KEYRING;
  delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
  process.env.TOJ_ABUSE_REPORTS_ENABLED = "1";
  process.env.TOJ_ABUSE_REPORTS_OPERATOR_READY = "1";
  process.env.TOJ_MODERATION_OPERATOR_ID = "moderator-on-call";
  process.env.TOJ_ABUSE_REPORTS_ALERTING_READY = "1";
  process.env.TOJ_ABUSE_REPORTS_ESCALATION_CONTACT = "safety-on-call";
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function fixture() {
  const alice = await account("+16505559101", "Alice");
  const bob = await account("+16505559102", "Bob");
  const direct = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
  const sent = await sendMessage(db, {
    senderAccountId: bob.accountId,
    senderDeviceId: bob.deviceId,
    dialogId: direct.dialogId,
    clientMsgId: crypto.randomUUID(),
    body: "unsafe message evidence",
  });
  return { alice, bob, dialogId: direct.dialogId, msgId: sent.msgId };
}

async function waitForApplicationLock(applicationName: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const row = (await db`
      SELECT wait_event_type FROM pg_stat_activity
      WHERE application_name = ${applicationName} AND state <> 'idle'
      ORDER BY backend_start DESC LIMIT 1`)[0];
    if (row?.wait_event_type === "Lock") return;
    await Bun.sleep(10);
  }
  throw new Error(`report backend ${applicationName} did not wait for the dialog lock`);
}

class PausedPushSender implements PushSender {
  requests: APNsSendRequest[] = [];
  readonly started: Promise<void>;
  private readonly releasePromise: Promise<void>;
  private markStarted!: () => void;
  private releaseSend!: () => void;

  constructor(private readonly response: APNsSendResult = { status: 200 }) {
    this.started = new Promise((resolve) => { this.markStarted = resolve; });
    this.releasePromise = new Promise((resolve) => { this.releaseSend = resolve; });
  }

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    this.markStarted();
    await this.releasePromise;
    return this.response;
  }

  release(): void {
    this.releaseSend();
  }
}

beforeEach(resetDb);
afterAll(async () => {
  delete process.env.TOJ_ABUSE_REPORTS_ENABLED;
  delete process.env.TOJ_ABUSE_REPORTS_OPERATOR_READY;
  delete process.env.TOJ_MODERATION_OPERATOR_ID;
  delete process.env.TOJ_ABUSE_REPORTS_ALERTING_READY;
  delete process.env.TOJ_ABUSE_REPORTS_ESCALATION_CONTACT;
  await db.close();
});

describe.serial("abuse reports", () => {
  test("schema readiness requires valid operational indexes and append-only triggers", async () => {
    expect(await abuseReportSchemaReadiness(db)).toEqual({ ready: true, missing: [] });
    let incomplete: Awaited<ReturnType<typeof abuseReportSchemaReadiness>> | null = null;
    try {
      await db.begin(async (tx) => {
        await tx`DROP INDEX abuse_report_budgets_retention_idx`;
        incomplete = await abuseReportSchemaReadiness(tx);
        throw new Error("rollback readiness fixture");
      });
    } catch (error) {
      expect(String(error)).toContain("rollback readiness fixture");
    }
    expect(incomplete?.ready).toBe(false);
    expect(incomplete?.missing).toContain("abuse_report_budgets_retention_idx");

    const priorEnvironment = process.env.NODE_ENV;
    try {
      process.env.NODE_ENV = "production";
      const unsafeOwner = await abuseReportSchemaReadiness(db);
      expect(unsafeOwner.ready).toBe(false);
      expect(unsafeOwner.missing).toContain("moderation.database_role_separation");
    } finally {
      if (priorEnvironment == null) delete process.env.NODE_ENV;
      else process.env.NODE_ENV = priorEnvironment;
    }
  });

  test("production readiness fails closed without throwing before the report schema is installed", async () => {
    const priorEnvironment = process.env.NODE_ENV;
    try {
      process.env.NODE_ENV = "production";
      await db.begin(async (tx) => {
        await tx`CREATE SCHEMA report_readiness_empty`;
        await tx`SET LOCAL search_path = report_readiness_empty`;
        const readiness = await abuseReportSchemaReadiness(tx);
        expect(readiness.ready).toBe(false);
        expect(readiness.missing).toContain("abuse_reports.id");
        throw new Error("rollback report readiness fixture");
      });
    } catch (error) {
      expect(String(error)).toContain("rollback report readiness fixture");
    } finally {
      if (priorEnvironment == null) delete process.env.NODE_ENV;
      else process.env.NODE_ENV = priorEnvironment;
    }
  });

  test("captures server-side evidence and preserves idempotency", async () => {
    const { alice, bob, dialogId, msgId } = await fixture();
    const clientReportId = crypto.randomUUID();
    const input = {
      clientReportId,
      dialogId,
      subject: { type: "message", msgId },
      reason: "harassment",
      details: "Repeated targeted harassment",
    };
    const first = await submitAbuseReport(db, alice.accountId, alice.deviceId, input);
    expect(first).toMatchObject({ status: "received", duplicate: false });
    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "report-v2": Buffer.alloc(32, 0x69).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "report-v2";
    const retry = await submitAbuseReport(db, alice.accountId, alice.deviceId, input);
    expect(retry).toEqual({ ...first, duplicate: true });
    expect((await db`SELECT fingerprint_key_id FROM abuse_reports WHERE id = ${first.reportId}`)[0]
      .fingerprint_key_id).toBe("report-v2");

    const report = await viewAbuseReport(db, first.reportId, true, "moderator-1");
    expect(report.reportedAccountId).toBe(bob.accountId);
    expect(report.evidence.messages.at(-1)).toMatchObject({
      msgId,
      senderAccountId: bob.accountId,
      text: "unsafe message evidence",
    });
    expect(report.evidence.details).toBe("Repeated targeted harassment");

    await expect(submitAbuseReport(db, alice.accountId, alice.deviceId, {
      ...input,
      reason: "spam",
    })).rejects.toMatchObject({ status: 409, code: "report_idempotency_conflict" });
  });

  test("makes missing and unauthorized subjects indistinguishable", async () => {
    const { alice } = await fixture();
    const charlie = await account("+16505559103", "Charlie");
    const dana = await account("+16505559104", "Dana");
    const foreign = await getOrCreateDirectDialog(db, charlie.accountId, dana.accountId);
    await expect(submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(),
      dialogId: foreign.dialogId,
      subject: { type: "account", accountId: charlie.accountId },
      reason: "spam",
    })).rejects.toMatchObject({ status: 404, code: "report_subject_not_found" });
  });

  test("rejects every unsupported subject shape without consuming report budget", async () => {
    const { alice, bob, dialogId, msgId } = await fixture();
    const charlie = await account("+16505559113", "Charlie");
    const owned = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "owned message",
    });
    const deleted = await sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "deleted message",
    });
    await deleteMessage(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId: deleted.msgId,
      clientMutationId: crypto.randomUUID(),
    });
    const service = await sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "service event",
      kind: "service",
      internalService: true,
    });
    const inputs = [
      { dialogId, subject: { type: "account", accountId: alice.accountId } },
      { dialogId, subject: { type: "account", accountId: charlie.accountId } },
      { dialogId, subject: { type: "message", msgId: owned.msgId } },
      { dialogId, subject: { type: "message", msgId: deleted.msgId } },
      { dialogId, subject: { type: "message", msgId: service.msgId } },
      { dialogId, subject: { type: "message", msgId: msgId + 100_000 } },
      { dialogId: crypto.randomUUID(), subject: { type: "message", msgId } },
    ];
    for (const candidate of inputs) {
      await expect(submitAbuseReport(db, alice.accountId, alice.deviceId, {
        clientReportId: crypto.randomUUID(),
        ...candidate,
        reason: "spam",
      })).rejects.toMatchObject({ status: 404, code: "report_subject_not_found" });
    }
    expect(await db`SELECT id FROM abuse_reports WHERE reporter_account_id = ${alice.accountId}`)
      .toHaveLength(0);
    expect(await db`SELECT id FROM abuse_report_submission_budgets
      WHERE reporter_account_id = ${alice.accountId}`).toHaveLength(0);
  });

  test("bounds account and message context to server-selected recent messages", async () => {
    const { alice, bob, dialogId } = await fixture();
    const sent: number[] = [];
    for (let index = 0; index < 12; index += 1) {
      const message = await sendMessage(db, {
        senderAccountId: bob.accountId,
        senderDeviceId: bob.deviceId,
        dialogId,
        clientMsgId: crypto.randomUUID(),
        body: `context-${index}`,
      });
      sent.push(message.msgId);
    }
    const accountReport = await submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(),
      dialogId,
      subject: { type: "account", accountId: bob.accountId },
      reason: "spam",
    });
    const accountEvidence = (await viewAbuseReport(
      db, accountReport.reportId, true, "moderator-context",
    )).evidence;
    expect(accountEvidence.messages).toHaveLength(10);
    expect(accountEvidence.messages.map((message: any) => message.msgId))
      .toEqual(sent.slice(-10));

    const messageReport = await submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(),
      dialogId,
      subject: { type: "message", msgId: sent.at(-1)! },
      reason: "harassment",
    });
    const messageEvidence = (await viewAbuseReport(
      db, messageReport.reportId, true, "moderator-context",
    )).evidence;
    expect(messageEvidence.messages).toHaveLength(6);
    expect(messageEvidence.messages.at(-1).msgId).toBe(sent.at(-1));
    expect(Buffer.byteLength(JSON.stringify(messageEvidence), "utf8")).toBeLessThanOrEqual(256 * 1024);
  });

  test("membership removal cannot commit between report authorization and evidence capture", async () => {
    const { alice, bob, dialogId } = await fixture();
    const applicationName = `toj-report-race-${crypto.randomUUID()}`;
    const separator = TEST_URL.includes("?") ? "&" : "?";
    const reportDb = makeSql(`${TEST_URL}${separator}application_name=${applicationName}`);
    const blocker = new Client({ connectionString: TEST_URL });
    await blocker.connect();
    let blockerCommitted = false;
    try {
      await blocker.query("BEGIN");
      await blocker.query("SELECT id FROM dialogs WHERE id = $1 FOR UPDATE", [dialogId]);
      await blocker.query(
        "UPDATE dialog_members SET left_at = now() WHERE dialog_id = $1 AND account_id = $2",
        [dialogId, alice.accountId],
      );
      const pending = submitAbuseReport(reportDb, alice.accountId, alice.deviceId, {
        clientReportId: crypto.randomUUID(), dialogId,
        subject: { type: "account", accountId: bob.accountId }, reason: "spam",
      });
      await waitForApplicationLock(applicationName);
      await blocker.query("COMMIT");
      blockerCommitted = true;
      await expect(pending).rejects.toMatchObject({
        status: 404, code: "report_subject_not_found",
      });
      expect(await db`SELECT id FROM abuse_reports WHERE reporter_account_id = ${alice.accountId}`)
        .toHaveLength(0);
    } finally {
      if (!blockerCommitted) await blocker.query("ROLLBACK").catch(() => {});
      await blocker.end();
      await reportDb.close();
    }
  });

  test("message edits and deletes linearize after the immutable report evidence snapshot", async () => {
    const { alice, bob, dialogId, msgId } = await fixture();

    const runPausedReport = async (
      reason: "harassment" | "violence",
      mutation: () => Promise<unknown>,
    ) => {
      const applicationName = `toj-report-message-race-${crypto.randomUUID()}`;
      const separator = TEST_URL.includes("?") ? "&" : "?";
      const reportDb = makeSql(`${TEST_URL}${separator}application_name=${applicationName}`);
      const blocker = new Client({ connectionString: TEST_URL });
      await blocker.connect();
      let blockerOpen = false;
      try {
        await blocker.query("BEGIN");
        blockerOpen = true;
        // This is the final write in report submission. Blocking it lets the report hold its
        // dialog/message locks after evidence capture while a live mutation attempts to start.
        await blocker.query("LOCK TABLE abuse_report_actions IN ACCESS EXCLUSIVE MODE");
        const submission = submitAbuseReport(reportDb, alice.accountId, alice.deviceId, {
          clientReportId: crypto.randomUUID(), dialogId,
          subject: { type: "message", msgId }, reason,
        });
        await waitForApplicationLock(applicationName);

        let mutationSettled = false;
        const pendingMutation = mutation().finally(() => { mutationSettled = true; });
        await Bun.sleep(50);
        expect(mutationSettled).toBe(false);

        await blocker.query("COMMIT");
        blockerOpen = false;
        const report = await submission;
        await pendingMutation;
        return await viewAbuseReport(db, report.reportId, true, "moderator-race");
      } finally {
        if (blockerOpen) await blocker.query("ROLLBACK");
        await blocker.end();
        await reportDb.close();
      }
    };

    const beforeEdit = await runPausedReport("harassment", () => editMessage(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId,
      clientMutationId: crypto.randomUUID(),
      body: "edited after report evidence",
      expectedEditVersion: 0,
    }));
    expect(beforeEdit.evidence.messages.find((message: any) => message.msgId === msgId)?.text)
      .toBe("unsafe message evidence");

    const beforeDelete = await runPausedReport("violence", () => deleteMessage(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId,
      clientMutationId: crypto.randomUUID(),
    }));
    expect(beforeDelete.evidence.messages.find((message: any) => message.msgId === msgId)?.text)
      .toBe("edited after report evidence");
    expect((await db`SELECT state FROM messages
      WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`)[0].state).toBe("deleted_for_all");
  });

  test("validates detail rules and enforces serial hourly budgets", async () => {
    const { alice, bob, dialogId } = await fixture();
    await expect(submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "account", accountId: bob.accountId },
      reason: "other", details: "too short",
    })).rejects.toBeInstanceOf(ReportError);

    for (let index = 0; index < 5; index += 1) {
      await submitAbuseReport(db, alice.accountId, alice.deviceId, {
        clientReportId: crypto.randomUUID(), dialogId,
        subject: { type: "account", accountId: bob.accountId }, reason: "spam",
      });
    }
    await expect(submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "account", accountId: bob.accountId }, reason: "spam",
    })).rejects.toMatchObject({ status: 429, code: "report_rate_limited", retryAfter: 3600 });
  });

  test("uses Unicode-scalar detail bounds and serializes concurrent idempotent retries", async () => {
    const { alice, bob, dialogId } = await fixture();
    const input = {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "account", accountId: bob.accountId }, reason: "other",
      details: "😀".repeat(500),
    };
    const [first, second] = await Promise.all([
      submitAbuseReport(db, alice.accountId, alice.deviceId, input),
      submitAbuseReport(db, alice.accountId, alice.deviceId, input),
    ]);
    expect([first.duplicate, second.duplicate].sort()).toEqual([false, true]);
    expect(Number((await db`SELECT count(*) AS count FROM abuse_report_submission_budgets
      WHERE reporter_account_id = ${alice.accountId}`)[0].count)).toBe(1);
    await expect(submitAbuseReport(db, alice.accountId, alice.deviceId, {
      ...input, clientReportId: crypto.randomUUID(), details: "😀".repeat(501),
    })).rejects.toBeInstanceOf(ReportError);
  });

  test("serializes distinct submissions at the hourly boundary and enforces the daily budget", async () => {
    const { alice, bob, dialogId } = await fixture();
    await db`
      INSERT INTO abuse_report_submission_budgets(reporter_account_id, accepted_at)
      SELECT ${alice.accountId}, now() - interval '10 minutes' FROM generate_series(1, 4)`;
    const submit = () => submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "account" as const, accountId: bob.accountId }, reason: "spam",
    });
    const hourly = await Promise.allSettled([submit(), submit()]);
    expect(hourly.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(hourly.filter((result) => result.status === "rejected")).toHaveLength(1);

    await db`DELETE FROM abuse_report_submission_budgets`;
    await db`
      INSERT INTO abuse_report_submission_budgets(reporter_account_id, accepted_at)
      SELECT ${alice.accountId}, now() - interval '2 hours' FROM generate_series(1, 20)`;
    await expect(submit()).rejects.toMatchObject({
      status: 429, code: "report_rate_limited",
    });
  });

  test("honors the authenticated HTTP 201/200/404 contract", async () => {
    const { alice, dialogId, msgId } = await fixture();
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    const endpoint = `http://127.0.0.1:${server.port}/v1/reports`;
    const payload = {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "message", msgId }, reason: "harassment",
      details: "HTTP contract evidence",
    };
    try {
      const unauthenticated = await fetch(endpoint, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });
      expect(unauthenticated.status).toBe(401);

      const nullBody = await fetch(endpoint, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: "null",
      });
      expect(nullBody.status).toBe(400);
      expect(await nullBody.json()).toMatchObject({ code: "invalid_report" });

      const submit = () => fetch(endpoint, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify(payload),
      });
      const first = await submit();
      expect(first.status).toBe(201);
      expect(await first.json()).toMatchObject({ status: "received", duplicate: false });
      const duplicate = await submit();
      expect(duplicate.status).toBe(200);
      expect(await duplicate.json()).toMatchObject({ status: "received", duplicate: true });

      const missing = await fetch(endpoint, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify({
          ...payload,
          clientReportId: crypto.randomUUID(),
          subject: { type: "message", msgId: msgId + 999 },
        }),
      });
      expect(missing.status).toBe(404);
      expect(await missing.json()).toMatchObject({ code: "report_subject_not_found" });
    } finally {
      server.stop(true);
    }
  });

  test("returns retryable crypto_unavailable without committing a partial report", async () => {
    const { alice, dialogId, msgId } = await fixture();
    const provider: KeyEncryptionProvider = {
      providerId: "report-outage-test",
      generateAndWrap: async () => { throw new CryptoUnavailableError(); },
      unwrap: async () => { throw new CryptoUnavailableError(); },
      rewrap: async () => { throw new CryptoUnavailableError(); },
      healthCheck: async () => { throw new CryptoUnavailableError(); },
    };
    const previousMode = process.env.TOJ_CRYPTO_MODE;
    const previousProvider = process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
    process.env.TOJ_CRYPTO_MODE = "envelope";
    process.env.TOJ_KEY_ENCRYPTION_PROVIDER = provider.providerId;
    resetEnvelopeCryptoInstancesForTests();
    registerKeyEncryptionProvider(provider);
    let server: ReturnType<typeof startCloudServer> | null = null;
    try {
      server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
      const response = await fetch(`http://127.0.0.1:${server.port}/v1/reports`, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify({
          clientReportId: crypto.randomUUID(),
          dialogId,
          subject: { type: "message", msgId },
          reason: "harassment",
        }),
      });
      expect(response.status).toBe(503);
      expect(response.headers.get("retry-after")).toBe("5");
      expect(await response.json()).toMatchObject({ code: "crypto_unavailable" });
      expect(await db`SELECT id FROM abuse_reports WHERE reporter_account_id = ${alice.accountId}`)
        .toHaveLength(0);
      expect(await db`SELECT id FROM abuse_report_submission_budgets
        WHERE reporter_account_id = ${alice.accountId}`).toHaveLength(0);
    } finally {
      server?.stop(true);
      if (previousMode == null) delete process.env.TOJ_CRYPTO_MODE;
      else process.env.TOJ_CRYPTO_MODE = previousMode;
      if (previousProvider == null) delete process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
      else process.env.TOJ_KEY_ENCRYPTION_PROVIDER = previousProvider;
      unregisterKeyEncryptionProvider(provider.providerId);
      resetEnvelopeCryptoInstancesForTests();
    }
  });

  test("audits operator actions, removes reported content, and expires evidence separately", async () => {
    const { alice, dialogId, msgId } = await fixture();
    const submitted = await submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "message", msgId }, reason: "violence",
    });
    expect(await claimAbuseReport(db, submitted.reportId, "moderator-1", "triaged")).toEqual({
      claimed: true, duplicate: false,
    });
    expect(await resolveAbuseReport(
      db, submitted.reportId, "moderator-1", "content_removed", "policy violation",
    )).toEqual({ resolved: true, duplicate: false });
    const message = (await db`
      SELECT state, media_id FROM messages WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`)[0];
    expect(message).toMatchObject({ state: "deleted_for_all", media_id: null });

    const audit = await viewAbuseReport(db, submitted.reportId, false, "moderator-1");
    expect(audit.actions.map((action: any) => action.action)).toEqual([
      "created", "claimed", "content_removed",
    ]);
    expect(audit.actions.every((action: any) => !("note" in action))).toBe(true);
    const evidenceView = await viewAbuseReport(db, submitted.reportId, true, "moderator-1");
    expect(evidenceView.actions.map((action: any) => action.note)).toEqual([
      null, "triaged", "policy violation",
    ]);
    expect(await listAbuseReports(db, "moderator-1", 10)).toHaveLength(0);
    expect((await db`SELECT reason, actor_id FROM content_access_audit
      WHERE request_id = ${submitted.reportId} ORDER BY created_at`).map((row: any) => row.reason))
      .toEqual(["abuse_report.view", "abuse_report.view_evidence"]);
    expect((await db`SELECT actor_id FROM content_access_audit
      WHERE reason = 'abuse_report.list' ORDER BY created_at DESC LIMIT 1`)[0].actor_id)
      .toBe("moderator-1");
    let updateError: unknown;
    try {
      await db`UPDATE abuse_report_actions SET action = 'resolved'
        WHERE report_id = ${submitted.reportId}`;
    } catch (error) { updateError = error; }
    expect(String(updateError)).toContain("append-only");
    let deleteError: unknown;
    try {
      await db`DELETE FROM abuse_report_actions WHERE report_id = ${submitted.reportId}`;
    } catch (error) { deleteError = error; }
    expect(String(deleteError)).toContain("append-only");
    let accessUpdateError: unknown;
    try {
      await db`UPDATE content_access_audit SET actor_id = 'tampered'
        WHERE request_id = ${submitted.reportId}`;
    } catch (error) { accessUpdateError = error; }
    expect(String(accessUpdateError)).toContain("append-only");
    await db`
      UPDATE abuse_reports SET evidence_expires_at = now() - interval '1 second'
      WHERE id = ${submitted.reportId}`;
    expect(await cleanupAbuseReports(db, 10)).toMatchObject({ evidence: 1, reports: 0 });
    expect((await db`SELECT evidence_ciphertext FROM abuse_reports WHERE id = ${submitted.reportId}`)[0]
      .evidence_ciphertext).toBeNull();
    await db`UPDATE abuse_reports SET audit_expires_at = now() - interval '1 second'
      WHERE id = ${submitted.reportId}`;
    expect(await cleanupAbuseReports(db, 10)).toMatchObject({ reports: 1 });
    expect(await db`SELECT id FROM abuse_report_actions WHERE report_id = ${submitted.reportId}`)
      .toHaveLength(0);
  });

  test("retains report-specific access audits until 365 days after resolution", async () => {
    const { alice, dialogId, msgId } = await fixture();
    const submitted = await submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "message", msgId }, reason: "harassment",
    });
    await db`INSERT INTO content_access_audit (
      actor_kind, actor_id, account_id, dialog_id, msg_id, reason, request_id, created_at
    ) VALUES (
      'moderation', 'moderator-retention', ${alice.accountId}, ${dialogId}, ${msgId},
      'abuse_report.view', ${submitted.reportId}, now() - interval '366 days'
    )`;

    expect(await cleanupAbuseReports(db, 10)).toMatchObject({ accessAudits: 0 });
    expect(await db`SELECT id FROM content_access_audit
      WHERE request_id = ${submitted.reportId}`).toHaveLength(1);

    await resolveAbuseReport(db, submitted.reportId, "moderator-retention", "resolved", null);
    await db`UPDATE abuse_reports SET audit_expires_at = now() - interval '1 second'
      WHERE id = ${submitted.reportId}`;
    expect(await cleanupAbuseReports(db, 10)).toMatchObject({ accessAudits: 1, reports: 1 });
    expect(await db`SELECT id FROM content_access_audit
      WHERE request_id = ${submitted.reportId}`).toHaveLength(0);
  });

  test("caller-set retention GUCs cannot bypass append-only audit triggers", async () => {
    const { alice, dialogId, msgId } = await fixture();
    const submitted = await submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "message", msgId }, reason: "harassment",
    });
    await viewAbuseReport(db, submitted.reportId, false, "moderator-role-test");
    const role = `toj_audit_probe_${crypto.randomUUID().replaceAll("-", "")}`;
    await db.unsafe(`CREATE ROLE "${role}" NOLOGIN`);
    try {
      await db.unsafe(`GRANT USAGE ON SCHEMA public TO "${role}"`);
      await db.unsafe(`GRANT SELECT, UPDATE, DELETE ON abuse_report_actions, content_access_audit TO "${role}"`);
      let actionError: unknown;
      try {
        await db.begin(async (tx) => {
          await tx.unsafe(`SET LOCAL ROLE "${role}"`);
          await tx`SELECT set_config('toj.allow_abuse_report_crypto_migration', '1', true)`;
          await tx`UPDATE abuse_report_actions SET note_key_id = note_key_id
            WHERE report_id = ${submitted.reportId}`;
        });
      } catch (error) { actionError = error; }
      expect(String(actionError)).toContain("append-only");

      let accessError: unknown;
      try {
        await db.begin(async (tx) => {
          await tx.unsafe(`SET LOCAL ROLE "${role}"`);
          await tx`SELECT set_config('toj.allow_content_access_retention_delete', '1', true)`;
          await tx`DELETE FROM content_access_audit WHERE request_id = ${submitted.reportId}`;
        });
      } catch (error) { accessError = error; }
      expect(String(accessError)).toContain("append-only");
    } finally {
      await db.unsafe(`DROP OWNED BY "${role}"`);
      await db.unsafe(`DROP ROLE "${role}"`);
    }
  });

  test("account-ban resolution revokes sessions, devices, and push registrations", async () => {
    const { alice, bob, dialogId } = await fixture();
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "reciprocal call eligibility",
    });
    await registerVoIPPushToken(
      db, bob.deviceId, "aa".repeat(32), "sandbox", [1], [1], 1,
    );
    const installationId = crypto.randomUUID();
    await registerInstallationPushToken(db, {
      accountId: bob.accountId,
      deviceId: bob.deviceId,
      installationId,
      token: "ab".repeat(32),
      environment: "sandbox",
      kind: "normal",
    });
    const callId = crypto.randomUUID();
    await createCall(db, {
      callerAccountId: alice.accountId,
      callerDeviceId: alice.deviceId,
      callId,
      dialogId,
      callerCommitment: Buffer.alloc(32, 0x41).toString("base64"),
      supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
      videoEnabled: false,
    });
    await db`UPDATE devices SET
      push_token_hash = ${Buffer.alloc(32, 1)}, push_token_hash_key_id = 'legacy-v1',
      push_token_ciphertext = ${Buffer.alloc(32, 2)}, push_token_nonce = ${Buffer.alloc(12, 3)},
      push_token_key_id = 'dev-v1', push_environment = 'sandbox'
      WHERE id = ${bob.deviceId}`;
    const submitted = await submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "account", accountId: bob.accountId }, reason: "scam",
    });
    await claimAbuseReport(db, submitted.reportId, "moderator-1", null);
    await resolveAbuseReport(db, submitted.reportId, "moderator-1", "account_banned", null);
    expect((await db`SELECT status FROM accounts WHERE id = ${bob.accountId}`)[0].status).toBe("banned");
    const bannedDevice = (await db`SELECT revoked_at, auth_token_key_id,
      push_token_hash, push_token_hash_key_id, push_token_ciphertext,
      voip_push_token_hash, voip_push_token_hash_key_id
      FROM devices WHERE id = ${bob.deviceId}`)[0];
    expect(bannedDevice).toMatchObject({
      auth_token_key_id: "random-deleted",
      push_token_hash: null, push_token_hash_key_id: null, push_token_ciphertext: null,
      voip_push_token_hash: null, voip_push_token_hash_key_id: null,
    });
    expect(bannedDevice.revoked_at).not.toBeNull();
    expect(await db`SELECT 1 FROM push_account_bindings
      WHERE installation_id = ${installationId} AND account_id = ${bob.accountId}`).toHaveLength(0);
    expect(await db`SELECT 1 FROM push_installations
      WHERE installation_id = ${installationId}`).toHaveLength(0);
    expect((await db`SELECT state, end_reason FROM calls WHERE id = ${callId}`)[0])
      .toMatchObject({ state: "ended", end_reason: "account_banned" });

    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    try {
      const response = await fetch(`http://127.0.0.1:${server.port}/v1/devices`, {
        headers: { authorization: `Bearer ${bob.token}` },
      });
      expect(response.status).toBe(401);
    } finally {
      server.stop(true);
    }
  });

  test("account-ban resolution atomically publishes terminal presence and removes every lease", async () => {
    const previousPresence = process.env.TOJ_PRESENCE_V1_ENABLED;
    const previousPresenceRollout = process.env.TOJ_PRESENCE_ROLLOUT_PERCENT;
    process.env.TOJ_PRESENCE_V1_ENABLED = "1";
    process.env.TOJ_PRESENCE_ROLLOUT_PERCENT = "100";
    const { alice, bob, dialogId } = await fixture();
    const connectionId = crypto.randomUUID();
    await setPresenceActivity(db, {
      accountId: bob.accountId,
      deviceId: bob.deviceId,
      connectionId,
      active: true,
    });

    const terminalEvents: any[] = [];
    let resolveTerminal!: () => void;
    const terminal = new Promise<void>((resolve) => { resolveTerminal = resolve; });
    const stopPresenceListener = startPresenceNotificationListener(TEST_URL, (broadcast) => {
      if (!broadcast.recipientAccountIds.includes(alice.accountId)) return;
      const event = broadcast.event as any;
      if (event.accountId !== bob.accountId) return;
      terminalEvents.push(event);
      const hasOffline = terminalEvents.some((candidate) => (
        candidate.type === "presence_update" && candidate.online === false
      ));
      const hasHidden = terminalEvents.some((candidate) => (
        candidate.type === "presence_visibility" && candidate.visible === false
      ));
      if (hasOffline && hasHidden) resolveTerminal();
    });

    try {
      // The listener connects asynchronously; wait before the transaction commits its NOTIFYs.
      await Bun.sleep(100);
      const submitted = await submitAbuseReport(db, alice.accountId, alice.deviceId, {
        clientReportId: crypto.randomUUID(), dialogId,
        subject: { type: "account", accountId: bob.accountId }, reason: "scam",
      });
      await claimAbuseReport(db, submitted.reportId, "moderator-1", null);
      await resolveAbuseReport(db, submitted.reportId, "moderator-1", "account_banned", null);
      await Promise.race([
        terminal,
        Bun.sleep(3_000).then(() => { throw new Error("terminal presence notification timed out"); }),
      ]);

      expect(terminalEvents).toContainEqual(expect.objectContaining({
        type: "presence_update", accountId: bob.accountId, online: false,
      }));
      expect(terminalEvents).toContainEqual({
        type: "presence_visibility", accountId: bob.accountId, visible: false,
      });
      expect(await db`
        SELECT connection_id FROM device_presence_leases WHERE account_id = ${bob.accountId}`)
        .toHaveLength(0);
    } finally {
      stopPresenceListener();
      if (previousPresence === undefined) delete process.env.TOJ_PRESENCE_V1_ENABLED;
      else process.env.TOJ_PRESENCE_V1_ENABLED = previousPresence;
      if (previousPresenceRollout === undefined) delete process.env.TOJ_PRESENCE_ROLLOUT_PERCENT;
      else process.env.TOJ_PRESENCE_ROLLOUT_PERCENT = previousPresenceRollout;
    }
  }, 5_000);

  test("account bans and VoIP invites have a single transaction ordering", async () => {
    const { alice, bob, dialogId } = await fixture();
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "reciprocal call eligibility",
    });
    await registerVoIPPushToken(
      db, bob.deviceId, "bb".repeat(32), "sandbox", [1], [1], 1,
    );
    const callId = crypto.randomUUID();
    await createCall(db, {
      callerAccountId: alice.accountId,
      callerDeviceId: alice.deviceId,
      callId,
      dialogId,
      callerCommitment: Buffer.alloc(32, 0x42).toString("base64"),
      supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
      videoEnabled: false,
    });
    const submitted = await submitAbuseReport(db, alice.accountId, alice.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId,
      subject: { type: "account", accountId: bob.accountId }, reason: "scam",
    });
    await claimAbuseReport(db, submitted.reportId, "moderator-1", null);

    const sender = new PausedPushSender({ status: 200, apnsId: "before-ban" });
    const processing = processVoIPPushBatch(db, sender, 1);
    await sender.started;
    let banCommitted = false;
    const ban = resolveAbuseReport(
      db, submitted.reportId, "moderator-1", "account_banned", null,
    ).then((result) => {
      banCommitted = true;
      return result;
    });
    await Bun.sleep(50);
    expect(banCommitted).toBe(false);
    sender.release();
    expect(await processing).toBe(1);
    expect(await ban).toMatchObject({ resolved: true, duplicate: false });
    expect(sender.requests).toEqual([expect.objectContaining({
      kind: "voip", callId,
    })]);
    expect((await db`SELECT status FROM voip_push_deliveries WHERE call_id = ${callId}`)[0].status)
      .toBe("sent");
    expect((await db`SELECT state, end_reason FROM calls WHERE id = ${callId}`)[0])
      .toMatchObject({ state: "ended", end_reason: "account_banned" });

    const carol = await account("+16505559111", "Carol");
    const dana = await account("+16505559112", "Dana");
    const secondDialog = await getOrCreateDirectDialog(db, carol.accountId, dana.accountId);
    await sendMessage(db, {
      senderAccountId: dana.accountId,
      senderDeviceId: dana.deviceId,
      dialogId: secondDialog.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "report evidence",
    });
    await sendMessage(db, {
      senderAccountId: carol.accountId,
      senderDeviceId: carol.deviceId,
      dialogId: secondDialog.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "reciprocal call eligibility",
    });
    await registerVoIPPushToken(
      db, dana.deviceId, "cc".repeat(32), "sandbox", [1], [1], 1,
    );
    const secondCallId = crypto.randomUUID();
    await createCall(db, {
      callerAccountId: carol.accountId,
      callerDeviceId: carol.deviceId,
      callId: secondCallId,
      dialogId: secondDialog.dialogId,
      callerCommitment: Buffer.alloc(32, 0x43).toString("base64"),
      supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
      videoEnabled: false,
    });
    const secondReport = await submitAbuseReport(db, carol.accountId, carol.deviceId, {
      clientReportId: crypto.randomUUID(), dialogId: secondDialog.dialogId,
      subject: { type: "account", accountId: dana.accountId }, reason: "scam",
    });
    await claimAbuseReport(db, secondReport.reportId, "moderator-1", null);
    await resolveAbuseReport(
      db, secondReport.reportId, "moderator-1", "account_banned", null,
    );
    const afterBan = new PausedPushSender();
    expect(await processVoIPPushBatch(db, afterBan, 1)).toBe(0);
    expect(afterBan.requests).toHaveLength(0);
    expect((await db`SELECT status, last_error FROM voip_push_deliveries
      WHERE call_id = ${secondCallId}`)[0])
      .toMatchObject({ status: "dead", last_error: "call ended" });
  });

  test("advertises only when schema and all operator gates are ready", async () => {
    const previousProfilePhotos = process.env.TOJ_PROFILE_PHOTOS_V1_ENABLED;
    const previousPresence = process.env.TOJ_PRESENCE_V1_ENABLED;
    const previousPresenceRollout = process.env.TOJ_PRESENCE_ROLLOUT_PERCENT;
    process.env.TOJ_PROFILE_PHOTOS_V1_ENABLED = "1";
    process.env.TOJ_PRESENCE_V1_ENABLED = "1";
    process.env.TOJ_PRESENCE_ROLLOUT_PERCENT = "100";
    try {
      const { alice } = await fixture();
      const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
      try {
        const response = await fetch(`http://127.0.0.1:${server.port}/v1/capabilities`, {
          headers: { authorization: `Bearer ${alice.token}` },
        });
        expect(response.status).toBe(200);
        expect((await response.json() as { capabilities: string[] }).capabilities)
          .toEqual(expect.arrayContaining([
            "abuse_reports_v1", "presence_v1", "profile_photos_v1",
          ]));
        const metrics = await abuseReportMetrics(db);
        expect(metrics).toContain("toj_abuse_report_schema_available 1");
      } finally {
        server.stop(true);
      }

      delete process.env.TOJ_ABUSE_REPORTS_OPERATOR_READY;
      const hiddenServer = startCloudServer(0, db, null, null, { backgroundWorkers: false });
      try {
        const response = await fetch(`http://127.0.0.1:${hiddenServer.port}/v1/capabilities`, {
          headers: { authorization: `Bearer ${alice.token}` },
        });
        const capabilities = (await response.json() as { capabilities: string[] }).capabilities;
        expect(capabilities).not.toContain("abuse_reports_v1");
        expect(capabilities).toEqual(expect.arrayContaining([
          "presence_v1", "profile_photos_v1",
        ]));
      } finally {
        hiddenServer.stop(true);
      }
    } finally {
      if (previousProfilePhotos === undefined) delete process.env.TOJ_PROFILE_PHOTOS_V1_ENABLED;
      else process.env.TOJ_PROFILE_PHOTOS_V1_ENABLED = previousProfilePhotos;
      if (previousPresence === undefined) delete process.env.TOJ_PRESENCE_V1_ENABLED;
      else process.env.TOJ_PRESENCE_V1_ENABLED = previousPresence;
      if (previousPresenceRollout === undefined) delete process.env.TOJ_PRESENCE_ROLLOUT_PERCENT;
      else process.env.TOJ_PRESENCE_ROLLOUT_PERCENT = previousPresenceRollout;
    }
  });
});
