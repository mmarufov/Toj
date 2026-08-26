import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import { blockAccount, revokeDeviceAndTerminateCalls } from "./calls";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { hashToken } from "./crypto";
import { createGroup, removeGroupMember } from "./groups";
import {
  expirePresenceLeases,
  heartbeatPresence,
  nextPresenceConnectionEpoch,
  presenceEnabledForAccount,
  presenceSchemaReadiness,
  publishTyping,
  queryPresence,
  revokeAccountPresence,
  setPresenceActivity,
  startPresenceNotificationListener,
} from "./presence";
import { getOrCreateDirectDialog } from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  process.env.TOJ_PRESENCE_V1_ENABLED = "1";
  process.env.TOJ_PRESENCE_ROLLOUT_PERCENT = "100";
  delete process.env.TOJ_PRESENCE_ALLOWLIST;
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function directPair() {
  const alice = await account("+16505559801", "Alice");
  const bob = await account("+16505559802", "Bob");
  const dialog = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId, alice.deviceId);
  return { alice, bob, dialogId: dialog.dialogId };
}

describe.serial("presence_v1", () => {
  beforeEach(resetDb);
  afterAll(() => db.end());

  test("schema and deterministic rollout fail closed", async () => {
    expect((await presenceSchemaReadiness(db)).ready).toBe(true);
    const user = await account("+16505559800", "Rollout");
    expect(presenceEnabledForAccount(user.accountId)).toBe(true);
    process.env.TOJ_PRESENCE_ROLLOUT_PERCENT = "0";
    expect(presenceEnabledForAccount(user.accountId)).toBe(false);
    process.env.TOJ_PRESENCE_ALLOWLIST = user.accountId;
    expect(presenceEnabledForAccount(user.accountId)).toBe(true);
  });

  test("query fails closed when rollout is enabled before the presence schema", async () => {
    const missingSchema = (async () => [{}]) as unknown as typeof db;
    await expect(queryPresence(missingSchema, crypto.randomUUID(), []))
      .rejects.toMatchObject({ status: 404, code: "capability_unavailable" });
  });

  test("capability and query endpoint are authenticated, gated, and bounded", async () => {
    const { alice, bob } = await directPair();
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    const base = `http://127.0.0.1:${server.port}`;
    try {
      const publicCapabilities = await (await fetch(`${base}/v1/capabilities`)).json() as {
        capabilities: string[];
      };
      expect(publicCapabilities.capabilities).not.toContain("presence_v1");
      const accountCapabilities = await (await fetch(`${base}/v1/capabilities`, {
        headers: { authorization: `Bearer ${bob.token}` },
      })).json() as { capabilities: string[] };
      expect(accountCapabilities.capabilities).toContain("presence_v1");
      expect((await fetch(`${base}/v1/presence/query`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ accountIds: [alice.accountId] }),
      })).status).toBe(401);
      expect((await fetch(`${base}/v1/presence/query`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${bob.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ accountIds: "not-an-array" }),
      })).status).toBe(400);
      const tooMany = Array.from({ length: 201 }, () => crypto.randomUUID());
      expect((await fetch(`${base}/v1/presence/query`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${bob.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ accountIds: tooMany }),
      })).status).toBe(413);
    } finally {
      await server.stop(true);
    }
  });

  test("realtime frames are bounded, rate-limited, and identity comes from the socket", async () => {
    const { alice, bob, dialogId } = await directPair();
    const previousMetricsToken = process.env.TOJ_METRICS_TOKEN;
    process.env.TOJ_METRICS_TOKEN = "presence-test-metrics";
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    const aliceSocket = new WebSocket(`ws://127.0.0.1:${server.port}/v1/ws`, {
      headers: { authorization: `Bearer ${alice.token}` },
    });
    const bobSocket = new WebSocket(`ws://127.0.0.1:${server.port}/v1/ws`, {
      headers: { authorization: `Bearer ${bob.token}` },
    });
    const bobEvents: any[] = [];
    bobSocket.onmessage = (message) => {
      try { bobEvents.push(JSON.parse(String(message.data))); } catch {}
    };
    const opened = (socket: WebSocket) => new Promise<void>((resolve, reject) => {
      if (socket.readyState === WebSocket.OPEN) return resolve();
      const timer = setTimeout(() => reject(new Error("websocket open timed out")), 3_000);
      socket.onopen = () => { clearTimeout(timer); resolve(); };
      socket.onerror = () => { clearTimeout(timer); reject(new Error("websocket error")); };
    });
    try {
      await Promise.all([opened(aliceSocket), opened(bobSocket)]);
      aliceSocket.send(JSON.stringify({ type: "presence_activity", active: true }));
      await Bun.sleep(50);
      const typing = JSON.stringify({ type: "typing_activity", dialogId, active: true });
      aliceSocket.send(typing);
      aliceSocket.send(typing);
      aliceSocket.send("{");
      aliceSocket.send(JSON.stringify({ type: "unsupported_activity" }));
      aliceSocket.send("x".repeat(4_097));
      await Bun.sleep(150);
      const typingEvents = bobEvents.filter((event) => event.type === "typing_update");
      expect(typingEvents).toHaveLength(1);
      expect(typingEvents[0]).toMatchObject({
        dialogId,
        actorAccountId: alice.accountId,
        active: true,
        expiresInMs: 7_000,
      });
      expect(typingEvents[0].typingSessionId).not.toBe(alice.accountId);
      const metrics = await (await fetch(`http://127.0.0.1:${server.port}/metrics`, {
        headers: { authorization: "Bearer presence-test-metrics" },
      })).text();
      expect(metrics).toContain('toj_presence_rejected_frames_total{reason="rate_limited"} 1');
      expect(metrics).toContain('toj_presence_rejected_frames_total{reason="oversized"} 1');
    } finally {
      aliceSocket.close();
      bobSocket.close();
      await server.stop(true);
      if (previousMetricsToken === undefined) delete process.env.TOJ_METRICS_TOKEN;
      else process.env.TOJ_METRICS_TOKEN = previousMetricsToken;
    }
  }, 5_000);

  test("revocation on one node closes the matching socket on another node", async () => {
    const { alice } = await directPair();
    const previousNotificationURL = process.env.TOJ_CALL_NOTIFY_DATABASE_URL;
    process.env.TOJ_CALL_NOTIFY_DATABASE_URL = TEST_URL;
    const socketNode = startCloudServer(0, db, null, null, { backgroundWorkers: true });
    const revokeNode = startCloudServer(0, db, null, null, { backgroundWorkers: true });
    const socket = new WebSocket(`ws://127.0.0.1:${socketNode.port}/v1/ws`, {
      headers: { authorization: `Bearer ${alice.token}` },
    });
    const opened = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("websocket open timed out")), 3_000);
      socket.onopen = () => { clearTimeout(timer); resolve(); };
      socket.onerror = () => { clearTimeout(timer); reject(new Error("websocket error")); };
    });
    const events: any[] = [];
    socket.onmessage = (message) => {
      try { events.push(JSON.parse(String(message.data))); } catch {}
    };
    const closed = new Promise<CloseEvent>((resolve) => {
      socket.onclose = resolve;
    });
    try {
      await opened;
      // Let both LISTEN connections reach readiness before committing the revocation.
      await Bun.sleep(150);
      const response = await fetch(`http://127.0.0.1:${revokeNode.port}/v1/session`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${alice.token}` },
      });
      expect(response.status).toBe(200);
      await response.json();
      const close = await Promise.race([
        closed,
        Bun.sleep(3_000).then(() => { throw new Error("remote revocation close timed out"); }),
      ]);
      expect(close.code).toBe(4001);
      expect(events).toContainEqual(expect.objectContaining({
        type: "session_revoked",
        deviceId: alice.deviceId,
        reason: "device_revoked",
      }));
    } finally {
      socket.close();
      const stopping = Promise.all([socketNode.stop(true), revokeNode.stop(true)]);
      // Bun 1.3.11 can leave stop(true) pending after a server-initiated WebSocket close even
      // though the close event has fired and the port has stopped accepting connections.
      await Promise.race([stopping, Bun.sleep(1_000)]);
      if (previousNotificationURL === undefined) delete process.env.TOJ_CALL_NOTIFY_DATABASE_URL;
      else process.env.TOJ_CALL_NOTIFY_DATABASE_URL = previousNotificationURL;
    }
  }, 8_000);

  test("same-node revocation sends the sticky control frame before closing", async () => {
    const { alice } = await directPair();
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    const socket = new WebSocket(`ws://127.0.0.1:${server.port}/v1/ws`, {
      headers: { authorization: `Bearer ${alice.token}` },
    });
    const opened = new Promise<void>((resolve, reject) => {
      socket.onopen = () => resolve();
      socket.onerror = () => reject(new Error("websocket error"));
    });
    let resolveRevocation!: (value: any) => void;
    const revocation = new Promise<any>((resolve) => { resolveRevocation = resolve; });
    socket.onmessage = (message) => {
      try {
        const value = JSON.parse(String(message.data));
        if (value.type === "session_revoked") resolveRevocation(value);
      } catch {}
    };
    const closed = new Promise<CloseEvent>((resolve) => { socket.onclose = resolve; });
    try {
      await opened;
      const response = await fetch(`http://127.0.0.1:${server.port}/v1/session`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${alice.token}` },
      });
      expect(response.status).toBe(200);
      expect(await Promise.race([
        revocation,
        Bun.sleep(2_000).then(() => { throw new Error("revocation frame timed out"); }),
      ])).toMatchObject({
        type: "session_revoked", deviceId: alice.deviceId, reason: "device_revoked",
      });
      expect((await closed).code).toBe(4001);
    } finally {
      socket.close();
      await Promise.race([server.stop(true), Bun.sleep(1_000)]);
    }
  }, 5_000);

  test("credential audit closes a revoked socket after a missed notification", async () => {
    const { alice } = await directPair();
    const server = startCloudServer(0, db, null, null, {
      backgroundWorkers: true,
      socketAuthorizationIntervalMs: 250,
    });
    const socket = new WebSocket(`ws://127.0.0.1:${server.port}/v1/ws`, {
      headers: { authorization: `Bearer ${alice.token}` },
    });
    const opened = new Promise<void>((resolve, reject) => {
      socket.onopen = () => resolve();
      socket.onerror = () => reject(new Error("websocket error"));
    });
    const events: any[] = [];
    socket.onmessage = (message) => {
      try { events.push(JSON.parse(String(message.data))); } catch {}
    };
    const closed = new Promise<CloseEvent>((resolve) => { socket.onclose = resolve; });
    try {
      await opened;
      // Deliberately bypass both revocation notification channels. The periodic database
      // reconciliation must still distinguish a revoked device from a disabled account and
      // deliver the terminal control event before closing the transport.
      await db`
        UPDATE devices
        SET revoked_at = now()
        WHERE id = ${alice.deviceId} AND account_id = ${alice.accountId}`;
      const close = await Promise.race([
        closed,
        Bun.sleep(3_000).then(() => { throw new Error("authorization audit timed out"); }),
      ]);
      expect(close.code).toBe(4001);
      expect(events).toContainEqual(expect.objectContaining({
        type: "session_revoked", deviceId: alice.deviceId,
      }));
    } finally {
      socket.close();
      await Promise.race([server.stop(true), Bun.sleep(1_000)]);
    }
  }, 6_000);

  test("only direct peers receive exact online and final-device last seen", async () => {
    const { alice, bob } = await directPair();
    const outsider = await account("+16505559803", "Outsider");
    const firstConnection = crypto.randomUUID();
    const broadcasts = await setPresenceActivity(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      connectionId: firstConnection,
      active: true,
    });
    expect(broadcasts[0]?.recipientAccountIds).toEqual([bob.accountId]);
    expect(await queryPresence(db, bob.accountId, [alice.accountId, outsider.accountId]))
      .toEqual({ presences: [expect.objectContaining({ accountId: alice.accountId, online: true })] });

    const second = (await db`
      INSERT INTO devices(account_id, platform, device_name, auth_token_hash)
      VALUES (${alice.accountId}, 'ios', 'Alice iPad', ${hashToken(crypto.randomUUID())})
      RETURNING id`)[0];
    const secondConnection = crypto.randomUUID();
    expect(await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: String(second.id),
      connectionId: secondConnection, active: true,
    })).toEqual([]);
    expect(await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: firstConnection, active: false,
    })).toEqual([]);
    const offline = await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: String(second.id),
      connectionId: secondConnection, active: false,
    });
    expect(offline[0]?.event).toEqual(expect.objectContaining({
      type: "presence_update", accountId: alice.accountId, online: false,
    }));
    const snapshot = (await queryPresence(db, bob.accountId, [alice.accountId])).presences[0];
    expect(snapshot.online).toBe(false);
    expect(snapshot.lastSeenAt).not.toBeNull();
    expect(snapshot.revision).toBe(2);
  });

  test("a stale socket close cannot deactivate its replacement", async () => {
    const { alice, bob } = await directPair();
    const oldConnection = crypto.randomUUID();
    const newConnection = crypto.randomUUID();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: oldConnection, active: true,
    });
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: newConnection, active: true,
    });
    expect(await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: oldConnection, active: false,
    })).toEqual([]);
    expect((await queryPresence(db, bob.accountId, [alice.accountId])).presences[0].online)
      .toBe(true);
  });

  test("a superseded socket cannot reclaim the newer connection lease", async () => {
    const { alice, bob } = await directPair();
    const oldConnection = crypto.randomUUID();
    const newConnection = crypto.randomUUID();
    const oldEpoch = await nextPresenceConnectionEpoch(db);
    const newEpoch = await nextPresenceConnectionEpoch(db);
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: oldConnection, connectionEpoch: oldEpoch, active: true,
    });
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: newConnection, connectionEpoch: newEpoch, active: true,
    });
    await expect(setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: oldConnection, connectionEpoch: oldEpoch, active: true,
    })).rejects.toMatchObject({ code: "stale_presence_connection", status: 409 });
    expect(await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: oldConnection, connectionEpoch: oldEpoch, active: false,
    })).toEqual([]);
    expect((await queryPresence(db, bob.accountId, [alice.accountId])).presences[0].online)
      .toBe(true);
  });

  test("expired leases publish the last confirmed heartbeat and advance revision", async () => {
    const { alice, bob } = await directPair();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: crypto.randomUUID(), active: true,
    });
    const heartbeat = new Date(Date.now() - 90_000);
    await db`
      UPDATE device_presence_leases
      SET last_heartbeat_at = ${heartbeat}, expires_at = now() - interval '1 second'
      WHERE device_id = ${alice.deviceId}`;
    const broadcasts = await expirePresenceLeases(db);
    expect(broadcasts[0]?.recipientAccountIds).toEqual([bob.accountId]);
    const snapshot = (await queryPresence(db, bob.accountId, [alice.accountId])).presences[0];
    expect(snapshot.online).toBe(false);
    expect(new Date(snapshot.lastSeenAt!).getTime()).toBe(heartbeat.getTime());
    expect(snapshot.revision).toBe(2);
  });

  test("a heartbeat re-establishes a foreground socket whose lease expired", async () => {
    const { alice, bob } = await directPair();
    const connectionId = crypto.randomUUID();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, connectionId, active: true,
    });
    await db`
      UPDATE device_presence_leases
      SET last_heartbeat_at = now() - interval '2 seconds',
          expires_at = now() - interval '1 second'
      WHERE device_id = ${alice.deviceId}`;
    await expirePresenceLeases(db);
    const broadcasts = await heartbeatPresence(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, connectionId,
    });
    expect(broadcasts[0]?.event).toEqual(expect.objectContaining({
      type: "presence_update", online: true, revision: 3,
    }));
    expect((await queryPresence(db, bob.accountId, [alice.accountId])).presences[0].online)
      .toBe(true);
  });

  test("heartbeat revives an expired lease with an observable online revision", async () => {
    const { alice, bob } = await directPair();
    const connectionId = crypto.randomUUID();
    const connectionEpoch = await nextPresenceConnectionEpoch(db);
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId, connectionEpoch, active: true,
    });
    await db`
      UPDATE device_presence_leases
      SET last_heartbeat_at = now() - interval '2 seconds',
          expires_at = now() - interval '1 second'
      WHERE device_id = ${alice.deviceId}`;
    expect((await queryPresence(db, bob.accountId, [alice.accountId])).presences[0])
      .toMatchObject({ online: false, revision: 1 });
    const broadcasts = await heartbeatPresence(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId, connectionEpoch,
    });
    expect(broadcasts[0]?.event).toMatchObject({
      type: "presence_update", online: true, revision: 2,
    });
    expect((await queryPresence(db, bob.accountId, [alice.accountId])).presences[0])
      .toMatchObject({ online: true, revision: 2 });
  });

  test("device revocation atomically removes its lease and rejects stale activity", async () => {
    const { alice } = await directPair();
    const connectionId = crypto.randomUUID();
    await setPresenceActivity(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      connectionId,
      active: true,
    });

    const result = await revokeDeviceAndTerminateCalls(db, alice.accountId, alice.deviceId);
    expect(result.presenceBroadcasts[0]?.event).toEqual(expect.objectContaining({
      type: "presence_update",
      accountId: alice.accountId,
      online: false,
    }));
    const rows = await db`
      SELECT
        (SELECT count(*) FROM device_presence_leases
         WHERE account_id = ${alice.accountId}) AS leases,
        (SELECT last_seen_at IS NOT NULL FROM account_presence
         WHERE account_id = ${alice.accountId}) AS has_last_seen`;
    expect(Number(rows[0].leases)).toBe(0);
    expect(rows[0].has_last_seen).toBe(true);
    await expect(heartbeatPresence(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      connectionId,
    })).rejects.toMatchObject({ status: 401 });
    await expect(setPresenceActivity(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      connectionId,
      active: true,
    })).rejects.toMatchObject({ status: 401 });
  });

  test("account-private cleanup erases exact presence state for tombstoned accounts", async () => {
    const { alice } = await directPair();
    await setPresenceActivity(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      connectionId: crypto.randomUUID(),
      active: true,
    });
    await db`SELECT public.toj_cleanup_account_private_state_v1(${alice.accountId})`;
    const rows = await db`
      SELECT
        (SELECT count(*) FROM device_presence_leases
         WHERE account_id = ${alice.accountId}) AS leases,
        (SELECT count(*) FROM account_presence
         WHERE account_id = ${alice.accountId}) AS presence`;
    expect(Number(rows[0].leases)).toBe(0);
    expect(Number(rows[0].presence)).toBe(0);
  });

  test("account deletion publishes terminal offline and visibility revocation before erasure", async () => {
    const { alice, bob } = await directPair();
    await setPresenceActivity(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      connectionId: crypto.randomUUID(),
      active: true,
    });
    const broadcasts = await db.begin(async (tx) => {
      const terminal = await revokeAccountPresence(tx, alice.accountId);
      await tx`SELECT public.toj_cleanup_account_private_state_v1(${alice.accountId})`;
      return terminal;
    });
    expect(broadcasts).toContainEqual(expect.objectContaining({
      recipientAccountIds: [bob.accountId],
      event: expect.objectContaining({
        type: "presence_update", accountId: alice.accountId, online: false,
      }),
    }));
    expect(broadcasts).toContainEqual(expect.objectContaining({
      recipientAccountIds: [bob.accountId],
      event: {
        type: "presence_visibility", accountId: alice.accountId, visible: false,
      },
    }));
    expect(await db`
      SELECT account_id FROM account_presence WHERE account_id = ${alice.accountId}`)
      .toHaveLength(0);
  });

  test("PostgreSQL notifications deliver presence events across server processes", async () => {
    const { alice, bob } = await directPair();
    let resolveBroadcast: ((value: unknown) => void) | undefined;
    const received = new Promise<any>((resolve) => { resolveBroadcast = resolve; });
    const stop = startPresenceNotificationListener(TEST_URL, (broadcast) => {
      if (broadcast.recipientAccountIds.includes(bob.accountId)) resolveBroadcast?.(broadcast);
    });
    try {
      await Bun.sleep(100);
      await setPresenceActivity(db, {
        accountId: alice.accountId,
        deviceId: alice.deviceId,
        connectionId: crypto.randomUUID(),
        active: true,
      });
      const broadcast = await Promise.race([
        received,
        Bun.sleep(3_000).then(() => { throw new Error("presence notification timed out"); }),
      ]);
      expect(broadcast.event).toEqual(expect.objectContaining({
        type: "presence_update", accountId: alice.accountId, online: true,
      }));
    } finally {
      stop();
    }
  }, 5_000);

  test("blocking hides direct presence and direct typing in both directions", async () => {
    const { alice, bob, dialogId } = await directPair();
    const connectionId = crypto.randomUUID();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId, active: true,
    });
    await blockAccount(db, bob.accountId, alice.accountId);
    expect(await queryPresence(db, bob.accountId, [alice.accountId])).toEqual({ presences: [] });
    expect(await publishTyping(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, dialogId,
      typingSessionId: connectionId, active: true,
    })).toEqual([]);
  });

  test("group typing reaches current members and rejects removed members", async () => {
    const owner = await account("+16505554110", "Owner");
    const alice = await account("+16505554111", "Alice");
    const bob = await account("+16505554112", "Bob");
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "Presence",
      memberIds: [alice.accountId, bob.accountId],
    });
    const typingSessionId = crypto.randomUUID();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: typingSessionId, active: true,
    });
    const event = await publishTyping(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, dialogId: groupId,
      typingSessionId, active: true,
    });
    expect(event[0]?.recipientAccountIds.sort()).toEqual([bob.accountId, owner.accountId].sort());
    expect(event[0]?.event).toEqual(expect.objectContaining({
      type: "typing_update", actorAccountId: alice.accountId, expiresInMs: 7_000,
    }));
    await removeGroupMember(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      targetAccountId: alice.accountId,
      clientMutationId: crypto.randomUUID(),
    });
    expect(await publishTyping(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, dialogId: groupId,
      typingSessionId, active: true,
    })).toEqual([]);
  });
});
