import { beforeEach, describe, expect, test } from "bun:test";
import { Client } from "pg";
import { makeSql } from "./db";
import { checkVerification, revokeDevice, startAccountDeletion, startVerification } from "./auth";
import { hashToken, open, pushTokenAAD, voipPushTokenAAD } from "./crypto";
import { getHistory, getOrCreateDirectDialog, sendMessage } from "./sync";
import { lockAccountMutations } from "./locks";
import {
  acceptCall,
  blockAccount,
  cancelCall,
  cleanupCallData,
  calleeCommitmentV1,
  callerCommitmentV1,
  CallError,
  confirmCallKey,
  createCall,
  declineCall,
  deleteAccountAndTerminateCalls,
  endCall,
  getIceConfig,
  getActiveCalls,
  getCall,
  getCallEvents,
  processCallHistoryOutbox,
  recordCallTelemetry,
  resolveCallHintTargets,
  revokeDeviceAndTerminateCalls,
  revealCallKey,
  sendEncryptedCallEvent,
  videoCallsEnabledForAccount,
  voiceCallsConfigured,
  type CallCommitmentContextV1,
  type CallKeyMaterialV1,
} from "./calls";
import {
  buildAPNsHeaders,
  buildVoIPAPNsPayload,
  processVoIPPushBatch,
  registerVoIPPushToken,
  type APNsSendRequest,
  type APNsSendResult,
  type PushSender,
} from "./push";
import { startCloudServer } from "./cloud";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);
const lockObserver = makeSql(TEST_URL);

const bytes = (start: number): Buffer => Buffer.from(Array.from({ length: 32 }, (_, index) => start + index));

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function addDevice(accountId: string): Promise<string> {
  return (await db`
    INSERT INTO devices (account_id, platform, device_name, auth_token_hash)
    VALUES (${accountId}, 'ios', 'Second iPhone', ${hashToken(crypto.randomUUID())}) RETURNING id`)[0].id;
}

async function pair() {
  const alice = await account("+16505551100", "Alice");
  const bob = await account("+16505551101", "Bob");
  const { dialogId } = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
  await sendMessage(db, {
    senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
    clientMsgId: crypto.randomUUID(), body: "hello",
  });
  await sendMessage(db, {
    senderAccountId: bob.accountId, senderDeviceId: bob.deviceId, dialogId,
    clientMsgId: crypto.randomUUID(), body: "hello back",
  });
  return { alice, bob, dialogId };
}

async function waitForAdvisoryWaiters(minimum: number): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const count = Number((await lockObserver`
      SELECT count(*) AS count FROM pg_locks
      WHERE locktype = 'advisory' AND granted = false`)[0].count);
    if (count >= minimum) return;
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for ${minimum} advisory-lock waiters`);
}

function context(callId: string, dialogId: string, alice: any, bob: any): CallCommitmentContextV1 {
  return {
    callId, dialogId,
    callerAccountId: alice.accountId,
    callerDeviceId: alice.deviceId,
    calleeAccountId: bob.accountId,
    offeredProtocolVersions: [1],
    offeredMediaProfileVersions: [1],
  };
}

function contextWithMedia(
  callId: string,
  dialogId: string,
  alice: any,
  bob: any,
  offeredMediaProfileVersions: number[],
): CallCommitmentContextV1 {
  return { ...context(callId, dialogId, alice, bob), offeredMediaProfileVersions };
}

class StubSender implements PushSender {
  readonly requests: APNsSendRequest[] = [];
  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    return { status: 200, apnsId: crypto.randomUUID() };
  }
}

class PausingSender implements PushSender {
  readonly requests: APNsSendRequest[] = [];
  readonly started: Promise<void>;
  private readonly releasePromise: Promise<void>;
  private signalStarted!: () => void;
  private signalRelease!: () => void;

  constructor() {
    this.started = new Promise((resolve) => { this.signalStarted = resolve; });
    this.releasePromise = new Promise((resolve) => { this.signalRelease = resolve; });
  }

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    this.signalStarted();
    await this.releasePromise;
    return { status: 200, apnsId: crypto.randomUUID() };
  }

  release() { this.signalRelease(); }
}

class ConcurrentPausingSender implements PushSender {
  readonly requests: APNsSendRequest[] = [];
  readonly multipleStarted: Promise<void>;
  private readonly releasePromise: Promise<void>;
  private signalMultipleStarted!: () => void;
  private signalRelease!: () => void;

  constructor() {
    this.multipleStarted = new Promise((resolve) => { this.signalMultipleStarted = resolve; });
    this.releasePromise = new Promise((resolve) => { this.signalRelease = resolve; });
  }

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    if (this.requests.length >= 2) this.signalMultipleStarted();
    await this.releasePromise;
    return { status: 200, apnsId: crypto.randomUUID() };
  }

  release() { this.signalRelease(); }
}

describe("E2EE voice-call control plane", () => {
  beforeEach(resetDb);

  test("TypeScript commitment encoding matches the pinned Swift vector", () => {
    const vectorContext: CallCommitmentContextV1 = {
      callId: "00000000-0000-0000-0000-000000000001",
      dialogId: "00000000-0000-0000-0000-000000000002",
      callerAccountId: "alice",
      callerDeviceId: "alice-ios-1",
      calleeAccountId: "bob",
      offeredProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    };
    const caller: CallKeyMaterialV1 = {
      publicKey: Buffer.from("8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f", "hex"),
      nonce: bytes(64), fingerprint: bytes(96),
    };
    const callerCommitment = callerCommitmentV1(vectorContext, caller);
    expect(callerCommitment.toString("hex"))
      .toBe("72af3dc7b2dc7adc92b31af69f240bc4f280052f0f6828aa51d6f21fdaf78411");
    const callee: CallKeyMaterialV1 = {
      publicKey: Buffer.from("358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254", "hex"),
      nonce: bytes(128), fingerprint: bytes(160),
    };
    expect(calleeCommitmentV1(vectorContext, callerCommitment, "bob-ios-1", 1, 1, callee).toString("hex"))
      .toBe("8b077d9791a6db5e2eb6efdc9f4d53590bd281f50caf6dc51d667b9a2ca4bca0");
  });

  test("voice capability requires an explicit healthy TURN gate and APNs", () => {
    const saved = {
      enabled: process.env.TOJ_VOICE_CALLS_ENABLED,
      ready: process.env.TOJ_TURN_READY,
      urls: process.env.TOJ_TURN_URLS,
      secret: process.env.TOJ_TURN_SHARED_SECRET,
    };
    try {
      process.env.TOJ_VOICE_CALLS_ENABLED = "1";
      process.env.TOJ_TURN_URLS = "turn:turn.example.test:3478";
      process.env.TOJ_TURN_SHARED_SECRET = "test-secret";
      delete process.env.TOJ_TURN_READY;
      expect(voiceCallsConfigured(true)).toBe(false);
      process.env.TOJ_TURN_READY = "1";
      expect(voiceCallsConfigured(false)).toBe(false);
      expect(voiceCallsConfigured(true)).toBe(true);
      process.env.TOJ_TURN_URLS = "  ,  ";
      expect(voiceCallsConfigured(true)).toBe(false);
      process.env.TOJ_TURN_URLS = "turn:turn.example.test:3478";
      process.env.TOJ_TURN_SHARED_SECRET = "   ";
      expect(voiceCallsConfigured(true)).toBe(false);
    } finally {
      for (const [key, value] of Object.entries(saved)) {
        const environmentKey = {
          enabled: "TOJ_VOICE_CALLS_ENABLED", ready: "TOJ_TURN_READY",
          urls: "TOJ_TURN_URLS", secret: "TOJ_TURN_SHARED_SECRET",
        }[key]!;
        if (value === undefined) delete process.env[environmentKey];
        else process.env[environmentKey] = value;
      }
    }
  });

  test("video rollout is readiness-gated, deterministic, allowlistable, and zero is rollback", () => {
    const saved = {
      percent: process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT,
      allowlist: process.env.TOJ_VIDEO_CALLS_ALLOWLIST,
    };
    const accountId = "00000000-0000-0000-0000-000000000123";
    try {
      process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT = "100";
      expect(videoCallsEnabledForAccount(accountId, false)).toBe(false);
      expect(videoCallsEnabledForAccount(accountId, true)).toBe(true);
      process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT = "0";
      expect(videoCallsEnabledForAccount(accountId, true)).toBe(false);
      process.env.TOJ_VIDEO_CALLS_ALLOWLIST = ` ${accountId.toUpperCase()} `;
      expect(videoCallsEnabledForAccount(accountId, true)).toBe(true);
      delete process.env.TOJ_VIDEO_CALLS_ALLOWLIST;
      process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT = "37";
      expect(videoCallsEnabledForAccount(accountId, true))
        .toBe(videoCallsEnabledForAccount(accountId, true));
    } finally {
      if (saved.percent === undefined) delete process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT;
      else process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT = saved.percent;
      if (saved.allowlist === undefined) delete process.env.TOJ_VIDEO_CALLS_ALLOWLIST;
      else process.env.TOJ_VIDEO_CALLS_ALLOWLIST = saved.allowlist;
    }
  });

  test("media-profile negotiation preserves video intent and the kill switch snapshot", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "a1".repeat(32), "sandbox", [1], [1, 2], 2);

    await expect(createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: crypto.randomUUID(), dialogId, callerCommitment: bytes(90).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: undefined,
    })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: crypto.randomUUID(), dialogId, callerCommitment: bytes(91).toString("base64"),
      supportedProtocolVersions: undefined, offeredMediaProfileVersions: [1],
    })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: crypto.randomUUID(), dialogId, callerCommitment: bytes(92).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1, 2, 3],
    })).rejects.toMatchObject({ code: "unsupported_media_profile" });

    const audioCallId = crypto.randomUUID();
    const audioContext = contextWithMedia(audioCallId, dialogId, alice, bob, [1, 2]);
    const audioMaterial = { publicKey: bytes(1), nonce: bytes(33), fingerprint: bytes(65) };
    const audio = await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: audioCallId, dialogId,
      callerCommitment: callerCommitmentV1(audioContext, audioMaterial).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1, 2], videoEnabled: false,
    });
    expect(audio.call.initialKind).toBe("voice");
    expect(Array.from(audio.call.offeredMediaProfileVersions)).toEqual([1, 2]);
    expect(Array.from(audio.call.selectableMediaProfileVersions)).toEqual([1]);
    const encodedAudio = JSON.parse(JSON.stringify(audio.call));
    expect(encodedAudio.offeredMediaProfileVersions).toEqual([1, 2]);
    expect(encodedAudio.selectableMediaProfileVersions).toEqual([1]);
    await expect(acceptCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: audioCallId,
      calleeCommitment: bytes(96).toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 2,
    })).rejects.toMatchObject({ code: "video_unavailable" });
    await acceptCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: audioCallId,
      calleeCommitment: bytes(96).toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 1,
    });
    await endCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: audioCallId, reason: "local_ended",
    });

    const rejectedVideoId = crypto.randomUUID();
    const rejectedContext = contextWithMedia(rejectedVideoId, dialogId, alice, bob, [2]);
    await expect(createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: rejectedVideoId, dialogId,
      callerCommitment: callerCommitmentV1(rejectedContext, audioMaterial).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [2], videoEnabled: false,
    })).rejects.toMatchObject({ code: "video_unavailable" });
    expect(await db`SELECT id FROM calls WHERE id = ${rejectedVideoId}`).toHaveLength(0);

    const inFlightId = crypto.randomUUID();
    const videoContext = contextWithMedia(inFlightId, dialogId, alice, bob, [2]);
    const createdVideo = await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: inFlightId, dialogId,
      callerCommitment: callerCommitmentV1(videoContext, audioMaterial).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [2], videoEnabled: true,
    });
    expect(createdVideo.call.initialKind).toBe("video");
    expect(Array.from(createdVideo.call.selectableMediaProfileVersions)).toEqual([2]);
    const retriedAfterRollback = await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: inFlightId, dialogId,
      callerCommitment: callerCommitmentV1(videoContext, audioMaterial).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [2], videoEnabled: false,
    });
    expect(retriedAfterRollback.call.id).toBe(inFlightId);
    expect(Array.from(retriedAfterRollback.call.selectableMediaProfileVersions)).toEqual([2]);
    const acceptedAfterRollback = await acceptCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: inFlightId,
      calleeCommitment: bytes(97).toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 2,
    });
    expect(acceptedAfterRollback.call.mediaProfileVersion).toBe(2);
  });

  test("concurrent identical call creation retries return the same persisted call", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "a6".repeat(32), "sandbox");
    const holderSql = makeSql(TEST_URL);
    const firstSql = makeSql(TEST_URL);
    const secondSql = makeSql(TEST_URL);
    let releaseLocks!: () => void;
    let announceLocks!: () => void;
    const locksHeld = new Promise<void>((resolve) => { announceLocks = resolve; });
    const released = new Promise<void>((resolve) => { releaseLocks = resolve; });
    const holder = holderSql.begin(async (tx) => {
      await lockAccountMutations(tx, [alice.accountId, bob.accountId]);
      announceLocks();
      await released;
    });
    await locksHeld;
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const parameters = {
      callerAccountId: alice.accountId,
      callerDeviceId: alice.deviceId,
      callId,
      dialogId,
      callerCommitment: callerCommitmentV1(ctx, {
        publicKey: bytes(7), nonce: bytes(39), fingerprint: bytes(71),
      }).toString("base64"),
      supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    };
    try {
      const first = createCall(firstSql, parameters);
      const second = createCall(secondSql, parameters);
      await waitForAdvisoryWaiters(2);
      releaseLocks();
      await holder;
      const [firstResult, secondResult] = await Promise.all([first, second]);
      expect(firstResult.call.id).toBe(callId);
      expect(secondResult.call.id).toBe(callId);
      expect(firstResult.ringTargetCount).toBe(1);
      expect(secondResult.ringTargetCount).toBe(1);
      expect(await db`SELECT id FROM calls WHERE id = ${callId}`).toHaveLength(1);
      expect(await db`SELECT id FROM call_invite_attempts WHERE caller_account_id = ${alice.accountId}`)
        .toHaveLength(1);
    } finally {
      releaseLocks();
      await holder;
      await Promise.all([holderSql.close(), firstSql.close(), secondSql.close()]);
    }
  }, 15_000);

  test("account rollout requires both participants and keeps audio available", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "a5".repeat(32), "sandbox", [1], [1, 2], 2);
    const savedAllowlist = process.env.TOJ_VIDEO_CALLS_ALLOWLIST;
    const savedPercent = process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT;
    try {
      process.env.TOJ_VIDEO_CALLS_ALLOWLIST = alice.accountId;
      process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT = "0";

      const videoCallId = crypto.randomUUID();
      const videoContext = contextWithMedia(videoCallId, dialogId, alice, bob, [2]);
      const material = { publicKey: bytes(3), nonce: bytes(35), fingerprint: bytes(67) };
      await expect(createCall(db, {
        callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
        callId: videoCallId, dialogId,
        callerCommitment: callerCommitmentV1(videoContext, material).toString("base64"),
        supportedProtocolVersions: [1], offeredMediaProfileVersions: [2],
        videoRolloutReady: true,
      })).rejects.toMatchObject({ code: "video_unavailable" });
      expect(await db`SELECT id FROM calls WHERE id = ${videoCallId}`).toHaveLength(0);

      const audioCallId = crypto.randomUUID();
      const audioContext = contextWithMedia(audioCallId, dialogId, alice, bob, [1, 2]);
      const audio = await createCall(db, {
        callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
        callId: audioCallId, dialogId,
        callerCommitment: callerCommitmentV1(audioContext, material).toString("base64"),
        supportedProtocolVersions: [1], offeredMediaProfileVersions: [1, 2],
        videoRolloutReady: true,
      });
      expect(audio.call.initialKind).toBe("voice");
      expect(audio.call.selectableMediaProfileVersions).toEqual([1]);
    } finally {
      if (savedAllowlist === undefined) delete process.env.TOJ_VIDEO_CALLS_ALLOWLIST;
      else process.env.TOJ_VIDEO_CALLS_ALLOWLIST = savedAllowlist;
      if (savedPercent === undefined) delete process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT;
      else process.env.TOJ_VIDEO_CALLS_ROLLOUT_PERCENT = savedPercent;
    }
  });

  test("call reads and wakeups are device scoped before and after first answer", async () => {
    const { alice, bob, dialogId } = await pair();
    const unrelatedAliceDevice = await addDevice(alice.accountId);
    const losingBobDevice = await addDevice(bob.accountId);
    await registerVoIPPushToken(db, bob.deviceId, "a2".repeat(32), "sandbox", [1], [1, 2], 2);
    await registerVoIPPushToken(db, losingBobDevice, "a3".repeat(32), "sandbox", [1], [1, 2], 2);
    const callId = crypto.randomUUID();
    const ctx = contextWithMedia(callId, dialogId, alice, bob, [2]);
    const callerMaterial = { publicKey: bytes(2), nonce: bytes(34), fingerprint: bytes(66) };
    const calleeMaterial = { publicKey: bytes(99), nonce: bytes(131), fingerprint: bytes(163) };
    const callerCommitment = callerCommitmentV1(ctx, callerMaterial);
    const created = await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitment.toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [2], videoEnabled: true,
    });
    expect(created.ringTargetCount).toBe(2);
    // Ring-target eligibility is immutable for the invitation view even if the device later
    // re-registers. Acceptance separately validates the current registration and fails closed.
    await registerVoIPPushToken(db, losingBobDevice, "a3".repeat(32), "sandbox");

    const invitation = (await getCall(db, bob.accountId, losingBobDevice, callId)).call;
    expect(invitation.view).toBe("invitation");
    expect(invitation.initialKind).toBe("video");
    expect(Array.from(invitation.selectableMediaProfileVersions)).toEqual([2]);
    expect(invitation.callerCommitment).not.toBeNull();
    expect(invitation.calleeCommitment).toBeNull();
    await expect(getCall(db, alice.accountId, unrelatedAliceDevice, callId))
      .rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(getCallEvents(db, alice.accountId, unrelatedAliceDevice, callId))
      .rejects.toMatchObject({ code: "not_found", status: 404 });
    expect((await getActiveCalls(db, alice.accountId, unrelatedAliceDevice)).calls).toEqual([]);
    const unrelatedMutation = { accountId: alice.accountId, deviceId: unrelatedAliceDevice, callId };
    await expect(acceptCall(db, {
      ...unrelatedMutation, calleeCommitment: bytes(200).toString("base64"),
      protocolVersion: 1, selectedMediaProfileVersion: 2,
    })).rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(revealCallKey(db, {
      ...unrelatedMutation, publicKey: bytes(201).toString("base64"),
      nonce: bytes(202).toString("base64"), fingerprint: bytes(203).toString("base64"),
    })).rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(confirmCallKey(db, {
      ...unrelatedMutation, confirmation: bytes(204).toString("base64"),
    })).rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(sendEncryptedCallEvent(db, {
      ...unrelatedMutation, version: 1, kind: "control", senderSequence: 1,
      ciphertext: Buffer.from("encrypted").toString("base64"),
      expiresAtMilliseconds: Date.now() + 30_000,
    })).rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(cancelCall(db, { ...unrelatedMutation, reason: "cancelled" }))
      .rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(endCall(db, { ...unrelatedMutation, reason: "failed" }))
      .rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(declineCall(db, { ...unrelatedMutation, reason: "declined" }))
      .rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(recordCallTelemetry(db, { ...unrelatedMutation, outcome: "failed" }))
      .rejects.toMatchObject({ code: "not_found", status: 404 });
    const savedTurnURLs = process.env.TOJ_TURN_URLS;
    const savedTurnSecret = process.env.TOJ_TURN_SHARED_SECRET;
    try {
      process.env.TOJ_TURN_URLS = "turn:turn.example.test:3478";
      process.env.TOJ_TURN_SHARED_SECRET = "test-secret";
      await expect(getIceConfig(db, alice.accountId, unrelatedAliceDevice, callId))
        .rejects.toMatchObject({ code: "not_found", status: 404 });
    } finally {
      if (savedTurnURLs === undefined) delete process.env.TOJ_TURN_URLS;
      else process.env.TOJ_TURN_URLS = savedTurnURLs;
      if (savedTurnSecret === undefined) delete process.env.TOJ_TURN_SHARED_SECRET;
      else process.env.TOJ_TURN_SHARED_SECRET = savedTurnSecret;
    }

    const calleeCommitment = calleeCommitmentV1(
      ctx, callerCommitment, bob.deviceId, 1, 2, calleeMaterial,
    );
    const accepted = await acceptCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 2,
    });
    const acceptanceTargets = await resolveCallHintTargets(db, {
      callId, latestEventSeq: accepted.call.latestEventSeq,
    }, [alice.deviceId, unrelatedAliceDevice, bob.deviceId, losingBobDevice]);
    expect(new Set(acceptanceTargets.map((target) => target.deviceId)))
      .toEqual(new Set([alice.deviceId, bob.deviceId, losingBobDevice]));
    expect(acceptanceTargets.find((target) => target.deviceId === losingBobDevice)?.latestEventSeq)
      .toBe(0);
    expect(acceptanceTargets.filter((target) => target.deviceId !== losingBobDevice)
      .every((target) => target.latestEventSeq === accepted.call.latestEventSeq)).toBe(true);

    const lifecycle = (await getCall(db, bob.accountId, losingBobDevice, callId)).call;
    expect(lifecycle.view).toBe("lifecycle");
    expect(lifecycle.state).toBe("ended");
    expect(lifecycle.endReason).toBe("answered_elsewhere");
    expect(lifecycle.localRingStatus).toBe("answered_elsewhere");
    expect(lifecycle.offeredProtocolVersions).toEqual([]);
    expect(lifecycle.offeredMediaProfileVersions).toEqual([]);
    expect(lifecycle.callerCommitment).toBeNull();
    expect(lifecycle.acceptedAt).toBeNull();
    expect(lifecycle.confirmedAt).toBeNull();
    expect(lifecycle.latestEventSeq).toBe(0);
    const lifecycleEvents = await getCallEvents(db, bob.accountId, losingBobDevice, callId);
    expect(lifecycleEvents).toMatchObject({ events: [], latestEventSeq: 0, hasMore: false });

    await revealCallKey(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: callerMaterial.publicKey.toString("base64"),
      nonce: callerMaterial.nonce.toString("base64"),
      fingerprint: callerMaterial.fingerprint.toString("base64"),
    });
    await revealCallKey(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
      publicKey: calleeMaterial.publicKey.toString("base64"),
      nonce: calleeMaterial.nonce.toString("base64"),
      fingerprint: calleeMaterial.fingerprint.toString("base64"),
      confirmation: bytes(195).toString("base64"),
    });
    await confirmCallKey(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      confirmation: bytes(227).toString("base64"),
    });

    const signal = await sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind: "offer", senderSequence: 1,
      ciphertext: Buffer.from("encrypted").toString("base64"),
      expiresAtMilliseconds: Date.now() + 30_000,
    });
    const setupTargets = await resolveCallHintTargets(db, {
      callId, latestEventSeq: signal.event.eventSeq,
    }, [alice.deviceId, unrelatedAliceDevice, bob.deviceId, losingBobDevice]);
    expect(new Set(setupTargets.map((target) => target.deviceId)))
      .toEqual(new Set([alice.deviceId, bob.deviceId]));
    const delayedAcceptanceTargets = await resolveCallHintTargets(db, {
      callId, latestEventSeq: accepted.call.latestEventSeq,
    }, [alice.deviceId, unrelatedAliceDevice, bob.deviceId, losingBobDevice]);
    expect(new Set(delayedAcceptanceTargets.map((target) => target.deviceId)))
      .toEqual(new Set([alice.deviceId, bob.deviceId, losingBobDevice]));
    expect(delayedAcceptanceTargets.find((target) => target.deviceId === losingBobDevice)?.latestEventSeq)
      .toBe(0);
    const lifecycleAfterSetup = (await getCall(db, bob.accountId, losingBobDevice, callId)).call;
    expect(lifecycleAfterSetup).toMatchObject({
      view: "lifecycle", state: "ended", localRingStatus: "answered_elsewhere",
      endReason: "answered_elsewhere", latestEventSeq: 0,
      acceptedAt: null, confirmedAt: null,
    });
  });

  test("first answer preserves explicit declines and wakes only devices still losing the ring", async () => {
    const { alice, bob, dialogId } = await pair();
    const declinedDevice = await addDevice(bob.accountId);
    const losingDevice = await addDevice(bob.accountId);
    await registerVoIPPushToken(db, bob.deviceId, "b1".repeat(32), "sandbox");
    await registerVoIPPushToken(db, declinedDevice, "b2".repeat(32), "sandbox");
    await registerVoIPPushToken(db, losingDevice, "b3".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const callerMaterial = { publicKey: bytes(4), nonce: bytes(36), fingerprint: bytes(68) };
    const callerCommitment = callerCommitmentV1(ctx, callerMaterial);
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId, dialogId, callerCommitment: callerCommitment.toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    const declined = await declineCall(db, {
      accountId: bob.accountId, deviceId: declinedDevice, callId,
    });
    expect(declined.call).toMatchObject({
      view: "lifecycle", state: "ended", localRingStatus: "declined",
      endReason: "declined", latestEventSeq: 0,
      callerCommitment: null, calleeCommitment: null, acceptedDeviceId: null,
    });

    const calleeMaterial = { publicKey: bytes(100), nonce: bytes(132), fingerprint: bytes(164) };
    const accepted = await acceptCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
      calleeCommitment: calleeCommitmentV1(
        ctx, callerCommitment, bob.deviceId, 1, 1, calleeMaterial,
      ).toString("base64"),
      protocolVersion: 1,
      selectedMediaProfileVersion: 1,
    });
    const statuses = await db`
      SELECT device_id, status FROM call_ring_targets WHERE call_id = ${callId}`;
    expect(new Map(statuses.map((row) => [row.device_id, row.status]))).toEqual(new Map([
      [bob.deviceId, "accepted"],
      [declinedDevice, "declined"],
      [losingDevice, "answered_elsewhere"],
    ]));
    expect((await getCall(db, bob.accountId, declinedDevice, callId)).call.localRingStatus)
      .toBe("declined");
    const declinedRetry = await declineCall(db, {
      accountId: bob.accountId, deviceId: declinedDevice, callId,
    });
    expect(declinedRetry.call).toMatchObject({
      view: "lifecycle", state: "ended", localRingStatus: "declined",
      endReason: "declined", latestEventSeq: 0,
      offeredProtocolVersions: [], offeredMediaProfileVersions: [],
      callerCommitment: null, calleeCommitment: null, callerFingerprint: null,
      acceptedDeviceId: null, calleePublicKey: null, callerPublicKey: null,
      acceptedAt: null, confirmedAt: null,
    });
    const targets = await resolveCallHintTargets(db, {
      callId, latestEventSeq: accepted.call.latestEventSeq,
    }, [alice.deviceId, bob.deviceId, declinedDevice, losingDevice]);
    expect(new Set(targets.map((target) => target.deviceId)))
      .toEqual(new Set([alice.deviceId, bob.deviceId, losingDevice]));
  });

  test("legacy VoIP registration clears stale video capability", async () => {
    const { bob } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "a4".repeat(32), "sandbox", [1], [1, 2], 2);
    const upgraded = (await db`
      SELECT supported_call_media_profile_versions, call_view_version
      FROM devices WHERE id = ${bob.deviceId}`)[0];
    expect(Array.from(upgraded.supported_call_media_profile_versions)).toEqual([1, 2]);
    expect(upgraded.call_view_version).toBe(2);
    const legacy = await registerVoIPPushToken(db, bob.deviceId, "a4".repeat(32), "sandbox");
    expect(legacy).toMatchObject({
      supportedCallProtocolVersions: [1], supportedCallMediaProfileVersions: [1], callViewVersion: 1,
    });
  });

  test("two-sided commitments, first-answer-wins, signaling, and history are durable", async () => {
    const { alice, bob, dialogId } = await pair();
    const otherBobDevice = await addDevice(bob.accountId);
    await registerVoIPPushToken(db, bob.deviceId, "ab".repeat(32), "sandbox");
    await registerVoIPPushToken(db, otherBobDevice, "ac".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const callerMaterial = { publicKey: bytes(1), nonce: bytes(33), fingerprint: bytes(65) };
    const calleeMaterial = { publicKey: bytes(97), nonce: bytes(129), fingerprint: bytes(161) };
    const callerCommitment = callerCommitmentV1(ctx, callerMaterial);
    const calleeCommitment = calleeCommitmentV1(
      ctx, callerCommitment, bob.deviceId, 1, 1, calleeMaterial,
    );

    const created = await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId, dialogId, callerCommitment: callerCommitment.toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1], networkKey: "test-network",
    });
    expect(created.ringTargetCount).toBe(2);
    expect(created.call.calleeCommitment).toBeNull();
    const accepted = await acceptCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 1,
    });
    expect(accepted.call.calleePublicKey).toBeNull();
    await expect(acceptCall(db, {
      accountId: bob.accountId, deviceId: otherBobDevice, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 1,
    })).rejects.toMatchObject({ code: "answered_elsewhere" });

    const tampered = Buffer.from(callerMaterial.nonce);
    tampered[0] ^= 1;
    await expect(revealCallKey(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: callerMaterial.publicKey.toString("base64"), nonce: tampered.toString("base64"),
      fingerprint: callerMaterial.fingerprint.toString("base64"),
    })).rejects.toMatchObject({ code: "invalid_commitment" });
    await revealCallKey(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: callerMaterial.publicKey.toString("base64"), nonce: callerMaterial.nonce.toString("base64"),
      fingerprint: callerMaterial.fingerprint.toString("base64"),
    });
    await revealCallKey(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
      publicKey: calleeMaterial.publicKey.toString("base64"), nonce: calleeMaterial.nonce.toString("base64"),
      fingerprint: calleeMaterial.fingerprint.toString("base64"), confirmation: bytes(193).toString("base64"),
    });
    const active = await confirmCallKey(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      confirmation: bytes(225).toString("base64"),
    });
    expect(active.call.state).toBe("active");
    const initialLease = Number((await db`
      SELECT EXTRACT(EPOCH FROM (expires_at - now())) AS seconds FROM calls WHERE id = ${callId}`)[0].seconds);
    expect(initialLease).toBeGreaterThan(100);
    expect(initialLease).toBeLessThanOrEqual(121);

    const oldTurnURLs = process.env.TOJ_TURN_URLS;
    const oldTurnSecret = process.env.TOJ_TURN_SHARED_SECRET;
    try {
      process.env.TOJ_TURN_URLS = "turn:one.example.test:3478,turns:two.example.test:443";
      process.env.TOJ_TURN_SHARED_SECRET = "turn-test-secret";
      const firstICE = await getIceConfig(db, alice.accountId, alice.deviceId, callId);
      const secondICE = await getIceConfig(db, alice.accountId, alice.deviceId, callId);
      expect(secondICE.iceServers).toEqual(firstICE.iceServers);
      const username = firstICE.iceServers.at(-1)!.username!;
      expect(username.split(":").at(-1)).toMatch(/^[0-9a-f]{32}$/);
      expect(await db`SELECT id FROM turn_allocations WHERE call_id = ${callId} AND account_id = ${alice.accountId}`)
        .toHaveLength(1);
      await expect(getIceConfig(db, bob.accountId, otherBobDevice, callId))
        .rejects.toMatchObject({ code: "invalid_device" });
      await expect(endCall(db, {
        accountId: bob.accountId, deviceId: otherBobDevice, callId, reason: "local_ended",
      })).rejects.toMatchObject({ code: "invalid_device" });
    } finally {
      if (oldTurnURLs === undefined) delete process.env.TOJ_TURN_URLS;
      else process.env.TOJ_TURN_URLS = oldTurnURLs;
      if (oldTurnSecret === undefined) delete process.env.TOJ_TURN_SHARED_SECRET;
      else process.env.TOJ_TURN_SHARED_SECRET = oldTurnSecret;
    }

    const expiry = Date.now() + 60_000;
    await db`UPDATE calls SET expires_at = now() + interval '30 seconds' WHERE id = ${callId}`;
    const signal = await sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind: "offer", senderSequence: 1,
      ciphertext: Buffer.alloc(65_564, 7).toString("base64"), expiresAtMilliseconds: expiry,
    });
    expect(signal.event.kind).toBe("offer");
    expect(signal.event.expiresAtMilliseconds).toBe(expiry);
    const renewedLease = Number((await db`
      SELECT EXTRACT(EPOCH FROM (expires_at - now())) AS seconds FROM calls WHERE id = ${callId}`)[0].seconds);
    expect(renewedLease).toBeGreaterThan(100);
    expect((await getCallEvents(db, bob.accountId, bob.deviceId, callId)).events.at(-1)?.ciphertext)
      .toBe(Buffer.alloc(65_564, 7).toString("base64"));

    // Exact transport retries are idempotent and do not consume the rolling signaling budget.
    const retriedSignal = await sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind: "offer", senderSequence: 1,
      ciphertext: Buffer.alloc(65_564, 7).toString("base64"), expiresAtMilliseconds: expiry,
    });
    expect(retriedSignal.event.eventSeq).toBe(signal.event.eventSeq);
    expect((await db`
      SELECT event_count, ciphertext_bytes, negotiation_event_count
      FROM call_signal_budgets WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`)[0])
      .toMatchObject({ event_count: 1, ciphertext_bytes: "65564", negotiation_event_count: 1 });

    const smallSignal = (kind: "offer" | "control", senderSequence = 2) => sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind, senderSequence,
      ciphertext: Buffer.alloc(1, 9).toString("base64"), expiresAtMilliseconds: expiry,
    });
    await db`
      UPDATE call_signal_budgets SET event_count = 120, ciphertext_bytes = 0,
        negotiation_event_count = 0, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    await expect(smallSignal("control")).rejects.toMatchObject({ code: "rate_limited", status: 429 });
    expect((await db`
      SELECT event_count FROM call_signal_budgets
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`)[0].event_count).toBe(120);

    await db`
      UPDATE call_signal_budgets SET event_count = 0, ciphertext_bytes = 524288,
        negotiation_event_count = 0, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    await expect(smallSignal("control")).rejects.toMatchObject({ code: "rate_limited", status: 429 });

    await db`
      UPDATE call_signal_budgets SET event_count = 0, ciphertext_bytes = 0,
        negotiation_event_count = 12, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    await expect(smallSignal("offer")).rejects.toMatchObject({ code: "rate_limited", status: 429 });

    // The call-row lock serializes racing devices/requests at the final budget slot: one commits,
    // one rolls back, and the stored counter never exceeds the configured ceiling.
    await db`
      UPDATE call_signal_budgets SET event_count = 119, ciphertext_bytes = 0,
        negotiation_event_count = 0, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    const racingSignals = await Promise.allSettled([
      smallSignal("control", 2),
      smallSignal("control", 3),
    ]);
    expect(racingSignals.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejectedRace = racingSignals.find((result) => result.status === "rejected") as PromiseRejectedResult;
    expect(rejectedRace.reason).toMatchObject({ code: "rate_limited", status: 429 });
    expect(Number((await db`
      SELECT event_count FROM call_signal_budgets
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`)[0].event_count)).toBe(120);

    await db`
      UPDATE call_signal_budgets SET event_count = 0, ciphertext_bytes = 0,
        negotiation_event_count = 0, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    const hangup = await sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind: "hangup", senderSequence: 4,
      ciphertext: Buffer.alloc(1, 11).toString("base64"), expiresAtMilliseconds: expiry,
    });
    expect(hangup.syncPushes?.length).toBeGreaterThan(0);
    expect((await db`SELECT state, end_reason FROM calls WHERE id = ${callId}`)[0])
      .toMatchObject({ state: "ended", end_reason: "remote_ended" });
    expect(await db`SELECT account_id FROM call_participant_leases WHERE call_id = ${callId}`)
      .toHaveLength(0);
    await expect(smallSignal("control", 5)).rejects.toMatchObject({ code: "invalid_state", status: 409 });
    const postEndTurnURLs = process.env.TOJ_TURN_URLS;
    const postEndTurnSecret = process.env.TOJ_TURN_SHARED_SECRET;
    try {
      delete process.env.TOJ_TURN_URLS;
      delete process.env.TOJ_TURN_SHARED_SECRET;
      await expect(getIceConfig(db, bob.accountId, otherBobDevice, callId))
        .rejects.toMatchObject({ code: "invalid_device", status: 403 });
    } finally {
      if (postEndTurnURLs === undefined) delete process.env.TOJ_TURN_URLS;
      else process.env.TOJ_TURN_URLS = postEndTurnURLs;
      if (postEndTurnSecret === undefined) delete process.env.TOJ_TURN_SHARED_SECRET;
      else process.env.TOJ_TURN_SHARED_SECRET = postEndTurnSecret;
    }

    const server = startCloudServer(0, db, null, null);
    try {
      const revoked = await fetch(`http://127.0.0.1:${server.port}/v1/session`, {
        method: "DELETE", headers: { authorization: `Bearer ${alice.token}` },
      });
      expect(revoked.status).toBe(200);
    } finally {
      await server.stop(true);
    }
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("ended");
    expect(await db`SELECT account_id FROM call_participant_leases WHERE call_id = ${callId}`).toHaveLength(0);
    const history = await getHistory(db, alice.accountId, dialogId);
    const service = history.messages.find((message) => message.kind === "service");
    expect(service).toBeDefined();
    expect(JSON.parse(service!.text)).toMatchObject({
      v: 1, type: "voice_call", callId, callerAccountId: alice.accountId, outcome: "completed",
    });
    const expiries = await db`SELECT expires_at FROM call_events WHERE call_id = ${callId}`;
    expect(expiries.every((row) => new Date(row.expires_at).getTime() <= Date.now() + 10 * 60_000 + 1_000)).toBe(true);
  });

  test("VoIP registration is separate and the outbox emits the minimal payload", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "cd".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const callerMaterial = { publicKey: bytes(2), nonce: bytes(34), fingerprint: bytes(66) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, callerMaterial).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    const sender = new StubSender();
    expect(await processVoIPPushBatch(db, sender)).toBe(1);
    expect(sender.requests[0]).toMatchObject({
      kind: "voip", callId, callerAccountId: alice.accountId, environment: "sandbox",
    });
    const request = sender.requests[0];
    if (request.kind !== "voip") throw new Error("expected VoIP request");
    expect(buildVoIPAPNsPayload(request)).toEqual({
      aps: { "content-available": 1 },
      toj: { v: 1, type: "voice_call", callId, callerAccountId: alice.accountId, expiresAt: request.expiresAt },
    });
    expect(buildAPNsHeaders(request, "com.toj.Toj", "com.toj.Toj.voip", 123)).toEqual({
      "apns-topic": "com.toj.Toj.voip",
      "apns-push-type": "voip",
      "apns-priority": "10",
      "apns-expiration": "0",
    });
    const stored = (await db`
      SELECT voip_push_token_ciphertext, voip_push_token_nonce, voip_push_token_key_id,
        push_token_ciphertext FROM devices WHERE id = ${bob.deviceId}`)[0];
    expect(Buffer.from(stored.voip_push_token_ciphertext).includes(Buffer.from("cd".repeat(32)))).toBe(false);
    const sealed = {
      ciphertext: Buffer.from(stored.voip_push_token_ciphertext),
      nonce: Buffer.from(stored.voip_push_token_nonce),
      keyId: stored.voip_push_token_key_id,
    };
    expect(open(sealed, voipPushTokenAAD(bob.deviceId)).toString("utf8")).toBe("cd".repeat(32));
    expect(() => open(sealed, pushTokenAAD(bob.deviceId))).toThrow();
    expect(stored.push_token_ciphertext).toBeNull();
  });

  test("push and history preserve immutable video versus voice start intent", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "ce".repeat(32), "sandbox", [1], [1, 2], 2);
    const material = { publicKey: bytes(4), nonce: bytes(36), fingerprint: bytes(68) };

    const videoCallId = crypto.randomUUID();
    const videoContext = contextWithMedia(videoCallId, dialogId, alice, bob, [2]);
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: videoCallId, dialogId,
      callerCommitment: callerCommitmentV1(videoContext, material).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [2], videoEnabled: true,
    });
    const sender = new StubSender();
    expect(await processVoIPPushBatch(db, sender)).toBe(1);
    const videoRequest = sender.requests[0];
    if (videoRequest?.kind !== "voip") throw new Error("expected VoIP request");
    expect(buildVoIPAPNsPayload(videoRequest).toj.type).toBe("video_call");
    await cancelCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: videoCallId,
    });

    const audioCallId = crypto.randomUUID();
    const audioContext = contextWithMedia(audioCallId, dialogId, alice, bob, [1, 2]);
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId: audioCallId, dialogId,
      callerCommitment: callerCommitmentV1(audioContext, material).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1, 2], videoEnabled: true,
    });
    await acceptCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: audioCallId,
      calleeCommitment: bytes(100).toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 2,
    });
    await endCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: audioCallId,
      reason: "local_ended",
    });

    const history = await getHistory(db, alice.accountId, dialogId);
    const historyType = (callId: string) => {
      const message = history.messages.find((candidate) => {
        if (candidate.kind !== "service") return false;
        return JSON.parse(candidate.text).callId === callId;
      });
      return message ? JSON.parse(message.text).type : null;
    };
    expect(historyType(videoCallId)).toBe("video_call");
    // Selecting media profile 2 for an audio-start call never rewrites its history intent.
    expect(historyType(audioCallId)).toBe("voice_call");
  });

  test("call-history delivery emits a bounded cross-process sync wake-up", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "cf".repeat(32), "sandbox");
    const listener = new Client({ connectionString: TEST_URL });
    await listener.connect();
    await listener.query("LISTEN toj_sync_events");
    try {
      const callId = crypto.randomUUID();
      const ctx = context(callId, dialogId, alice, bob);
      const material = { publicKey: bytes(6), nonce: bytes(38), fingerprint: bytes(70) };
      await createCall(db, {
        callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
        callId, dialogId,
        callerCommitment: callerCommitmentV1(ctx, material).toString("base64"),
        supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
      });
      const wakeup = new Promise<{ accountId: string; pts: number; ptsCount: number }>(
        (resolve, reject) => {
          const timeout = setTimeout(() => reject(new Error("sync wake-up timed out")), 2_000);
          listener.on("notification", (notification) => {
            if (notification.channel !== "toj_sync_events" || !notification.payload) return;
            const decoded = JSON.parse(notification.payload);
            if (![alice.accountId, bob.accountId].includes(decoded.accountId)) return;
            clearTimeout(timeout);
            resolve(decoded);
          });
        },
      );
      await cancelCall(db, {
        accountId: alice.accountId, deviceId: alice.deviceId, callId,
      });
      const decoded = await wakeup;
      expect(Object.keys(decoded).sort()).toEqual(["accountId", "pts", "ptsCount"]);
      expect([alice.accountId, bob.accountId]).toContain(decoded.accountId);
      expect(decoded.pts).toBeGreaterThan(0);
      expect(decoded.ptsCount).toBe(1);
    } finally {
      await listener.end();
    }
  });

  test("VoIP delivery uses bounded concurrency so one slow APNs request cannot stall the batch", async () => {
    const { alice, bob, dialogId } = await pair();
    const targetDevices = [bob.deviceId];
    for (let index = 0; index < 4; index += 1) targetDevices.push(await addDevice(bob.accountId));
    for (const [index, deviceId] of targetDevices.entries()) {
      await registerVoIPPushToken(db, deviceId, (index + 40).toString(16).padStart(2, "0").repeat(32), "sandbox");
    }
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(2), nonce: bytes(34), fingerprint: bytes(66) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });

    const sender = new ConcurrentPausingSender();
    const processing = processVoIPPushBatch(db, sender);
    const startedConcurrently = await Promise.race([
      sender.multipleStarted.then(() => true),
      Bun.sleep(1_000).then(() => false),
    ]);
    sender.release();
    expect(startedConcurrently).toBe(true);
    expect(await processing).toBe(targetDevices.length);
    expect(sender.requests).toHaveLength(targetDevices.length);
  });

  test("only complete VoIP registrations ring and a decline is scoped to one device", async () => {
    const { alice, bob, dialogId } = await pair();
    const secondBobDevice = await addDevice(bob.accountId);
    const unregisteredBobDevice = await addDevice(bob.accountId);
    await registerVoIPPushToken(db, bob.deviceId, "d1".repeat(32), "sandbox");
    await registerVoIPPushToken(db, secondBobDevice, "d2".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(5), nonce: bytes(37), fingerprint: bytes(69) };
    const created = await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    expect(created.ringTargetCount).toBe(2);
    const targets = await db`
      SELECT device_id, status FROM call_ring_targets WHERE call_id = ${callId} ORDER BY device_id`;
    expect(targets.map((row) => row.device_id).sort()).toEqual([bob.deviceId, secondBobDevice].sort());
    expect(targets.some((row) => row.device_id === unregisteredBobDevice)).toBe(false);

    const firstDecline = await declineCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
    });
    expect(firstDecline.call).toMatchObject({
      view: "lifecycle", state: "ended", localRingStatus: "declined", latestEventSeq: 0,
    });
    expect((await db`
      SELECT status FROM call_ring_targets WHERE call_id = ${callId} AND device_id = ${bob.deviceId}`)[0].status)
      .toBe("declined");
    expect((await db`
      SELECT status FROM call_ring_targets WHERE call_id = ${callId} AND device_id = ${secondBobDevice}`)[0].status)
      .toBe("ringing");

    const finalDecline = await declineCall(db, {
      accountId: bob.accountId, deviceId: secondBobDevice, callId,
    });
    expect(finalDecline.call.state).toBe("ended");
    expect((await declineCall(db, {
      accountId: bob.accountId, deviceId: secondBobDevice, callId,
    })).call.state).toBe("ended");
    const service = (await getHistory(db, bob.accountId, dialogId)).messages
      .find((message) => message.kind === "service" && JSON.parse(message.text).callId === callId);
    expect(JSON.parse(service!.text)).toMatchObject({
      callerAccountId: alice.accountId, outcome: "declined",
    });
  });

  test("deadline is rechecked on the locked call before credentials are issued", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d3".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(6), nonce: bytes(38), fingerprint: bytes(70) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });

    await db`UPDATE calls SET expires_at = now() - interval '1 second' WHERE id = ${callId}`;
    const oldURLs = process.env.TOJ_TURN_URLS;
    const oldSecret = process.env.TOJ_TURN_SHARED_SECRET;
    try {
      process.env.TOJ_TURN_URLS = "turn:one.example.test:3478";
      process.env.TOJ_TURN_SHARED_SECRET = "turn-test-secret";
      await expect(getIceConfig(db, alice.accountId, alice.deviceId, callId))
        .rejects.toMatchObject({ code: "expired" });
    } finally {
      if (oldURLs === undefined) delete process.env.TOJ_TURN_URLS;
      else process.env.TOJ_TURN_URLS = oldURLs;
      if (oldSecret === undefined) delete process.env.TOJ_TURN_SHARED_SECRET;
      else process.env.TOJ_TURN_SHARED_SECRET = oldSecret;
    }
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("requested");
  });

  test("call history stays pending after a transient failure and retries idempotently", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d4".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(7), nonce: bytes(39), fingerprint: bytes(71) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    await sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: callId, body: "ordinary message using the public call id",
    });
    await db`
      UPDATE dialog_members SET left_at = now()
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    expect((await cancelCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
    })).call.state).toBe("ended");
    expect((await db`SELECT status, attempts FROM call_history_outbox WHERE call_id = ${callId}`)[0])
      .toMatchObject({ status: "pending", attempts: 1 });
    const outbox = (await db`
      SELECT history_client_msg_id FROM call_history_outbox WHERE call_id = ${callId}`)[0];
    expect(outbox.history_client_msg_id).not.toBe(callId);

    await db`UPDATE calls SET ended_at = now() - interval '31 days' WHERE id = ${callId}`;
    await db`UPDATE call_history_outbox SET available_at = now() + interval '1 hour' WHERE call_id = ${callId}`;
    expect((await cleanupCallData(db, 10)).calls).toBe(0);
    expect(await db`SELECT id FROM calls WHERE id = ${callId}`).toHaveLength(1);

    await db`
      UPDATE dialog_members SET left_at = NULL
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    await db`UPDATE call_history_outbox SET available_at = now() WHERE call_id = ${callId}`;
    expect((await processCallHistoryOutbox(db, 1, callId)).processed).toBe(1);
    expect((await processCallHistoryOutbox(db, 1, callId)).processed).toBe(0);
    expect((await db`SELECT status FROM call_history_outbox WHERE call_id = ${callId}`)[0].status)
      .toBe("delivered");
    const rows = (await getHistory(db, bob.accountId, dialogId)).messages
      .filter((message) => message.kind === "service" && JSON.parse(message.text).callId === callId);
    expect(rows).toHaveLength(1);
  });

  test("account deletion and call termination commit together with the original caller identity", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d5".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(8), nonce: bytes(40), fingerprint: bytes(72) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    const deletion = await startAccountDeletion(db, alice.accountId);
    const result = await deleteAccountAndTerminateCalls(db, alice.accountId, deletion.code!);
    expect(result.deleted).toBe(true);
    expect((await db`SELECT status FROM accounts WHERE id = ${alice.accountId}`)[0].status).toBe("deleted");
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("ended");
    const service = (await getHistory(db, bob.accountId, dialogId)).messages
      .find((message) => message.kind === "service" && JSON.parse(message.text).callId === callId);
    expect(service!.sender_account_id).toBe(alice.accountId);
    expect(JSON.parse(service!.text)).toMatchObject({ callerAccountId: alice.accountId });
  });

  test("device revocation and owned call termination are atomic", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d7".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(10), nonce: bytes(42), fingerprint: bytes(74) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });

    await expect(revokeDevice(db, alice.accountId, alice.deviceId, {
      beforeCommit: async (tx) => {
        await tx`UPDATE calls SET state = 'ended' WHERE id = ${callId}`;
        throw new Error("simulated transaction failure");
      },
    })).rejects.toThrow("simulated transaction failure");
    expect((await db`SELECT revoked_at FROM devices WHERE id = ${alice.deviceId}`)[0].revoked_at).toBeNull();
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("requested");

    expect((await revokeDeviceAndTerminateCalls(db, alice.accountId, alice.deviceId)).revoked).toBe(true);
    expect((await db`SELECT revoked_at FROM devices WHERE id = ${alice.deviceId}`)[0].revoked_at).not.toBeNull();
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("ended");
  });

  test("a concurrent call end cannot be overwritten by a late VoIP send result", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d6".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(9), nonce: bytes(41), fingerprint: bytes(73) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    const sender = new PausingSender();
    const processing = processVoIPPushBatch(db, sender);
    await sender.started;
    await cancelCall(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId });
    sender.release();
    expect(await processing).toBe(1);
    expect((await db`
      SELECT status FROM voip_push_deliveries WHERE call_id = ${callId} AND device_id = ${bob.deviceId}`)[0].status)
      .toBe("dead");
  });

  test("blocks stop user messages and new calls but internal call history remains trusted", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "e1".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(4), nonce: bytes(36), fingerprint: bytes(68) };
    const callee = { publicKey: bytes(100), nonce: bytes(132), fingerprint: bytes(164) };
    const callerCommitment = callerCommitmentV1(ctx, caller);
    const calleeCommitment = calleeCommitmentV1(ctx, callerCommitment, bob.deviceId, 1, 1, callee);
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitment.toString("base64"), supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    });
    await acceptCall(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1, selectedMediaProfileVersion: 1 });
    await revealCallKey(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: caller.publicKey.toString("base64"), nonce: caller.nonce.toString("base64"),
      fingerprint: caller.fingerprint.toString("base64") });
    await revealCallKey(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId,
      publicKey: callee.publicKey.toString("base64"), nonce: callee.nonce.toString("base64"),
      fingerprint: callee.fingerprint.toString("base64"), confirmation: bytes(196).toString("base64") });
    await confirmCallKey(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId,
      confirmation: bytes(228).toString("base64") });

    await blockAccount(db, bob.accountId, alice.accountId);
    expect((await db`SELECT state, end_reason FROM calls WHERE id = ${callId}`)[0])
      .toMatchObject({ state: "ended", end_reason: "blocked" });
    expect(await db`SELECT account_id FROM call_participant_leases WHERE call_id = ${callId}`)
      .toHaveLength(0);
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: crypto.randomUUID(), body: "blocked",
    })).rejects.toThrow("conversation is blocked");
    await endCall(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId, reason: "local_ended" });
    await endCall(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId, reason: "local_ended" });
    const serviceRows = (await getHistory(db, bob.accountId, dialogId)).messages
      .filter((message) => message.kind === "service" && JSON.parse(message.text).callId === callId);
    expect(serviceRows).toHaveLength(1);

    await expect(createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId: crypto.randomUUID(), dialogId,
      callerCommitment: bytes(1).toString("base64"), supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    })).rejects.toMatchObject({ code: "blocked" });
  });

  test("once blocking wins the shared mutation lock, queued messages and calls cannot commit", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "e6".repeat(32), "sandbox");
    const holderSql = makeSql(TEST_URL);
    const blockerSql = makeSql(TEST_URL);
    const senderSql = makeSql(TEST_URL);
    const callerSql = makeSql(TEST_URL);
    let releaseLocks!: () => void;
    let announceLocks!: () => void;
    const locksHeld = new Promise<void>((resolve) => { announceLocks = resolve; });
    const released = new Promise<void>((resolve) => { releaseLocks = resolve; });
    const holder = holderSql.begin(async (tx) => {
      await lockAccountMutations(tx, [alice.accountId, bob.accountId]);
      announceLocks();
      await released;
    });
    await locksHeld;

    const blocking = blockAccount(blockerSql, bob.accountId, alice.accountId);
    await waitForAdvisoryWaiters(1);
    const sending = sendMessage(senderSql, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: crypto.randomUUID(), body: "must not cross the block boundary",
    }).then(() => null, (error: unknown) => error);
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const calling = createCall(callerSql, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, {
        publicKey: bytes(11), nonce: bytes(43), fingerprint: bytes(75),
      }).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    }).then(() => null, (error: unknown) => error);
    // Ensure block, send, and call are all queued on the shared account boundary before release.
    // Before the call path followed the common lock order, it held dialog membership rows here and
    // deterministically deadlocked with the sender that acquired the advisory lock ahead of it.
    await waitForAdvisoryWaiters(3);
    releaseLocks();
    await holder;

    expect((await blocking).blocked).toBe(true);
    expect(await sending).toMatchObject({ message: "conversation is blocked" });
    expect(await calling).toMatchObject({ code: "blocked" });
    expect(await db`SELECT id FROM calls WHERE id = ${callId}`).toHaveLength(0);
    await Promise.all([holderSql.close(), blockerSql.close(), senderSql.close(), callerSql.close()]);
  }, 15_000);

  test("HTTP event endpoint accepts the full encrypted boundary and rejects one byte over", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "e2".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(3), nonce: bytes(35), fingerprint: bytes(67) };
    const callee = { publicKey: bytes(99), nonce: bytes(131), fingerprint: bytes(163) };
    const callerCommitment = callerCommitmentV1(ctx, caller);
    const calleeCommitment = calleeCommitmentV1(ctx, callerCommitment, bob.deviceId, 1, 1, callee);
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitment.toString("base64"), supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    });
    await acceptCall(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1, selectedMediaProfileVersion: 1 });
    await revealCallKey(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: caller.publicKey.toString("base64"), nonce: caller.nonce.toString("base64"),
      fingerprint: caller.fingerprint.toString("base64") });
    await revealCallKey(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId,
      publicKey: callee.publicKey.toString("base64"), nonce: callee.nonce.toString("base64"),
      fingerprint: callee.fingerprint.toString("base64"), confirmation: bytes(195).toString("base64") });
    await confirmCallKey(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId,
      confirmation: bytes(227).toString("base64") });

    const server = startCloudServer(0, db, null, null);
    const url = `http://127.0.0.1:${server.port}/v1/calls/${callId}/events`;
    try {
      const send = (size: number, sequence: number,
        kind: "offer" | "ice_candidate" | "control" = "offer") => fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify({
          version: 1, kind, senderSequence: sequence,
          ciphertext: Buffer.alloc(size).toString("base64"), expiresAtMilliseconds: Date.now() + 60_000,
        }),
      });
      const boundary = await send(65_564, 1);
      expect(boundary.status).toBe(201);
      const tooLarge = await send(65_565, 2);
      expect(tooLarge.status).toBe(413);
      expect(await tooLarge.json()).toMatchObject({ code: "payload_too_large" });
      const candidateTooLarge = await send(8_193, 3, "ice_candidate");
      expect(candidateTooLarge.status).toBe(413);
      expect(await candidateTooLarge.json()).toMatchObject({ code: "payload_too_large" });
      const controlTooLarge = await send(2_049, 4, "control");
      expect(controlTooLarge.status).toBe(413);
      expect(await controlTooLarge.json()).toMatchObject({ code: "payload_too_large" });
    } finally {
      await server.stop(true);
    }
  });

  test("telemetry accepts only pinned buckets, is participant-scoped, and rejects PII-shaped input", async () => {
    const { alice, bob, dialogId } = await pair();
    const carol = await account("+16505551102", "Carol");
    await registerVoIPPushToken(db, bob.deviceId, "e5".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const callerCommitment = callerCommitmentV1(ctx, { publicKey: bytes(3), nonce: bytes(35), fingerprint: bytes(67) });
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitment.toString("base64"), supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    });

    const report = {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      outcome: "completed", routeClass: "relay_tls", privacyMode: "relay_only",
      setupBucket: "le_3s", recoveryBucket: "none", rttBucket: "le_200", lossBucket: "le_5",
      jitterBucket: "le_30", bitrateBucket: "le_32", recoveryCount: 2, appVersion: "0.1.0.0", region: "eu-central",
    };
    expect(await recordCallTelemetry(db, report)).toEqual({ recorded: true });
    expect(await recordCallTelemetry(db, report)).toEqual({ recorded: true });
    expect((await db`SELECT count(*)::int AS count FROM call_telemetry_reports WHERE call_id = ${callId}`)[0].count)
      .toBe(1);

    // A bucket value outside the pinned enumeration is rejected.
    await expect(recordCallTelemetry(db, { ...report, rttBucket: "le_9999" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    // A required field is enforced.
    await expect(recordCallTelemetry(db, { ...report, outcome: undefined }))
      .rejects.toMatchObject({ code: "invalid_request" });
    // appVersion must match the safe numeric shape; free text (potential PII) is refused.
    await expect(recordCallTelemetry(db, { ...report, appVersion: "leak; DROP" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    // A non-participant cannot report telemetry for a call and cannot even confirm it exists.
    await expect(recordCallTelemetry(db, { ...report, accountId: carol.accountId, deviceId: carol.deviceId }))
      .rejects.toMatchObject({ code: "not_found" });

    // The HTTP route returns 202 for a valid report and 400 for an invalid one.
    const server = startCloudServer(0, db, null, null);
    const url = `http://127.0.0.1:${server.port}/v1/calls/${callId}/telemetry`;
    try {
      const ok = await fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${bob.token}`, "content-type": "application/json" },
        body: JSON.stringify({ outcome: "completed", rttBucket: "le_100" }),
      });
      expect(ok.status).toBe(202);
      expect(await ok.json()).toEqual({ recorded: true });
      const bad = await fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${bob.token}`, "content-type": "application/json" },
        body: JSON.stringify({ outcome: "not_a_real_outcome" }),
      });
      expect(bad.status).toBe(400);
    } finally {
      await server.stop(true);
    }
  });
});
