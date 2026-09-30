import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { SQL } from "bun";
import { checkVerification, startVerification } from "./auth";
import {
  clearCloudProductivityReadinessCache,
  clearWorkerHeartbeatCache,
  cloudProductivitySchemaState,
  workerHeartbeatFresh,
} from "./cloud-productivity-readiness";
import { productivityNeedsForPath, startCloudServer } from "./cloud";
import { scheduledItemAAD, seal } from "./crypto";
import { makeSql } from "./db";
import { clearMessagingFeatureReadinessCache } from "./messaging-feature-readiness";
import { drainLinkPreviewFanout } from "./link-previews";
import { createMediaUpload, mediaLimits } from "./media";
import {
  linkPreviewWorkerConcurrency,
  productivityWorkerLeaseSeconds,
  scheduledDeliveryWorkerConcurrency,
} from "./productivity-runtime";
import {
  cancelScheduledDelivery,
  createScheduledDelivery,
  drainScheduledDeliveries,
  listScheduledDeliveries,
  startScheduledDeliveryWorker,
} from "./scheduled-deliveries";
import { getOrCreateDirectDialog } from "./sync";

process.env.TOJ_PRODUCTIVITY_WORKERS_DISABLED = "1";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);
const MEDIA_BYTES = 25 * 1024 * 1024;
const MANAGED_ENV = [
  "TOJ_MEDIA_MAX_OBJECT_BYTES",
  "TOJ_MEDIA_ACCOUNT_QUOTA_BYTES",
  "TOJ_SCHEDULED_DELIVERY_WORKER_CONCURRENCY",
  "TOJ_LINK_PREVIEW_WORKER_CONCURRENCY",
  "TOJ_PRODUCTIVITY_WORKER_LEASE_SECONDS",
  "TOJ_SCHEDULED_DELIVERY_V1_ENABLED",
  "TOJ_SCHEDULED_DELIVERY_ALLOWLIST",
  "TOJ_SCHEDULED_DELIVERY_ROLLOUT_PERCENT",
  "TOJ_LINK_PREVIEWS_V1_ENABLED",
  "TOJ_LINK_PREVIEWS_ALLOWLIST",
  "TOJ_LINK_PREVIEWS_ROLLOUT_PERCENT",
  "TOJ_AUTH_SESSIONS_V2_ENABLED",
  "TOJ_TWO_FACTOR_ENABLED",
  "TOJ_PINNED_MESSAGES_ENABLED",
  "TOJ_AUTO_DELETE_ENABLED",
  "TOJ_POLLS_ENABLED",
  "TOJ_STICKER_PACKS_ENABLED",
  "TOJ_GIPHY_ENABLED",
  "TOJ_MULTI_ACCOUNT_PUSH_ENABLED",
] as const;
const originalEnvironment = new Map(MANAGED_ENV.map((name) => [name, process.env[name]]));

function restoreEnvironment(): void {
  for (const [name, value] of originalEnvironment) {
    if (value == null) delete process.env[name];
    else process.env[name] = value;
  }
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function pair() {
  const alice = await account("+16505554801", "Alice");
  const bob = await account("+16505554802", "Bob");
  const direct = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId, alice.deviceId);
  return { alice, bob, dialogId: direct.dialogId };
}

function countedSql(base: SQL, onQuery?: (text: string) => void): { sql: SQL; count: () => number } {
  let calls = 0;
  const wrap = (candidate: SQL): SQL => new Proxy(candidate, {
    apply(target, _thisArg, args) {
      calls += 1;
      const strings = args[0];
      onQuery?.(Array.isArray(strings) ? strings.join("?") : String(strings));
      return Reflect.apply(target, target, args);
    },
    get(target, property, receiver) {
      const value = Reflect.get(target, property, receiver);
      if (property === "begin" && typeof value === "function") {
        return (callback: (tx: SQL) => unknown) => Reflect.apply(value, target, [
          (tx: SQL) => callback(wrap(tx)),
        ]);
      }
      return typeof value === "function" ? value.bind(target) : value;
    },
  }) as SQL;
  const sql = wrap(base);
  return { sql, count: () => calls };
}

function blockedScheduledDispatchSql(base: SQL) {
  let active = 0;
  let maximumActive = 0;
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const sql = new Proxy(base, {
    apply(target, _thisArg, args) {
      const strings = args[0];
      const query = Array.isArray(strings) ? strings.join("?") : String(strings);
      if (query.includes("SELECT account_id, origin_device_id, dialog_id, silent, reminder, attempts")) {
        return (async () => {
          active += 1;
          maximumActive = Math.max(maximumActive, active);
          try {
            await gate;
            return await Reflect.apply(target, target, args);
          } finally {
            active -= 1;
          }
        })();
      }
      return Reflect.apply(target, target, args);
    },
    get(target, property, receiver) {
      const value = Reflect.get(target, property, receiver);
      return typeof value === "function" ? value.bind(target) : value;
    },
  }) as SQL;
  return {
    sql,
    release,
    active: () => active,
    maximumActive: () => maximumActive,
  };
}

function pausedScheduledCompletionSql(base: SQL) {
  let ownsDeliveryRow = false;
  let ownershipFollowedAccountLock = false;
  let ownershipTransactionQueries: string[] = [];
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const wrap = (
    candidate: SQL,
    transactionState?: { accountLockObserved: boolean; queries: string[] },
  ): SQL => new Proxy(candidate, {
    apply(target, _thisArg, args) {
      const strings = args[0];
      const query = Array.isArray(strings) ? strings.join("?") : String(strings);
      const normalizedQuery = query.replace(/\s+/g, " ").trim();
      transactionState?.queries.push(normalizedQuery);
      if (normalizedQuery.includes("pg_advisory_xact_lock")) {
        if (transactionState) transactionState.accountLockObserved = true;
      }
      const result = Reflect.apply(target, target, args);
      if (
        (normalizedQuery.includes("SELECT 1 FROM scheduled_deliveries")
          || normalizedQuery.includes("SELECT account_id FROM scheduled_deliveries"))
        && normalizedQuery.includes("state = 'processing'")
        && normalizedQuery.includes("lease_token =")
        && normalizedQuery.includes("FOR UPDATE")
      ) {
        return (async () => {
          const rows = await result;
          if (rows.length > 0) {
            ownsDeliveryRow = true;
            ownershipFollowedAccountLock = transactionState?.accountLockObserved === true;
            ownershipTransactionQueries = transactionState?.queries ?? [];
            await gate;
          }
          return rows;
        })();
      }
      return result;
    },
    get(target, property, receiver) {
      const value = Reflect.get(target, property, receiver);
      if (property === "begin" && typeof value === "function") {
        return (callback: (tx: SQL) => unknown) => Reflect.apply(value, target, [
          (tx: SQL) => callback(wrap(tx, { accountLockObserved: false, queries: [] })),
        ]);
      }
      return typeof value === "function" ? value.bind(target) : value;
    },
  }) as SQL;
  return {
    sql: wrap(base),
    release,
    ownsDeliveryRow: () => ownsDeliveryRow,
    ownershipFollowedAccountLock: () => ownershipFollowedAccountLock,
    ownershipTransactionQueries: () => ownershipTransactionQueries,
  };
}

async function waitUntil(predicate: () => boolean, message: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (predicate()) return;
    await Bun.sleep(10);
  }
  throw new Error(message);
}

describe("dark-gated scaling hardening", () => {
  beforeEach(async () => {
    restoreEnvironment();
    await db`
      TRUNCATE accounts, otp_challenges, link_preview_cache_entries
      RESTART IDENTITY CASCADE`;
    clearCloudProductivityReadinessCache(db);
    clearWorkerHeartbeatCache(db);
  });

  afterEach(() => {
    restoreEnvironment();
  });

  test("25 MB is accepted while larger and unsafe configured media limits are rejected", async () => {
    const alice = await account("+16505554803", "Media");
    expect(mediaLimits()).toMatchObject({
      maxObjectBytes: MEDIA_BYTES,
      accountQuotaBytes: 250 * 1024 * 1024,
    });
    const accepted = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "file",
      contentType: "application/octet-stream",
      fileName: "exactly-25mb.bin",
      byteSize: MEDIA_BYTES,
      sha256: "00".repeat(32),
      uploadProtocol: "parts_v2",
    });
    expect(accepted.totalParts).toBe(50);

    for (const byteSize of [MEDIA_BYTES + 1, 100 * 1024 * 1024]) {
      await expect(createMediaUpload(db, alice.accountId, alice.deviceId, {
        kind: "file",
        contentType: "application/octet-stream",
        byteSize,
        sha256: "11".repeat(32),
        uploadProtocol: "parts_v2",
      })).rejects.toMatchObject({ status: 413, code: "media_too_large" });
    }

    process.env.TOJ_MEDIA_MAX_OBJECT_BYTES = String(MEDIA_BYTES + 1);
    expect(() => mediaLimits()).toThrow("TOJ_MEDIA_MAX_OBJECT_BYTES");
    process.env.TOJ_MEDIA_MAX_OBJECT_BYTES = String(100 * 1024 * 1024);
    expect(() => mediaLimits()).toThrow("TOJ_MEDIA_MAX_OBJECT_BYTES");
    delete process.env.TOJ_MEDIA_MAX_OBJECT_BYTES;
    process.env.TOJ_MEDIA_ACCOUNT_QUOTA_BYTES = String(250 * 1024 * 1024 + 1);
    expect(() => mediaLimits()).toThrow("TOJ_MEDIA_ACCOUNT_QUOTA_BYTES");
  });

  test("scheduled pages decrypt in order with exactly three queries from one through 100 rows", async () => {
    const { alice, dialogId } = await pair();
    await db`INSERT INTO account_scheduled_delivery_states(account_id, revision)
      VALUES (${alice.accountId}, 100)`;
    const baseTime = Date.now() + 3_600_000;
    await db.begin(async (tx) => {
      for (let deliveryIndex = 0; deliveryIndex < 100; deliveryIndex += 1) {
        const deliveryId = crypto.randomUUID();
        const deliverAt = new Date(baseTime + deliveryIndex * 1_000);
        await tx`
          INSERT INTO scheduled_deliveries(
            id, account_id, origin_device_id, dialog_id, deliver_at, available_at, revision
          ) VALUES (
            ${deliveryId}, ${alice.accountId}, ${alice.deviceId}, ${dialogId},
            ${deliverAt}, ${deliverAt}, ${deliveryIndex + 1}
          )`;
        for (let itemIndex = 0; itemIndex < 3; itemIndex += 1) {
          const clientMsgId = crypto.randomUUID();
          const payload = seal(JSON.stringify({
            body: `delivery-${deliveryIndex}-item-${itemIndex}`,
            replyToMsgId: null,
            mentions: [],
            linkPreviewCandidate: null,
          }), scheduledItemAAD(alice.accountId, deliveryId, itemIndex, clientMsgId));
          await tx`
            INSERT INTO scheduled_delivery_items(
              delivery_id, item_index, client_msg_id, kind,
              payload_key_id, payload_nonce, payload_ciphertext
            ) VALUES (
              ${deliveryId}, ${itemIndex}, ${clientMsgId}, 'text',
              ${payload.keyId}, ${payload.nonce}, ${payload.ciphertext}
            )`;
        }
      }
    });

    const oneQuery = countedSql(db);
    const one = await listScheduledDeliveries(oneQuery.sql, alice.accountId, { limit: 1 });
    expect(one.deliveries).toHaveLength(1);
    expect(one.deliveries[0].items.map((item) => item.body)).toEqual([
      "delivery-0-item-0", "delivery-0-item-1", "delivery-0-item-2",
    ]);
    expect(oneQuery.count()).toBe(3);

    const hundredQuery = countedSql(db);
    const hundred = await listScheduledDeliveries(hundredQuery.sql, alice.accountId, { limit: 100 });
    expect(hundred.deliveries).toHaveLength(100);
    expect(hundred.deliveries.map((delivery) => delivery.items[0].body)).toEqual(
      Array.from({ length: 100 }, (_, index) => `delivery-${index}-item-0`),
    );
    expect(hundred.deliveries.every((delivery) => delivery.items.length === 3)).toBe(true);
    expect(hundredQuery.count()).toBe(oneQuery.count());
  });

  test("productivity readiness rejects a valid but incorrectly defined fanout index", async () => {
    await db`DROP INDEX IF EXISTS link_preview_cache_fanout_pending_idx`;
    try {
      await db`
        CREATE INDEX link_preview_cache_fanout_pending_idx
        ON link_preview_cache_entries(updated_at)
        WHERE NOT fanout_pending`;
      clearCloudProductivityReadinessCache(db);
      const state = await cloudProductivitySchemaState(db, { bypassCache: true });
      expect(state.ready).toBe(false);
      expect(state.missingIndexes).toContain("link_preview_cache_fanout_pending_idx");
    } finally {
      await db`DROP INDEX IF EXISTS link_preview_cache_fanout_pending_idx`;
      await db`
        CREATE INDEX link_preview_cache_fanout_pending_idx
        ON link_preview_cache_entries(updated_at, url_lookup_hmac)
        WHERE fanout_pending`;
      clearCloudProductivityReadinessCache(db);
    }
    expect((await cloudProductivitySchemaState(db, { bypassCache: true })).ready).toBe(true);
  });

  test("preview fanout is restart-safe, processes 25 rows per transaction, and discards stale edits", async () => {
    const { alice, dialogId } = await pair();
    const lookup = Buffer.alloc(32, 0x7a);
    const snapshotId = crypto.randomUUID();
    const nonce = Buffer.alloc(12, 0x01);
    await db.begin(async (tx) => {
      await tx`UPDATE dialogs SET last_msg_id = 200 WHERE id = ${dialogId}`;
      await tx`
        INSERT INTO messages(
          dialog_id, msg_id, sender_account_id, client_msg_id, kind,
          body_key_id, body_nonce, body_ciphertext, edit_version
        )
        SELECT ${dialogId}, ordinal, ${alice.accountId}, gen_random_uuid(), 'text',
               'fanout-test', decode(repeat('01', 12), 'hex'), decode('01', 'hex'),
               CASE WHEN ordinal > 190 THEN 1 ELSE 0 END
        FROM generate_series(1, 200) ordinal`;
      await tx`
        INSERT INTO link_preview_snapshots(
          id, url_key_id, url_nonce, url_ciphertext,
          metadata_key_id, metadata_nonce, metadata_ciphertext, expires_at
        ) VALUES (
          ${snapshotId}, 'fanout-test', ${nonce}, ${Buffer.from([1])},
          'fanout-test', ${nonce}, ${Buffer.from([1])}, now() + interval '1 day'
        )`;
      await tx`
        INSERT INTO link_preview_cache_entries(
          url_lookup_hmac, url_key_id, url_nonce, url_ciphertext, state,
          current_snapshot_id, fetched_at, expires_at, fanout_pending
        ) VALUES (
          ${lookup}, 'fanout-test', ${nonce}, ${Buffer.from([1])}, 'ready',
          ${snapshotId}, now(), now() + interval '1 day', TRUE
        )`;
      await tx`
        INSERT INTO message_link_previews(
          dialog_id, msg_id, generation, expected_edit_version, url_lookup_hmac,
          original_url_key_id, original_url_nonce, original_url_ciphertext, state
        )
        SELECT ${dialogId}, ordinal, 1, 0, ${lookup},
               'fanout-test', ${nonce}, ${Buffer.from([1])}, 'pending'
        FROM generate_series(1, 200) ordinal`;
      await tx`
        INSERT INTO link_preview_waiters(
          url_lookup_hmac, dialog_id, msg_id, expected_edit_version, generation
        )
        SELECT ${lookup}, ${dialogId}, ordinal, 0, 1
        FROM generate_series(1, 200) ordinal`;
    });

    let transactions = 0;
    const instrumented = new Proxy(db, {
      apply(target, thisArg, args) {
        return Reflect.apply(target, thisArg, args);
      },
      get(target, property, receiver) {
        if (property === "begin") {
          return async (body: (tx: SQL) => Promise<unknown>) => {
            transactions += 1;
            return await target.begin(body);
          };
        }
        const value = Reflect.get(target, property, receiver);
        return typeof value === "function" ? value.bind(target) : value;
      },
    }) as SQL;

    expect(await drainLinkPreviewFanout(instrumented, 100)).toBe(100);
    expect(transactions).toBe(4);
    expect(Number((await db`SELECT count(*) AS count FROM link_preview_waiters`)[0].count)).toBe(100);
    expect((await db`SELECT fanout_pending FROM link_preview_cache_entries
      WHERE url_lookup_hmac = ${lookup}`)[0].fanout_pending).toBe(true);

    // This second call represents process restart after the first bounded tick committed.
    transactions = 0;
    expect(await drainLinkPreviewFanout(instrumented, 100)).toBe(100);
    expect(transactions).toBe(4);
    expect(await drainLinkPreviewFanout(instrumented, 100)).toBe(0);
    expect(Number((await db`SELECT count(*) AS count FROM link_preview_waiters`)[0].count)).toBe(0);
    expect((await db`SELECT fanout_pending FROM link_preview_cache_entries
      WHERE url_lookup_hmac = ${lookup}`)[0].fanout_pending).toBe(false);
    expect(Number((await db`
      SELECT count(*) AS count FROM message_link_previews WHERE state = 'ready'`)[0].count)).toBe(190);
    expect(Number((await db`
      SELECT count(*) AS count FROM message_link_previews WHERE state = 'pending'`)[0].count)).toBe(0);
    const eventCounts = await db`
      SELECT account_id, msg_id, count(*)::int AS count
      FROM account_events WHERE type = 'message.preview_updated'
      GROUP BY account_id, msg_id`;
    expect(eventCounts).toHaveLength(380);
    expect(eventCounts.every((row: any) => Number(row.count) === 1)).toBe(true);
  });

  test("scheduled claims fill only open slots, renew leases, and fence superseded tokens", async () => {
    const { alice, dialogId } = await pair();
    const scheduleIds: string[] = [];
    for (let index = 0; index < 6; index += 1) {
      const scheduleId = crypto.randomUUID();
      scheduleIds.push(scheduleId);
      await createScheduledDelivery(db, {
        accountId: alice.accountId,
        deviceId: alice.deviceId,
        body: {
          scheduleId,
          clientMutationId: crypto.randomUUID(),
          dialogId,
          deliverAt: new Date(Date.now() + 61_000).toISOString(),
          items: [{
            clientMsgId: crypto.randomUUID(),
            kind: "text",
            body: `bounded-${index}`,
          }],
        },
      });
    }
    await db`
      UPDATE scheduled_deliveries SET deliver_at = now(), available_at = now()
      WHERE id IN ${db(scheduleIds)}`;

    const blocked = blockedScheduledDispatchSql(db);
    const firstTick = drainScheduledDeliveries(blocked.sql, 100, {
      concurrency: 3,
      leaseSeconds: 30,
      renewEveryMilliseconds: 1_000,
    });
    await waitUntil(() => blocked.active() === 3, "three scheduled jobs did not start");
    expect(blocked.maximumActive()).toBe(3);
    expect((await db`
      SELECT state, count(*)::int AS count FROM scheduled_deliveries GROUP BY state
      ORDER BY state`).map((row: any) => [row.state, Number(row.count)])).toEqual([
      ["processing", 3], ["scheduled", 3],
    ]);
    const initialExpiry = new Date((await db`
      SELECT min(lease_expires_at) AS value FROM scheduled_deliveries
      WHERE state = 'processing'`)[0].value).getTime();
    await Bun.sleep(1_200);
    const renewedExpiry = new Date((await db`
      SELECT min(lease_expires_at) AS value FROM scheduled_deliveries
      WHERE state = 'processing'`)[0].value).getTime();
    expect(renewedExpiry).toBeGreaterThan(initialExpiry);
    blocked.release();
    expect(await firstTick).toBe(3);
    expect(await drainScheduledDeliveries(db, 100, { concurrency: 3 })).toBe(3);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages WHERE dialog_id = ${dialogId} AND kind = 'text'`)[0].count))
      .toBe(6);

    const fencedScheduleId = crypto.randomUUID();
    await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId: fencedScheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{
          clientMsgId: crypto.randomUUID(),
          kind: "text",
          body: "token-fenced",
        }],
      },
    });
    await db`
      UPDATE scheduled_deliveries SET deliver_at = now(), available_at = now()
      WHERE id = ${fencedScheduleId}`;
    const fenced = blockedScheduledDispatchSql(db);
    const oldOwner = drainScheduledDeliveries(fenced.sql, 1, {
      concurrency: 1,
      leaseSeconds: 30,
      renewEveryMilliseconds: 1_000,
    });
    await waitUntil(() => fenced.active() === 1, "fenced scheduled job did not start");
    const replacementToken = crypto.randomUUID();
    await db`
      UPDATE scheduled_deliveries SET lease_token = ${replacementToken},
        lease_expires_at = now() + interval '30 seconds'
      WHERE id = ${fencedScheduleId}`;
    fenced.release();
    expect(await oldOwner).toBe(1);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages
      WHERE dialog_id = ${dialogId} AND kind = 'text'`)[0].count)).toBe(6);
    expect((await db`
      SELECT state, lease_token FROM scheduled_deliveries WHERE id = ${fencedScheduleId}`)[0])
      .toEqual(expect.objectContaining({ state: "processing", lease_token: replacementToken }));

    await db`
      UPDATE scheduled_deliveries SET lease_expires_at = now() - interval '1 second'
      WHERE id = ${fencedScheduleId}`;
    expect(await drainScheduledDeliveries(db, 1, { concurrency: 1 })).toBe(1);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages
      WHERE dialog_id = ${dialogId} AND kind = 'text'`)[0].count)).toBe(7);
    expect((await db`
      SELECT state FROM scheduled_deliveries WHERE id = ${fencedScheduleId}`)[0].state)
      .toBe("delivered");
  });

  test("scheduled completion follows mutation lock order while cancellation races", async () => {
    const { alice, dialogId } = await pair();
    const scheduleId = crypto.randomUUID();
    const created = await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{
          clientMsgId: crypto.randomUUID(),
          kind: "text",
          body: "completion-cancel-lock-order",
        }],
      },
    });
    await db`
      UPDATE scheduled_deliveries SET deliver_at = now(), available_at = now()
      WHERE id = ${scheduleId}`;

    const paused = pausedScheduledCompletionSql(db);
    const worker = drainScheduledDeliveries(paused.sql, 1, { concurrency: 1 });
    await waitUntil(
      () => paused.ownsDeliveryRow(),
      "scheduled completion did not acquire its delivery row",
    );
    const observedOwnershipOrder = {
      followed: paused.ownershipFollowedAccountLock(),
      queries: paused.ownershipTransactionQueries(),
    };
    const cancellation = cancelScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      deliveryId: scheduleId,
      body: {
        clientMutationId: crypto.randomUUID(),
        expectedRevision: created.scheduledDelivery.revision,
      },
    });
    await Bun.sleep(50);
    paused.release();

    const settled = await Promise.race([
      Promise.allSettled([worker, cancellation]),
      Bun.sleep(5_000).then(() => { throw new Error("scheduled cancellation race stalled"); }),
    ]);
    expect(observedOwnershipOrder).toEqual(expect.objectContaining({ followed: true }));
    expect(settled[0]).toEqual(expect.objectContaining({ status: "fulfilled", value: 1 }));
    expect(settled[1].status).toBe("rejected");
    if (settled[1].status === "rejected") {
      expect(["already_delivered", "schedule_processing"])
        .toContain(settled[1].reason?.code);
    }
    expect((await db`
      SELECT state FROM scheduled_deliveries WHERE id = ${scheduleId}`)[0].state)
      .toBe("delivered");
  }, 15_000);

  test("scheduled worker shutdown stops new claims and drains active work", async () => {
    const { alice, dialogId } = await pair();
    const scheduleIds: string[] = [];
    for (let index = 0; index < 2; index += 1) {
      const scheduleId = crypto.randomUUID();
      scheduleIds.push(scheduleId);
      await createScheduledDelivery(db, {
        accountId: alice.accountId,
        deviceId: alice.deviceId,
        body: {
          scheduleId,
          clientMutationId: crypto.randomUUID(),
          dialogId,
          deliverAt: new Date(Date.now() + 61_000).toISOString(),
          items: [{
            clientMsgId: crypto.randomUUID(),
            kind: "text",
            body: `shutdown-${index}`,
          }],
        },
      });
    }
    await db`
      UPDATE scheduled_deliveries SET deliver_at = now(), available_at = now()
      WHERE id IN ${db(scheduleIds)}`;

    const blocked = blockedScheduledDispatchSql(db);
    const stop = startScheduledDeliveryWorker(blocked.sql, {
      concurrency: 1,
      pollMilliseconds: 250,
      heartbeatMilliseconds: 1_000,
      shutdownDrainMilliseconds: 2_000,
    });
    await waitUntil(() => blocked.active() === 1, "scheduled worker did not start its active job");
    const stopping = stop();
    blocked.release();
    await stopping;

    expect((await db`
      SELECT state, count(*)::int AS count
      FROM scheduled_deliveries GROUP BY state ORDER BY state`
    ).map((row: any) => [row.state, Number(row.count)])).toEqual([
      ["delivered", 1],
      ["scheduled", 1],
    ]);
  });

  test("worker settings are bounded and unrelated authenticated paths perform no health query", async () => {
    delete process.env.TOJ_AUTH_SESSIONS_V2_ENABLED;
    delete process.env.TOJ_TWO_FACTOR_ENABLED;
    delete process.env.TOJ_PINNED_MESSAGES_ENABLED;
    delete process.env.TOJ_AUTO_DELETE_ENABLED;
    delete process.env.TOJ_POLLS_ENABLED;
    delete process.env.TOJ_STICKER_PACKS_ENABLED;
    delete process.env.TOJ_GIPHY_ENABLED;
    delete process.env.TOJ_MULTI_ACCOUNT_PUSH_ENABLED;
    expect(scheduledDeliveryWorkerConcurrency()).toBe(8);
    expect(linkPreviewWorkerConcurrency()).toBe(4);
    expect(productivityWorkerLeaseSeconds()).toBe(120);
    process.env.TOJ_SCHEDULED_DELIVERY_WORKER_CONCURRENCY = "33";
    expect(() => scheduledDeliveryWorkerConcurrency()).toThrow("1 through 32");
    delete process.env.TOJ_SCHEDULED_DELIVERY_WORKER_CONCURRENCY;
    process.env.TOJ_LINK_PREVIEW_WORKER_CONCURRENCY = "0";
    expect(() => linkPreviewWorkerConcurrency()).toThrow("1 through 16");
    delete process.env.TOJ_LINK_PREVIEW_WORKER_CONCURRENCY;
    process.env.TOJ_PRODUCTIVITY_WORKER_LEASE_SECONDS = "29";
    expect(() => productivityWorkerLeaseSeconds()).toThrow("30 through 600");
    delete process.env.TOJ_PRODUCTIVITY_WORKER_LEASE_SECONDS;

    expect(productivityNeedsForPath("/v1/profile")).toEqual({
      schema: false, scheduledWorker: false, previewWorker: false,
    });
    expect(productivityNeedsForPath("/v1/media/uploads").schema).toBe(false);
    expect(productivityNeedsForPath("/v1/calls/active").schema).toBe(false);
    expect(productivityNeedsForPath("/v1/sync/difference")).toEqual({
      schema: true, scheduledWorker: true, previewWorker: true,
    });

    const alice = await account("+16505554804", "Health");
    process.env.TOJ_SCHEDULED_DELIVERY_V1_ENABLED = "1";
    process.env.TOJ_SCHEDULED_DELIVERY_ALLOWLIST = alice.accountId;
    process.env.TOJ_LINK_PREVIEWS_V1_ENABLED = "1";
    process.env.TOJ_LINK_PREVIEWS_ALLOWLIST = alice.accountId;
    await db`
      INSERT INTO worker_heartbeats(worker_kind, worker_id, last_seen_at)
      VALUES ('scheduled_delivery', gen_random_uuid(), now()),
             ('link_preview', gen_random_uuid(), now())`;

    let heartbeatQueries = 0;
    let productivitySchemaQueries = 0;
    let v2AuthenticationQueries = 0;
    let messagingSchemaQueries = 0;
    const counted = countedSql(db, (query) => {
      if (query.includes("FROM worker_heartbeats")) heartbeatQueries += 1;
      if (query.includes("cloud_productivity_required_tables")) productivitySchemaQueries += 1;
      if (query.includes("FROM session_access_tokens")) v2AuthenticationQueries += 1;
      if (query.includes("messaging_feature_required_tables")) messagingSchemaQueries += 1;
    });
    clearCloudProductivityReadinessCache(counted.sql);
    clearWorkerHeartbeatCache(counted.sql);
    const server = startCloudServer(0, counted.sql, null, null, { backgroundWorkers: false });
    try {
      const headers = { authorization: `Bearer ${alice.token}` };
      const capabilities = await Promise.all(Array.from({ length: 20 }, () =>
        fetch(`http://127.0.0.1:${server.port}/v1/capabilities`, { headers })
          .then((response) => response.json())
      ));
      expect(capabilities.every((body: any) =>
        body.capabilities.includes("scheduled_delivery_v1")
        && body.capabilities.includes("link_previews_v1")
        && !body.capabilities.includes("two_factor_v1")
      )).toBe(true);
      expect(heartbeatQueries).toBe(1);
      expect(productivitySchemaQueries).toBe(1);
      expect(v2AuthenticationQueries).toBe(0);
      expect(messagingSchemaQueries).toBe(1);

      heartbeatQueries = 0;
      const profile = await fetch(`http://127.0.0.1:${server.port}/v1/profile`, { headers });
      expect(profile.status).toBe(200);
      expect(heartbeatQueries).toBe(0);

      const bob = await account("+16505554805", "Health Peer");
      const direct = await getOrCreateDirectDialog(
        db,
        alice.accountId,
        bob.accountId,
        alice.deviceId,
      );
      messagingSchemaQueries = 0;
      clearMessagingFeatureReadinessCache(counted.sql);
      const sent = await fetch(`http://127.0.0.1:${server.port}/v1/messages/send`, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({
          dialogId: direct.dialogId,
          clientMsgId: crypto.randomUUID(),
          kind: "text",
          body: "Dark features must stay off the hot path",
        }),
      });
      expect(sent.status).toBe(200);
      expect(messagingSchemaQueries).toBe(0);

      await db`UPDATE worker_heartbeats SET last_seen_at = now() - interval '31 seconds'`;
      clearWorkerHeartbeatCache(counted.sql);
      const stale = await fetch(`http://127.0.0.1:${server.port}/v1/capabilities`, { headers })
        .then((response) => response.json() as Promise<{ capabilities: string[] }>);
      expect(stale.capabilities).not.toContain("scheduled_delivery_v1");
      expect(stale.capabilities).not.toContain("link_previews_v1");
    } finally {
      await server.stop(true);
    }

    let failures = 0;
    const failing = new Proxy((() => {
      failures += 1;
      throw new Error("database unavailable");
    }) as unknown as SQL, {
      get(_target, property) {
        if (property === "array") return db.array.bind(db);
        return undefined;
      },
    }) as SQL;
    clearWorkerHeartbeatCache(failing);
    const closed = await Promise.all(Array.from({ length: 10 }, () =>
      workerHeartbeatFresh(failing, "scheduled_delivery")
    ));
    expect(closed.every((value) => value === false)).toBe(true);
    expect(failures).toBe(1);
  });
});
