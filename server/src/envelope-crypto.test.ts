import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import { bodyAAD, open as legacyOpen, seal as legacySeal } from "./crypto";
import { makeSql } from "./db";
import { lockMutationKeys } from "./locks";
import { refreshV2Session, upgradeLegacySession } from "./session-security";
import {
  activateCryptoWriteMode,
  assertCryptoConfiguration,
  CryptoUnavailableError,
  EnvelopeCrypto,
  envelopeReadiness,
  envelopeSchemaReadiness,
  LocalDevelopmentKeyProvider,
  openForScope,
  preloadEnvelopeKeys,
  registerKeyEncryptionProvider,
  resetEnvelopeCryptoInstancesForTests,
  retireDataKey,
  unregisterKeyEncryptionProvider,
  type GeneratedDataKey,
  type KeyEncryptionProvider,
  type KeyScope,
  type WrappedDataKey,
} from "./envelope-crypto";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

class ControllableProvider implements KeyEncryptionProvider {
  private readonly base = new LocalDevelopmentKeyProvider(Buffer.alloc(32, 0x44), "test-kek");
  readonly providerId = this.base.providerId;
  unwraps = 0;
  unavailable = false;
  wrongRewrap = false;
  unwrapGate: Promise<void> | null = null;
  unwrapStarted: (() => void) | null = null;

  async generateAndWrap(scope: KeyScope, keyId: string): Promise<GeneratedDataKey> {
    if (this.unavailable) throw new CryptoUnavailableError();
    return await this.base.generateAndWrap(scope, keyId);
  }

  async unwrap(scope: KeyScope, keyId: string, wrapped: WrappedDataKey): Promise<Buffer> {
    this.unwraps += 1;
    if (this.unavailable) throw new CryptoUnavailableError();
    this.unwrapStarted?.();
    this.unwrapStarted = null;
    if (this.unwrapGate) await this.unwrapGate;
    return await this.base.unwrap(scope, keyId, wrapped);
  }

  async rewrap(scope: KeyScope, keyId: string, wrapped: WrappedDataKey): Promise<GeneratedDataKey> {
    if (this.unavailable) throw new CryptoUnavailableError();
    if (this.wrongRewrap) return await this.base.generateAndWrap(scope, keyId);
    return await this.base.rewrap(scope, keyId, wrapped);
  }

  async healthCheck(): Promise<void> {
    if (this.unavailable) throw new CryptoUnavailableError();
  }
}

async function makeAccount() {
  const { code } = await startVerification(db, "+16505559201");
  return await checkVerification(db, "+16505559201", code, "ios", "Test iPhone", "Alice");
}

async function resetCryptoWriteState(): Promise<void> {
  await db`ALTER TABLE crypto_write_state DISABLE TRIGGER crypto_write_state_guard`;
  try {
    await db`UPDATE crypto_write_state
      SET write_mode = 'legacy', epoch = 1, updated_at = now() WHERE singleton`;
  } finally {
    await db`ALTER TABLE crypto_write_state ENABLE TRIGGER crypto_write_state_guard`;
  }
}

async function waitForAdvisoryWaiters(expected: number): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    const row = (await db`
      SELECT count(*)::int AS count
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND pid <> pg_backend_pid()
        AND wait_event_type = 'Lock'
        AND wait_event = 'advisory'`)[0];
    if (Number(row?.count ?? 0) >= expected) return;
    await Bun.sleep(5);
  }
  throw new Error(`expected ${expected} blocked advisory-lock waiters`);
}

async function settleLockCycle(
  operations: Promise<unknown>[],
  description: string,
): Promise<PromiseSettledResult<unknown>[]> {
  let timeout: ReturnType<typeof setTimeout> | null = null;
  try {
    return await Promise.race([
      Promise.allSettled(operations),
      new Promise<never>((_resolve, reject) => {
        timeout = setTimeout(() => reject(new Error(`${description} did not settle`)), 5_000);
      }),
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

function expectDatabaseDetectedLockCycle(results: PromiseSettledResult<unknown>[]): void {
  expect(results.some((result) => result.status === "fulfilled")).toBe(true);
  const failures = results.flatMap((result) => result.status === "rejected"
    ? [String(result.reason)]
    : []);
  expect(failures.some((failure) => failure.includes("deadlock detected"))).toBe(true);
}

async function readSubprocessLine(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  state: { buffer: string },
): Promise<string> {
  while (!state.buffer.includes("\n")) {
    const chunk = await reader.read();
    if (chunk.done) throw new Error(`envelope cache subprocess ended early: ${state.buffer}`);
    state.buffer += new TextDecoder().decode(chunk.value);
  }
  const newline = state.buffer.indexOf("\n");
  const line = state.buffer.slice(0, newline);
  state.buffer = state.buffer.slice(newline + 1);
  return line;
}

beforeEach(async () => {
  await resetCryptoWriteState();
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
  delete process.env.TOJ_ENVELOPE_CANARY_ACCOUNTS;
  delete process.env.TOJ_ENVELOPE_CANARY_PERCENT;
});

afterAll(async () => {
  await db.close();
});

describe.serial("provider-neutral envelope encryption", () => {
  test("schema readiness rejects an invalid or missing required index", async () => {
    expect(await envelopeSchemaReadiness(db)).toEqual({ ready: true, missing: [] });
    let incomplete: Awaited<ReturnType<typeof envelopeSchemaReadiness>> | null = null;
    try {
      await db.begin(async (tx) => {
        await tx`DROP INDEX messages_body_key_migration_idx`;
        incomplete = await envelopeSchemaReadiness(tx);
        throw new Error("rollback readiness fixture");
      });
    } catch (error) {
      expect(String(error)).toContain("rollback readiness fixture");
    }
    expect(incomplete?.ready).toBe(false);
    expect(incomplete?.missing).toContain("messages_body_key_migration_idx");

    let disabledTrigger: Awaited<ReturnType<typeof envelopeSchemaReadiness>> | null = null;
    try {
      await db.begin(async (tx) => {
        await tx`ALTER TABLE messages DISABLE TRIGGER crypto_write_fence_messages_body_key_id`;
        disabledTrigger = await envelopeSchemaReadiness(tx);
        throw new Error("rollback trigger fixture");
      });
    } catch (error) {
      expect(String(error)).toContain("rollback trigger fixture");
    }
    expect(disabledTrigger?.ready).toBe(false);
    expect(disabledTrigger?.missing).toContain("crypto_write_fence_messages_body_key_id");

    let disabledReceiptTrigger: Awaited<ReturnType<typeof envelopeSchemaReadiness>> | null = null;
    try {
      await db.begin(async (tx) => {
        await tx`ALTER TABLE session_rotation_receipts DISABLE TRIGGER
          crypto_write_fence_session_rotation_receipts_response_key_id`;
        disabledReceiptTrigger = await envelopeSchemaReadiness(tx);
        throw new Error("rollback receipt-trigger fixture");
      });
    } catch (error) {
      expect(String(error)).toContain("rollback receipt-trigger fixture");
    }
    expect(disabledReceiptTrigger?.ready).toBe(false);
    expect(disabledReceiptTrigger?.missing).toContain(
      "crypto_write_fence_session_rotation_receipts_response_key_id",
    );
  });

  test("transaction batches resolve one active key only once per scope", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    await db.begin(async (tx) => {
      let calls = 0;
      const counted = new Proxy(tx, {
        apply(target, _thisArg, argumentsList) {
          calls += 1;
          return Reflect.apply(target, target, argumentsList);
        },
      });
      const crypto = new EnvelopeCrypto(counted, { mode: "envelope", activeProvider: provider });
      const scope: KeyScope = { kind: "account", accountId: account.accountId };
      await crypto.seal(scope, "one", Buffer.from("one"), true, true);
      const firstCalls = calls;
      await crypto.seal(scope, "two", Buffer.from("two"), true, true);
      expect(calls).toBe(firstCalls);
    });
  });

  test("creates an account DEK, authenticates scope and AAD, and dual-reads legacy", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const aad = bodyAAD(cryptoUUID(), 1, account.accountId);
    const sealed = await crypto.seal(scope, "secret", aad);
    expect(sealed.keyId).not.toBe("dev-v1");
    expect((await crypto.open(scope, sealed, aad)).toString()).toBe("secret");
    await expect(crypto.open(scope, sealed, Buffer.from("wrong"))).rejects.toThrow("authentication failed");

    const other = await checkVerification(
      db,
      "+16505559202",
      (await startVerification(db, "+16505559202")).code,
      "ios",
      "Other iPhone",
      "Bob",
    );
    await expect(crypto.open(
      { kind: "account", accountId: other.accountId },
      sealed,
      aad,
    )).rejects.toThrow("scope mismatch");

    const legacy = legacySeal("old", aad);
    expect((await crypto.open(scope, legacy, aad)).toString()).toBe("old");
  });

  test("uses cached keys during an outage and fails closed on a cache miss", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const aad = Buffer.from("cache-test");
    const sealed = await crypto.seal(scope, "cached", aad);
    provider.unavailable = true;
    expect((await crypto.open(scope, sealed, aad)).toString()).toBe("cached");
    crypto.clearCache();
    await expect(crypto.open(scope, sealed, aad)).rejects.toBeInstanceOf(CryptoUnavailableError);
  });

  test("single-flights unwraps and keeps caller-owned keys safe across eviction", async () => {
    const firstAccount = await makeAccount();
    const secondAccount = await checkVerification(
      db,
      "+16505559204",
      (await startVerification(db, "+16505559204")).code,
      "ios",
      "Cache iPhone",
      "Cache",
    );
    const provider = new ControllableProvider();
    const writer = new EnvelopeCrypto(db, {
      mode: "envelope", activeProvider: provider, cacheSize: 2,
    });
    const firstScope: KeyScope = { kind: "account", accountId: firstAccount.accountId };
    const secondScope: KeyScope = { kind: "account", accountId: secondAccount.accountId };
    const first = await writer.seal(firstScope, "first", Buffer.from("eviction-first"));
    const second = await writer.seal(secondScope, "second", Buffer.from("eviction-second"));
    writer.clearCache();

    const reader = new EnvelopeCrypto(db, {
      mode: "envelope", activeProvider: provider, cacheSize: 1,
    });
    provider.unwraps = 0;
    const sameKeyReads = await Promise.all(Array.from({ length: 16 }, () =>
      reader.open(firstScope, first, Buffer.from("eviction-first"))
    ));
    expect(provider.unwraps).toBe(1);
    expect(sameKeyReads.every((value) => value.toString() === "first")).toBe(true);
    for (const value of sameKeyReads) value.fill(0);

    reader.clearCache();
    provider.unwraps = 0;
    let releaseBarrier!: () => void;
    provider.unwrapGate = new Promise<void>((resolve) => { releaseBarrier = resolve; });
    const barrierReads = [
      reader.open(firstScope, first, Buffer.from("eviction-first")),
      reader.open(secondScope, second, Buffer.from("eviction-second")),
    ];
    const deadline = Date.now() + 2_000;
    while (provider.unwraps < 2 && Date.now() < deadline) await Bun.sleep(1);
    expect(provider.unwraps).toBe(2);
    releaseBarrier();
    const [barrierFirst, barrierSecond] = await Promise.all(barrierReads);
    expect(barrierFirst.toString()).toBe("first");
    expect(barrierSecond.toString()).toBe("second");
    barrierFirst.fill(0);
    barrierSecond.fill(0);
    provider.unwrapGate = null;

    reader.clearCache();
    provider.unwraps = 0;
    for (let iteration = 0; iteration < 20; iteration += 1) {
      const [openedFirst, openedSecond] = await Promise.all([
        reader.open(firstScope, first, Buffer.from("eviction-first")),
        reader.open(secondScope, second, Buffer.from("eviction-second")),
      ]);
      expect(openedFirst.toString()).toBe("first");
      expect(openedSecond.toString()).toBe("second");
      openedFirst.fill(0);
      openedSecond.fill(0);
      reader.clearCache();
    }
    expect(provider.unwraps).toBe(40);
  });

  test("rotation immediately changes new writes while old ciphertext remains readable", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const first = await crypto.seal(scope, "before", Buffer.from("rotation"));
    const rotation = await crypto.rotate(scope);
    expect(rotation.previousKeyId).toBe(first.keyId);
    const second = await crypto.seal(scope, "after", Buffer.from("rotation"));
    expect(second.keyId).toBe(rotation.activeKeyId);
    expect(second.keyId).not.toBe(first.keyId);
    expect((await crypto.open(scope, first, Buffer.from("rotation"))).toString()).toBe("before");
    expect((await crypto.open(scope, second, Buffer.from("rotation"))).toString()).toBe("after");
    const states = await db`SELECT state FROM account_data_keys
      WHERE account_id = ${account.accountId} ORDER BY version`;
    expect(states.map((row: any) => row.state)).toEqual(["retiring", "active"]);
  });

  test("rotation waits for an in-flight writer before switching the active key", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const initial = await crypto.seal(scope, "initial", Buffer.from("rotation-writer-initial"));

    let writerReady!: () => void;
    const writerHasFence = new Promise<void>((resolve) => { writerReady = resolve; });
    let releaseWriter!: () => void;
    const writerGate = new Promise<void>((resolve) => { releaseWriter = resolve; });
    let writerSealed: Awaited<ReturnType<EnvelopeCrypto["seal"]>> | null = null;
    const writer = db.begin(async (tx) => {
      const writerCrypto = new EnvelopeCrypto(tx, {
        mode: "envelope",
        activeProvider: provider,
      });
      writerSealed = await writerCrypto.seal(
        scope,
        "in flight",
        Buffer.from("rotation-writer-in-flight"),
      );
      writerReady();
      await writerGate;
    });
    await writerHasFence;

    let rotationFinished = false;
    const rotation = crypto.rotate(scope).then((value) => {
      rotationFinished = true;
      return value;
    });
    await Bun.sleep(50);
    expect(rotationFinished).toBe(false);

    releaseWriter();
    await writer;
    const rotated = await rotation;
    expect(writerSealed?.keyId).toBe(initial.keyId);
    expect(rotated.previousKeyId).toBe(initial.keyId);
    const after = await crypto.seal(scope, "after", Buffer.from("rotation-writer-after"));
    expect(after.keyId).toBe(rotated.activeKeyId);
    expect(after.keyId).not.toBe(writerSealed?.keyId);
  });

  test("an exclusive-fence writer never joins an unwrap flight waiting on its fence", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const reader = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const originalAAD = Buffer.from("lock-cycle-original");
    const original = await reader.seal(scope, "original", originalAAD);
    reader.clearCache();

    let fenceHeld!: () => void;
    const hasFence = new Promise<void>((resolve) => { fenceHeld = resolve; });
    let startWriter!: () => void;
    const writerMayStart = new Promise<void>((resolve) => { startWriter = resolve; });
    let releaseWriter!: () => void;
    const writerMayCommit = new Promise<void>((resolve) => { releaseWriter = resolve; });
    let writerSealed!: (value: Awaited<ReturnType<EnvelopeCrypto["seal"]>>) => void;
    const writerResult = new Promise<Awaited<ReturnType<EnvelopeCrypto["seal"]>>>((resolve) => {
      writerSealed = resolve;
    });

    const writer = db.begin(async (tx) => {
      await lockMutationKeys(tx, [`envelope-key:account:${account.accountId}`]);
      fenceHeld();
      await writerMayStart;
      const crypto = new EnvelopeCrypto(tx, { mode: "envelope", activeProvider: provider });
      writerSealed(await crypto.seal(scope, "writer", Buffer.from("lock-cycle-writer")));
      await writerMayCommit;
    });
    await hasFence;

    // This cache-miss reader publishes a global single-flight and then waits for the writer's
    // shared scope fence. The writer must bypass that flight because it already owns the exclusive
    // fence; joining it creates a JavaScript/PostgreSQL lock cycle that PostgreSQL cannot detect.
    const blockedReader = reader.open(scope, original, originalAAD);
    await Bun.sleep(50);
    startWriter();
    let timeout: ReturnType<typeof setTimeout> | null = null;
    try {
      const sealed = await Promise.race([
        writerResult,
        new Promise<never>((_resolve, reject) => {
          timeout = setTimeout(() => reject(new Error("exclusive-fence writer deadlocked")), 1_000);
        }),
      ]);
      expect(sealed.keyId).toBe(original.keyId);
    } finally {
      if (timeout) clearTimeout(timeout);
      releaseWriter();
    }
    await writer;
    const opened = await blockedReader;
    expect(opened.toString()).toBe("original");
    opened.fill(0);
  });

  test("an exclusive-fence transaction never preloads through a flight waiting on its fence", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    registerKeyEncryptionProvider(provider);
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const reader = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const aad = Buffer.from("preload-lock-cycle-original");
    const original = await reader.seal(scope, "original", aad);
    reader.clearCache();

    let fenceHeld!: () => void;
    const hasFence = new Promise<void>((resolve) => { fenceHeld = resolve; });
    let startPreload!: () => void;
    const preloadMayStart = new Promise<void>((resolve) => { startPreload = resolve; });
    let preloadFinished!: () => void;
    const preloadResult = new Promise<void>((resolve) => { preloadFinished = resolve; });
    let releaseWriter!: () => void;
    const writerMayCommit = new Promise<void>((resolve) => { releaseWriter = resolve; });

    const writer = db.begin(async (tx) => {
      const crypto = new EnvelopeCrypto(tx, { mode: "envelope", activeProvider: provider });
      // This mirrors draft mutation: sealing marks the account scope as exclusively fenced, then
      // a response load preloads ciphertext keys before the surrounding transaction commits.
      await crypto.seal(scope, "writer", Buffer.from("preload-lock-cycle-writer"));
      crypto.clearCache();
      fenceHeld();
      await preloadMayStart;
      await preloadEnvelopeKeys(tx, [original.keyId]);
      preloadFinished();
      await writerMayCommit;
    });
    await hasFence;

    const blockedReader = reader.open(scope, original, aad);
    await Bun.sleep(50);
    startPreload();
    let timeout: ReturnType<typeof setTimeout> | null = null;
    try {
      await Promise.race([
        preloadResult,
        new Promise<never>((_resolve, reject) => {
          timeout = setTimeout(() => reject(new Error("exclusive-fence preload deadlocked")), 1_000);
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
      releaseWriter();
    }
    await writer;
    const opened = await blockedReader;
    expect(opened.toString()).toBe("original");
    opened.fill(0);
    unregisterKeyEncryptionProvider(provider.providerId);
  });

  test("an exclusive-fence transaction never opens through a flight waiting on its fence", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    registerKeyEncryptionProvider(provider);
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const reader = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const aad = Buffer.from("open-lock-cycle-original");
    const original = await reader.seal(scope, "original", aad);
    reader.clearCache();

    let fenceHeld!: () => void;
    const hasFence = new Promise<void>((resolve) => { fenceHeld = resolve; });
    let startOpen!: () => void;
    const openMayStart = new Promise<void>((resolve) => { startOpen = resolve; });
    let openFinished!: () => void;
    const openResult = new Promise<void>((resolve) => { openFinished = resolve; });
    let releaseWriter!: () => void;
    const writerMayCommit = new Promise<void>((resolve) => { releaseWriter = resolve; });

    const writer = db.begin(async (tx) => {
      const crypto = new EnvelopeCrypto(tx, { mode: "envelope", activeProvider: provider });
      await crypto.seal(scope, "writer", Buffer.from("open-lock-cycle-writer"));
      crypto.clearCache();
      fenceHeld();
      await openMayStart;
      const opened = await openForScope(tx, scope, original, aad);
      expect(opened.toString()).toBe("original");
      opened.fill(0);
      openFinished();
      await writerMayCommit;
    });
    await hasFence;

    const blockedReader = reader.open(scope, original, aad);
    await Bun.sleep(50);
    startOpen();
    let timeout: ReturnType<typeof setTimeout> | null = null;
    try {
      await Promise.race([
        openResult,
        new Promise<never>((_resolve, reject) => {
          timeout = setTimeout(() => reject(new Error("exclusive-fence open deadlocked")), 1_000);
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
      releaseWriter();
    }
    await writer;
    const opened = await blockedReader;
    expect(opened.toString()).toBe("original");
    opened.fill(0);
    unregisterKeyEncryptionProvider(provider.providerId);
  });

  test("cross-scope opens expose a two-transaction fence cycle to PostgreSQL", async () => {
    const firstAccount = await makeAccount();
    const secondAccount = await checkVerification(
      db,
      "+16505559203",
      (await startVerification(db, "+16505559203")).code,
      "ios",
      "Second iPhone",
      "Bob",
    );
    const provider = new ControllableProvider();
    const firstScope: KeyScope = { kind: "account", accountId: firstAccount.accountId };
    const secondScope: KeyScope = { kind: "account", accountId: secondAccount.accountId };
    const firstAAD = Buffer.from("cross-scope-open-first");
    const secondAAD = Buffer.from("cross-scope-open-second");
    const reader = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const first = await reader.seal(firstScope, "first", firstAAD);
    const second = await reader.seal(secondScope, "second", secondAAD);

    let firstFenced!: () => void;
    let secondFenced!: () => void;
    const firstHasFence = new Promise<void>((resolve) => { firstFenced = resolve; });
    const secondHasFence = new Promise<void>((resolve) => { secondFenced = resolve; });
    let beginCrossReads!: () => void;
    const crossReadsMayBegin = new Promise<void>((resolve) => { beginCrossReads = resolve; });

    const firstTransaction = db.begin(async (tx) => {
      await tx`SELECT set_config('deadlock_timeout', '50ms', true),
                      set_config('idle_in_transaction_session_timeout', '2s', true)`;
      const crypto = new EnvelopeCrypto(tx, { mode: "envelope", activeProvider: provider });
      await crypto.seal(firstScope, "hold first fence", Buffer.from("hold-first-fence"));
      firstFenced();
      await crossReadsMayBegin;
      const opened = await crypto.open(secondScope, second, secondAAD);
      expect(opened.toString()).toBe("second");
      opened.fill(0);
    });
    const secondTransaction = db.begin(async (tx) => {
      await tx`SELECT set_config('deadlock_timeout', '50ms', true),
                      set_config('idle_in_transaction_session_timeout', '2s', true)`;
      const crypto = new EnvelopeCrypto(tx, { mode: "envelope", activeProvider: provider });
      await crypto.seal(secondScope, "hold second fence", Buffer.from("hold-second-fence"));
      secondFenced();
      await crossReadsMayBegin;
      const opened = await crypto.open(firstScope, first, firstAAD);
      expect(opened.toString()).toBe("first");
      opened.fill(0);
    });
    await Promise.all([firstHasFence, secondHasFence]);

    // Publish one process-global flight behind each exclusive fence. Joining those flights from
    // the opposite transaction would hide the A -> B -> A cycle from PostgreSQL forever.
    reader.clearCache();
    const blockedFirst = reader.open(firstScope, first, firstAAD);
    const blockedSecond = reader.open(secondScope, second, secondAAD);
    await waitForAdvisoryWaiters(2);
    beginCrossReads();

    const results = await settleLockCycle(
      [firstTransaction, secondTransaction],
      "cross-scope open lock cycle",
    );
    expectDatabaseDetectedLockCycle(results);
    const [openedFirst, openedSecond] = await Promise.all([blockedFirst, blockedSecond]);
    expect(openedFirst.toString()).toBe("first");
    expect(openedSecond.toString()).toBe("second");
    openedFirst.fill(0);
    openedSecond.fill(0);
  });

  test("mixed-scope preloads expose a two-transaction fence cycle to PostgreSQL", async () => {
    const firstAccount = await makeAccount();
    const secondAccount = await checkVerification(
      db,
      "+16505559203",
      (await startVerification(db, "+16505559203")).code,
      "ios",
      "Second iPhone",
      "Bob",
    );
    const provider = new ControllableProvider();
    registerKeyEncryptionProvider(provider);
    try {
      const firstScope: KeyScope = { kind: "account", accountId: firstAccount.accountId };
      const secondScope: KeyScope = { kind: "account", accountId: secondAccount.accountId };
      const firstAAD = Buffer.from("cross-scope-preload-first");
      const secondAAD = Buffer.from("cross-scope-preload-second");
      const reader = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
      const first = await reader.seal(firstScope, "first", firstAAD);
      const second = await reader.seal(secondScope, "second", secondAAD);

      let firstFenced!: () => void;
      let secondFenced!: () => void;
      const firstHasFence = new Promise<void>((resolve) => { firstFenced = resolve; });
      const secondHasFence = new Promise<void>((resolve) => { secondFenced = resolve; });
      let beginPreloads!: () => void;
      const preloadsMayBegin = new Promise<void>((resolve) => { beginPreloads = resolve; });

      const firstTransaction = db.begin(async (tx) => {
        await tx`SELECT set_config('deadlock_timeout', '50ms', true),
                        set_config('idle_in_transaction_session_timeout', '2s', true)`;
        const crypto = new EnvelopeCrypto(tx, { mode: "envelope", activeProvider: provider });
        await crypto.seal(firstScope, "hold first fence", Buffer.from("preload-first-fence"));
        firstFenced();
        await preloadsMayBegin;
        await preloadEnvelopeKeys(tx, [second.keyId]);
      });
      const secondTransaction = db.begin(async (tx) => {
        await tx`SELECT set_config('deadlock_timeout', '50ms', true),
                        set_config('idle_in_transaction_session_timeout', '2s', true)`;
        const crypto = new EnvelopeCrypto(tx, { mode: "envelope", activeProvider: provider });
        await crypto.seal(secondScope, "hold second fence", Buffer.from("preload-second-fence"));
        secondFenced();
        await preloadsMayBegin;
        await preloadEnvelopeKeys(tx, [first.keyId]);
      });
      await Promise.all([firstHasFence, secondHasFence]);

      reader.clearCache();
      const blockedFirst = reader.open(firstScope, first, firstAAD);
      const blockedSecond = reader.open(secondScope, second, secondAAD);
      await waitForAdvisoryWaiters(2);
      beginPreloads();

      const results = await settleLockCycle(
        [firstTransaction, secondTransaction],
        "mixed-scope preload lock cycle",
      );
      expectDatabaseDetectedLockCycle(results);
      const [openedFirst, openedSecond] = await Promise.all([blockedFirst, blockedSecond]);
      expect(openedFirst.toString()).toBe("first");
      expect(openedSecond.toString()).toBe("second");
      openedFirst.fill(0);
      openedSecond.fill(0);
    } finally {
      unregisterKeyEncryptionProvider(provider.providerId);
    }
  });

  test("rewrap verifies the replacement DEK before committing provider metadata", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const aad = Buffer.from("rewrap-verification");
    const sealed = await crypto.seal(scope, "preserve me", aad);
    const before = Buffer.from((await db`
      SELECT wrapped_key FROM account_data_keys WHERE id = ${sealed.keyId}`)[0].wrapped_key);

    provider.wrongRewrap = true;
    await expect(crypto.rewrap(sealed.keyId)).rejects.toMatchObject({
      code: "crypto_unavailable",
    });
    const after = Buffer.from((await db`
      SELECT wrapped_key FROM account_data_keys WHERE id = ${sealed.keyId}`)[0].wrapped_key);
    expect(after.equals(before)).toBe(true);
    crypto.clearCache();
    expect((await crypto.open(scope, sealed, aad)).toString()).toBe("preserve me");
  });

  test("revocation waits for an in-flight unwrap and prevents it from repopulating afterward", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const aad = Buffer.from("retirement-race");
    const sealed = await crypto.seal(scope, "retire me", aad);
    await crypto.rotate(scope);
    await db`UPDATE account_data_keys SET retiring_at = now() - interval '2 days'
      WHERE id = ${sealed.keyId}`;
    crypto.clearCache();

    let releaseUnwrap!: () => void;
    provider.unwrapGate = new Promise<void>((resolve) => { releaseUnwrap = resolve; });
    let unwrapStarted!: () => void;
    const started = new Promise<void>((resolve) => { unwrapStarted = resolve; });
    provider.unwrapStarted = unwrapStarted;
    const opening = crypto.open(scope, sealed, aad);
    await started;
    process.env.TOJ_CRYPTO_RETIREMENT_GRACE_DAYS = "1";
    let retirementFinished = false;
    try {
      const retirement = retireDataKey(db, sealed.keyId).then((result) => {
        retirementFinished = true;
        return result;
      });
      await Bun.sleep(50);
      expect(retirementFinished).toBe(false);
      releaseUnwrap();
      const opened = await opening;
      expect(opened.toString()).toBe("retire me");
      opened.fill(0);
      expect(await retirement).toMatchObject({ keyId: sealed.keyId, state: "draining" });
      await expect(crypto.open(scope, sealed, aad)).rejects.toThrow(`unknown key_id ${sealed.keyId}`);

      await db`UPDATE account_data_keys
        SET revocation_started_at = now() - interval '10 minutes' WHERE id = ${sealed.keyId}`;
      expect(await retireDataKey(db, sealed.keyId)).toEqual({
        keyId: sealed.keyId, state: "retired", finalizeAfter: null,
      });
    } finally {
      delete process.env.TOJ_CRYPTO_RETIREMENT_GRACE_DAYS;
    }
    await expect(crypto.open(scope, sealed, aad)).rejects.toThrow(`unknown key_id ${sealed.keyId}`);
  });

  test("cross-process retirement drains cached plaintext before wrapped-key erasure", async () => {
    const account = await makeAccount();
    const provider = new LocalDevelopmentKeyProvider();
    const crypto = new EnvelopeCrypto(db, {
      mode: "envelope", activeProvider: provider, cacheTTL: 5,
    });
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const aad = Buffer.from("cross-process-retirement");
    const sealed = await crypto.seal(scope, "retired plaintext", aad);
    await crypto.rotate(scope);
    await db`UPDATE account_data_keys SET retiring_at = now() - interval '2 days'
      WHERE id = ${sealed.keyId}`;

    const child = Bun.spawn([
      process.execPath,
      new URL("./envelope-cache-reader.fixture.ts", import.meta.url).pathname,
      JSON.stringify({
        databaseURL: TEST_URL,
        accountId: account.accountId,
        keyId: sealed.keyId,
        nonce: sealed.nonce.toString("base64"),
        ciphertext: sealed.ciphertext.toString("base64"),
        aad: aad.toString("base64"),
      }),
    ], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    const reader = child.stdout.getReader();
    const output = { buffer: "" };
    let stdinEnded = false;
    try {
      expect(await readSubprocessLine(reader, output)).toBe("cached");
      process.env.TOJ_CRYPTO_RETIREMENT_GRACE_DAYS = "1";
      const draining = await retireDataKey(db, sealed.keyId);
      expect(draining).toMatchObject({ state: "draining" });
      expect((await db`SELECT state, revocation_started_at,
          octet_length(wrapped_key) AS wrapped_bytes
        FROM account_data_keys WHERE id = ${sealed.keyId}`)[0]).toMatchObject({
        state: "retiring",
      });
      expect(Number((await db`SELECT octet_length(wrapped_key) AS bytes
        FROM account_data_keys WHERE id = ${sealed.keyId}`)[0].bytes)).toBeGreaterThan(0);

      await Bun.sleep(25);
      await db`UPDATE account_data_keys
        SET revocation_started_at = now() - interval '10 minutes' WHERE id = ${sealed.keyId}`;
      expect(await retireDataKey(db, sealed.keyId)).toEqual({
        keyId: sealed.keyId, state: "retired", finalizeAfter: null,
      });
      expect((await db`SELECT state, octet_length(wrapped_key) AS bytes
        FROM account_data_keys WHERE id = ${sealed.keyId}`)[0]).toMatchObject({
        state: "retired", bytes: 0,
      });

      child.stdin.end();
      stdinEnded = true;
      expect(await readSubprocessLine(reader, output)).toBe("revoked");
      expect(await child.exited).toBe(0);
    } finally {
      delete process.env.TOJ_CRYPTO_RETIREMENT_GRACE_DAYS;
      if (!stdinEnded) child.stdin.end();
      if (child.exitCode == null) child.kill();
      await child.exited;
      reader.releaseLock();
    }
  });

  test("database final mode rejects changed legacy ciphertext and cannot skip canary", async () => {
    const account = await makeAccount();
    let directTransitionError: unknown;
    try {
      await db`UPDATE crypto_write_state
        SET write_mode = 'envelope', epoch = epoch + 1 WHERE singleton`;
    } catch (error) {
      directTransitionError = error;
    }
    expect(String(directTransitionError)).toContain("envelope-canary must precede");

    let fenceError: any;
    try {
      await db.begin(async (tx) => {
        await tx`UPDATE crypto_write_state
          SET write_mode = 'envelope-canary', epoch = epoch + 1 WHERE singleton`;
        await tx`UPDATE crypto_write_state
          SET write_mode = 'envelope', epoch = epoch + 1 WHERE singleton`;
        await tx`UPDATE accounts SET phone_nonce = ${Buffer.alloc(12, 0x7a)}
          WHERE id = ${account.accountId}`;
      });
    } catch (error) {
      fenceError = error;
    }
    expect(String(fenceError)).toContain("legacy ciphertext writes are disabled");
    expect((await db`SELECT write_mode FROM crypto_write_state WHERE singleton`)[0].write_mode)
      .toBe("legacy");
  });

  test("final writer cutover permits legacy rows while readiness reports migration debt", async () => {
    await makeAccount();
    try {
      process.env.TOJ_KEY_ENCRYPTION_PROVIDER = "local";
      process.env.TOJ_CRYPTO_MODE = "envelope-canary";
      resetEnvelopeCryptoInstancesForTests();
      const canary = await activateCryptoWriteMode(db, "envelope-canary");
      expect(canary).toMatchObject({ previousMode: "legacy", mode: "envelope-canary" });

      process.env.TOJ_CRYPTO_MODE = "envelope";
      resetEnvelopeCryptoInstancesForTests();
      const final = await activateCryptoWriteMode(db, "envelope");
      expect(final).toMatchObject({ previousMode: "envelope-canary", mode: "envelope" });

      const readiness = await envelopeReadiness(db);
      expect(readiness.databaseMode).toBe("envelope");
      expect(readiness.legacyReferences).toBeGreaterThan(0);
    } finally {
      await resetCryptoWriteState();
      delete process.env.TOJ_CRYPTO_MODE;
      delete process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
      resetEnvelopeCryptoInstancesForTests();
    }
    expect((await db`SELECT write_mode FROM crypto_write_state WHERE singleton`)[0].write_mode)
      .toBe("legacy");
  });

  test("final writer mode seals and idempotently replays v2 rotation receipts", async () => {
    const account = await makeAccount();
    const session = await upgradeLegacySession(db, account.accountId, account.deviceId);
    const rotationId = cryptoUUID();
    try {
      process.env.TOJ_KEY_ENCRYPTION_PROVIDER = "local";
      process.env.TOJ_CRYPTO_MODE = "envelope-canary";
      resetEnvelopeCryptoInstancesForTests();
      await activateCryptoWriteMode(db, "envelope-canary");

      process.env.TOJ_CRYPTO_MODE = "envelope";
      resetEnvelopeCryptoInstancesForTests();
      await activateCryptoWriteMode(db, "envelope");

      const rotated = await refreshV2Session(db, session.refreshToken, rotationId);
      expect(await refreshV2Session(db, session.refreshToken, rotationId)).toEqual(rotated);
      const receipt = (await db`
        SELECT response_key_id
        FROM session_rotation_receipts
        WHERE rotation_id = ${rotationId}`)[0];
      expect(String(receipt.response_key_id)).not.toBe("dev-v1");
    } finally {
      await resetCryptoWriteState();
      delete process.env.TOJ_CRYPTO_MODE;
      delete process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
      resetEnvelopeCryptoInstancesForTests();
    }
  });

  test("final writer activation fails closed for unsupported legacy report snapshots", async () => {
    const account = await makeAccount();
    try {
      await db`
        INSERT INTO user_reports (
          id, reporter_account_id, reported_account_id, reason,
          message_snapshot_ciphertext, message_snapshot_nonce, message_snapshot_key_id
        ) VALUES (
          ${cryptoUUID()}, ${account.accountId}, ${account.accountId}, 'other',
          ${Buffer.from("legacy")}, ${Buffer.alloc(12)}, 'dev-v1'
        )`;
      process.env.TOJ_KEY_ENCRYPTION_PROVIDER = "local";
      process.env.TOJ_CRYPTO_MODE = "envelope-canary";
      resetEnvelopeCryptoInstancesForTests();
      await activateCryptoWriteMode(db, "envelope-canary");

      process.env.TOJ_CRYPTO_MODE = "envelope";
      resetEnvelopeCryptoInstancesForTests();
      await expect(activateCryptoWriteMode(db, "envelope")).rejects.toThrow(
        "legacy user_reports snapshots must be resolved",
      );
      expect((await db`SELECT write_mode FROM crypto_write_state WHERE singleton`)[0].write_mode)
        .toBe("envelope-canary");
    } finally {
      await resetCryptoWriteState();
      delete process.env.TOJ_CRYPTO_MODE;
      delete process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
      resetEnvelopeCryptoInstancesForTests();
    }
  });

  test("final envelope startup can remove the legacy ciphertext secret after migration", () => {
    const aad = Buffer.from("legacy-retirement");
    const legacy = legacySeal("legacy", aad);
    const provider: KeyEncryptionProvider = {
      providerId: "test-kms",
      generateAndWrap: async () => { throw new Error("not used"); },
      unwrap: async () => { throw new Error("not used"); },
      rewrap: async () => { throw new Error("not used"); },
      healthCheck: async () => {},
    };
    const originalNodeEnvironment = process.env.NODE_ENV;
    const originalMode = process.env.TOJ_CRYPTO_MODE;
    const originalProvider = process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
    const originalMessageKey = process.env.TOJ_MESSAGE_KEY;
    const originalHmacKey = process.env.TOJ_HMAC_KEY;
    registerKeyEncryptionProvider(provider);
    try {
      process.env.NODE_ENV = "production";
      process.env.TOJ_CRYPTO_MODE = "envelope";
      process.env.TOJ_KEY_ENCRYPTION_PROVIDER = provider.providerId;
      process.env.TOJ_HMAC_KEY = Buffer.alloc(32, 0x0b).toString("base64");
      delete process.env.TOJ_MESSAGE_KEY;
      expect(() => assertCryptoConfiguration()).not.toThrow();
      expect(() => legacyOpen(legacy, aad)).toThrow("TOJ_MESSAGE_KEY required in production");

      process.env.TOJ_CRYPTO_MODE = "envelope-canary";
      expect(() => assertCryptoConfiguration()).toThrow("TOJ_MESSAGE_KEY required in production");
    } finally {
      if (originalNodeEnvironment == null) delete process.env.NODE_ENV;
      else process.env.NODE_ENV = originalNodeEnvironment;
      if (originalMode == null) delete process.env.TOJ_CRYPTO_MODE;
      else process.env.TOJ_CRYPTO_MODE = originalMode;
      if (originalProvider == null) delete process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
      else process.env.TOJ_KEY_ENCRYPTION_PROVIDER = originalProvider;
      if (originalMessageKey == null) delete process.env.TOJ_MESSAGE_KEY;
      else process.env.TOJ_MESSAGE_KEY = originalMessageKey;
      if (originalHmacKey == null) delete process.env.TOJ_HMAC_KEY;
      else process.env.TOJ_HMAC_KEY = originalHmacKey;
      unregisterKeyEncryptionProvider(provider.providerId);
      resetEnvelopeCryptoInstancesForTests();
    }
  });

  test("production envelope mode rejects the local development provider", () => {
    const originalNodeEnvironment = process.env.NODE_ENV;
    const originalMode = process.env.TOJ_CRYPTO_MODE;
    const originalProvider = process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
    const originalHmacKey = process.env.TOJ_HMAC_KEY;
    try {
      process.env.NODE_ENV = "production";
      process.env.TOJ_CRYPTO_MODE = "envelope";
      process.env.TOJ_KEY_ENCRYPTION_PROVIDER = "local";
      process.env.TOJ_HMAC_KEY = Buffer.alloc(32, 0x0b).toString("base64");
      expect(() => assertCryptoConfiguration()).toThrow(
        "the local key provider is forbidden in production",
      );
    } finally {
      if (originalNodeEnvironment == null) delete process.env.NODE_ENV;
      else process.env.NODE_ENV = originalNodeEnvironment;
      if (originalMode == null) delete process.env.TOJ_CRYPTO_MODE;
      else process.env.TOJ_CRYPTO_MODE = originalMode;
      if (originalProvider == null) delete process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
      else process.env.TOJ_KEY_ENCRYPTION_PROVIDER = originalProvider;
      if (originalHmacKey == null) delete process.env.TOJ_HMAC_KEY;
      else process.env.TOJ_HMAC_KEY = originalHmacKey;
      resetEnvelopeCryptoInstancesForTests();
    }
  });

  test("preloads unique keys, tolerates provider outage, and rejects unknown or corrupt material", async () => {
    const firstAccount = await makeAccount();
    const { code } = await startVerification(db, "+16505559203");
    const secondAccount = await checkVerification(
      db, "+16505559203", code, "ios", "Second iPhone", "Carol",
    );
    const provider = new ControllableProvider();
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const firstScope: KeyScope = { kind: "account", accountId: firstAccount.accountId };
    const secondScope: KeyScope = { kind: "account", accountId: secondAccount.accountId };
    const first = await crypto.seal(firstScope, "first", Buffer.from("preload-1"));
    const second = await crypto.seal(secondScope, "second", Buffer.from("preload-2"));
    crypto.clearCache();
    provider.unwraps = 0;
    await crypto.preload([first.keyId, first.keyId, second.keyId]);
    expect(provider.unwraps).toBe(2);
    provider.unavailable = true;
    expect((await crypto.open(firstScope, first, Buffer.from("preload-1"))).toString()).toBe("first");
    expect((await crypto.open(secondScope, second, Buffer.from("preload-2"))).toString()).toBe("second");
    await expect(crypto.open(firstScope, {
      keyId: cryptoUUID(), nonce: Buffer.alloc(12), ciphertext: Buffer.alloc(16),
    }, Buffer.from("unknown"))).rejects.toThrow("unknown key_id");
    await expect(crypto.open(firstScope, {
      ...first, ciphertext: Buffer.from(first.ciphertext.map((byte, index) => index ? byte : byte ^ 1)),
    }, Buffer.from("preload-1"))).rejects.toThrow("authentication failed");
  });

  test("fails before persistence when a provider returns malformed key material", async () => {
    const account = await makeAccount();
    const base = new ControllableProvider();
    const malformed: KeyEncryptionProvider = {
      providerId: base.providerId,
      async generateAndWrap(scope, keyId) {
        const generated = await base.generateAndWrap(scope, keyId);
        return { ...generated, plaintextKey: Buffer.alloc(1) };
      },
      unwrap: (...arguments_) => base.unwrap(...arguments_),
      rewrap: (...arguments_) => base.rewrap(...arguments_),
      healthCheck: () => base.healthCheck(),
    };
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: malformed });
    await expect(crypto.seal(
      { kind: "account", accountId: account.accountId }, "bad", Buffer.from("bad-provider"),
    )).rejects.toBeInstanceOf(CryptoUnavailableError);
    expect(await db`SELECT id FROM account_data_keys WHERE account_id = ${account.accountId}`)
      .toHaveLength(0);
  });

  test("retires only an unreferenced key after the configured rollback window", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const crypto = new EnvelopeCrypto(db, { mode: "envelope", activeProvider: provider });
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    const first = await crypto.seal(scope, "ephemeral", Buffer.from("retire"));
    await crypto.rotate(scope);
    await db`UPDATE account_data_keys SET retiring_at = now() - interval '2 days'
      WHERE id = ${first.keyId}`;
    process.env.TOJ_CRYPTO_RETIREMENT_GRACE_DAYS = "1";
    try {
      const draining = await retireDataKey(db, first.keyId);
      expect(draining).toMatchObject({ keyId: first.keyId, state: "draining" });
      expect(typeof draining.finalizeAfter).toBe("string");
      expect((await db`SELECT state, octet_length(wrapped_key) AS bytes
        FROM account_data_keys WHERE id = ${first.keyId}`)[0]).toMatchObject({
        state: "retiring",
      });
      await db`UPDATE account_data_keys
        SET revocation_started_at = now() - interval '10 minutes' WHERE id = ${first.keyId}`;
      expect(await retireDataKey(db, first.keyId)).toEqual({
        keyId: first.keyId, state: "retired", finalizeAfter: null,
      });
    } finally {
      delete process.env.TOJ_CRYPTO_RETIREMENT_GRACE_DAYS;
    }
    expect((await db`SELECT state, octet_length(wrapped_key) AS bytes
      FROM account_data_keys WHERE id = ${first.keyId}`)[0]).toMatchObject({
      state: "retired", bytes: 0,
    });
  });

  test("canary selection leaves non-selected account writes on the legacy key", async () => {
    const account = await makeAccount();
    const provider = new ControllableProvider();
    const scope: KeyScope = { kind: "account", accountId: account.accountId };
    process.env.TOJ_ENVELOPE_CANARY_ACCOUNTS = account.accountId;
    const selected = new EnvelopeCrypto(db, { mode: "envelope-canary", activeProvider: provider });
    expect((await selected.seal(scope, "selected", Buffer.from("canary"))).keyId).not.toBe("dev-v1");

    process.env.TOJ_ENVELOPE_CANARY_ACCOUNTS = "";
    const unselected = new EnvelopeCrypto(db, { mode: "envelope-canary", activeProvider: provider });
    expect((await unselected.seal(scope, "legacy", Buffer.from("canary"))).keyId).toBe("dev-v1");
  });
});

function cryptoUUID(): string {
  return crypto.randomUUID();
}
