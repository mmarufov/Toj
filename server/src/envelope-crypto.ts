import type { SQL } from "bun";
import {
  createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual,
} from "node:crypto";
import {
  assertLegacyMessageKeyConfigured,
  assertProtocolIdentifierConfiguration,
  open as legacyOpen,
  seal as legacySeal,
  type Sealed,
} from "./crypto";
import { lockMutationKeys, lockSharedMutationKeys } from "./locks";

const TAG_LENGTH = 16;
const DATA_KEY_BYTES = 32;
const DEFAULT_CACHE_SIZE = 256;
const DEFAULT_CACHE_TTL_MS = 5 * 60 * 1_000;
const MAX_CACHE_TTL_MS = 5 * 60 * 1_000;
// An open copies its cached key and performs AES-GCM synchronously. This extra minute means the
// final destructive pass cannot overlap a read that copied a key immediately before cache expiry,
// even under severe scheduler delay. New unwraps are fenced as soon as revocation starts.
const RETIREMENT_CACHE_DRAIN_MS = MAX_CACHE_TTL_MS + 60 * 1_000;

function zeroize(value: unknown): void {
  if (Buffer.isBuffer(value)) value.fill(0);
}

export type CryptoMode = "legacy" | "envelope-canary" | "envelope";
export type KeyScope =
  | { kind: "account"; accountId: string }
  | { kind: "service"; serviceName: string };

export type WrappedDataKey = {
  providerId: string;
  providerKeyReference: string;
  wrappedKey: Buffer;
};

export type GeneratedDataKey = WrappedDataKey & { plaintextKey: Buffer };

export interface KeyEncryptionProvider {
  readonly providerId: string;
  generateAndWrap(scope: KeyScope, keyId: string): Promise<GeneratedDataKey>;
  unwrap(scope: KeyScope, keyId: string, wrapped: WrappedDataKey): Promise<Buffer>;
  rewrap(scope: KeyScope, keyId: string, wrapped: WrappedDataKey): Promise<GeneratedDataKey>;
  healthCheck(): Promise<void>;
}

const registeredProviders = new Map<string, KeyEncryptionProvider>();

/**
 * Production provider adapters register during process bootstrap, before the cloud server starts.
 * The environment selects the provider by its stable providerId; credentials never enter this API.
 */
export function registerKeyEncryptionProvider(provider: KeyEncryptionProvider): void {
  if (!/^[a-z0-9][a-z0-9._-]{0,63}$/i.test(provider.providerId)) {
    throw new CryptoUnavailableError("key provider has an invalid providerId");
  }
  registeredProviders.set(provider.providerId, provider);
}

export function unregisterKeyEncryptionProvider(providerId: string): void {
  registeredProviders.delete(providerId);
}

export class CryptoUnavailableError extends Error {
  readonly code = "crypto_unavailable";
  readonly status = 503;

  constructor(message = "encryption key service unavailable") {
    super(message);
    this.name = "CryptoUnavailableError";
  }
}

function cryptoUnavailable(error: unknown): CryptoUnavailableError {
  return error instanceof CryptoUnavailableError ? error : new CryptoUnavailableError();
}

export class LocalDevelopmentKeyProvider implements KeyEncryptionProvider {
  readonly providerId = "local-development";
  private readonly wrappingKey: Buffer;
  private readonly keyReference: string;

  constructor(key?: Uint8Array, keyReference = "local-v1") {
    if (process.env.NODE_ENV === "production") {
      throw new CryptoUnavailableError("the local key provider is forbidden in production");
    }
    const configured = process.env.TOJ_LOCAL_KEY_ENCRYPTION_KEY;
    this.wrappingKey = key
      ? Buffer.from(key)
      : configured ? Buffer.from(configured, "base64") : Buffer.alloc(DATA_KEY_BYTES, 0x19);
    if (this.wrappingKey.length !== DATA_KEY_BYTES) {
      throw new CryptoUnavailableError("local key-encryption key must decode to 32 bytes");
    }
    this.keyReference = keyReference;
  }

  private aad(scope: KeyScope, keyId: string): Buffer {
    return Buffer.from(`toj/dek-wrap/v1|${scopeLabel(scope)}|${keyId}|${this.keyReference}`, "utf8");
  }

  private wrap(scope: KeyScope, keyId: string, plaintextKey: Buffer): WrappedDataKey {
    const nonce = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", this.wrappingKey, nonce);
    cipher.setAAD(this.aad(scope, keyId));
    const ciphertext = Buffer.concat([cipher.update(plaintextKey), cipher.final(), cipher.getAuthTag()]);
    return {
      providerId: this.providerId,
      providerKeyReference: this.keyReference,
      wrappedKey: Buffer.concat([nonce, ciphertext]),
    };
  }

  async generateAndWrap(scope: KeyScope, keyId: string): Promise<GeneratedDataKey> {
    const plaintextKey = randomBytes(DATA_KEY_BYTES);
    try {
      return { plaintextKey, ...this.wrap(scope, keyId, plaintextKey) };
    } catch (error) {
      zeroize(plaintextKey);
      throw error;
    }
  }

  async unwrap(scope: KeyScope, keyId: string, wrapped: WrappedDataKey): Promise<Buffer> {
    if (wrapped.providerId !== this.providerId || wrapped.providerKeyReference !== this.keyReference) {
      throw new CryptoUnavailableError("wrapped key belongs to an unavailable provider key");
    }
    if (wrapped.wrappedKey.length < 12 + TAG_LENGTH) {
      throw new CryptoUnavailableError("wrapped data key is corrupt");
    }
    const nonce = wrapped.wrappedKey.subarray(0, 12);
    const payload = wrapped.wrappedKey.subarray(12);
    const tag = payload.subarray(payload.length - TAG_LENGTH);
    const ciphertext = payload.subarray(0, payload.length - TAG_LENGTH);
    try {
      const decipher = createDecipheriv("aes-256-gcm", this.wrappingKey, nonce);
      decipher.setAAD(this.aad(scope, keyId));
      decipher.setAuthTag(tag);
      const key = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
      if (key.length !== DATA_KEY_BYTES) throw new Error("invalid data key length");
      return key;
    } catch {
      throw new CryptoUnavailableError("wrapped data key could not be unwrapped");
    }
  }

  async rewrap(scope: KeyScope, keyId: string, wrapped: WrappedDataKey): Promise<GeneratedDataKey> {
    const plaintextKey = await this.unwrap(scope, keyId, wrapped);
    try {
      return { plaintextKey, ...this.wrap(scope, keyId, plaintextKey) };
    } catch (error) {
      zeroize(plaintextKey);
      throw error;
    }
  }

  async healthCheck(): Promise<void> {
    const scope: KeyScope = { kind: "service", serviceName: "health-check" };
    const keyId = "00000000-0000-4000-8000-000000000000";
    const generated = await this.generateAndWrap(scope, keyId);
    let opened: Buffer | null = null;
    try {
      opened = await this.unwrap(scope, keyId, generated);
      if (!opened.equals(generated.plaintextKey)) throw new CryptoUnavailableError();
    } finally {
      zeroize(generated.plaintextKey);
      zeroize(opened);
    }
  }
}

type StoredKey = WrappedDataKey & {
  id: string;
  scope: KeyScope;
  version: number;
  state: "active" | "retiring" | "retired";
  revocationStartedAt: Date | null;
};

type CachedKey = {
  key: Buffer;
  scope: KeyScope;
  expiresAt: number;
  lastUsedAt: number;
  expirationTimer: ReturnType<typeof setTimeout> | null;
};
type InFlightKey = {
  // The provider-owned plaintext lives only until every caller that joined this unwrap has
  // copied it. The cache receives a distinct Buffer and can therefore evict/zeroize safely.
  promise: Promise<Buffer>;
  key: Buffer | null;
  waiters: number;
  settled: boolean;
  generation: number;
};
type SharedKeyState = {
  cache: Map<string, CachedKey>;
  inFlight: Map<string, InFlightKey>;
  generations: Map<string, number>;
  retired: Set<string>;
};

let sharedKeyState: SharedKeyState = {
  cache: new Map(), inFlight: new Map(), generations: new Map(), retired: new Set(),
};

function disposeCachedKey(keyId: string, expected?: CachedKey): void {
  const cached = sharedKeyState.cache.get(keyId);
  if (!cached || (expected && cached !== expected)) return;
  if (cached.expirationTimer) clearTimeout(cached.expirationTimer);
  cached.key.fill(0);
  sharedKeyState.cache.delete(keyId);
}

function invalidateSharedKey(keyId: string, retired = false): void {
  sharedKeyState.generations.set(keyId, (sharedKeyState.generations.get(keyId) ?? 0) + 1);
  if (retired) sharedKeyState.retired.add(keyId);
  disposeCachedKey(keyId);
}

function scopeLabel(scope: KeyScope): string {
  return scope.kind === "account" ? `account:${scope.accountId}` : `service:${scope.serviceName}`;
}

// Bun supplies a callback-scoped SQL object for each transaction. Remember only envelope fences
// acquired through this module, keyed by that object, so reads in the same transaction can avoid a
// process-global unwrap flight that may be waiting on their own exclusive PostgreSQL lock.
let transactionEnvelopeFences = new WeakMap<object, Set<string>>();

function isTransactionSQL(sql: SQL): boolean {
  return typeof (sql as SQL & { savepoint?: unknown }).savepoint === "function";
}

function markEnvelopeFenceHeld(sql: SQL, scope: KeyScope): void {
  if (!isTransactionSQL(sql)) return;
  const key = sql as unknown as object;
  const held = transactionEnvelopeFences.get(key) ?? new Set<string>();
  held.add(scopeLabel(scope));
  transactionEnvelopeFences.set(key, held);
}

function envelopeFenceHeld(sql: SQL, scope: KeyScope): boolean {
  return transactionEnvelopeFences.get(sql as unknown as object)?.has(scopeLabel(scope)) === true;
}

function transactionHasEnvelopeFences(sql: SQL): boolean {
  return (transactionEnvelopeFences.get(sql as unknown as object)?.size ?? 0) > 0;
}

/**
 * Migration workers already hold ciphertext-row locks when they reach the key fence. A normal
 * writer may hold this fence while waiting for one of those rows, so migrations must never wait
 * here or they could invert the writer lock order. Returning false lets the bounded batch commit
 * (and release its SKIP LOCKED rows) before retrying.
 */
export async function tryLockEnvelopeScopeForMigration(
  sql: SQL,
  scope: KeyScope,
): Promise<boolean> {
  const row = (await sql`
    SELECT pg_try_advisory_xact_lock(
      hashtextextended(${`envelope-key:${scopeLabel(scope)}`}, 0)
    ) AS acquired`)[0];
  const acquired = row?.acquired === true;
  if (acquired) markEnvelopeFenceHeld(sql, scope);
  return acquired;
}

function cryptoModeFromEnvironment(): CryptoMode {
  const value = process.env.TOJ_CRYPTO_MODE ?? "legacy";
  if (value === "legacy" || value === "envelope-canary" || value === "envelope") return value;
  throw new CryptoUnavailableError("TOJ_CRYPTO_MODE must be legacy, envelope-canary, or envelope");
}

function boundedNumber(value: string | undefined, fallback: number, min: number, max: number): number {
  const parsed = Number(value ?? fallback);
  return Number.isFinite(parsed) ? Math.max(min, Math.min(max, parsed)) : fallback;
}

function validateGeneratedDataKey(result: GeneratedDataKey, expectedProviderId: string): void {
  if (
    result.providerId !== expectedProviderId
    || !result.providerKeyReference
    || !Buffer.isBuffer(result.wrappedKey)
    || result.wrappedKey.length === 0
    || !Buffer.isBuffer(result.plaintextKey)
    || result.plaintextKey.length !== DATA_KEY_BYTES
  ) {
    result.plaintextKey?.fill?.(0);
    throw new CryptoUnavailableError("key provider returned invalid wrapped key material");
  }
}

function providerFromEnvironment(mode: CryptoMode): KeyEncryptionProvider | null {
  if (mode === "legacy") return null;
  const provider = process.env.TOJ_KEY_ENCRYPTION_PROVIDER
    ?? (process.env.NODE_ENV === "production" ? "" : "local");
  if (provider === "local") return new LocalDevelopmentKeyProvider();
  const registered = registeredProviders.get(provider);
  if (registered) return registered;
  throw new CryptoUnavailableError(
    "envelope mode requires a registered production KeyEncryptionProvider",
  );
}

function payloadAAD(scope: KeyScope, keyId: string, aad: Buffer): Buffer {
  return Buffer.concat([
    Buffer.from(`toj/envelope/v2|${scopeLabel(scope)}|${keyId}|`, "utf8"),
    aad,
  ]);
}

function encryptWithKey(key: Buffer, plaintext: Buffer | string, aad: Buffer): Omit<Sealed, "keyId"> {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(aad);
  const input = typeof plaintext === "string" ? Buffer.from(plaintext, "utf8") : plaintext;
  const ciphertext = Buffer.concat([cipher.update(input), cipher.final(), cipher.getAuthTag()]);
  return { nonce, ciphertext };
}

function decryptWithKey(key: Buffer, sealed: Sealed, aad: Buffer): Buffer {
  if (sealed.ciphertext.length < TAG_LENGTH) throw new Error("ciphertext is truncated");
  const tag = sealed.ciphertext.subarray(sealed.ciphertext.length - TAG_LENGTH);
  const ciphertext = sealed.ciphertext.subarray(0, sealed.ciphertext.length - TAG_LENGTH);
  const decipher = createDecipheriv("aes-256-gcm", key, sealed.nonce);
  decipher.setAAD(aad);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

export class EnvelopeCrypto {
  private readonly providers = new Map<string, KeyEncryptionProvider>();
  // Transaction executors are distinct Bun objects, so key material and single-flight unwraps
  // live at process/pool scope rather than disappearing with each transaction wrapper.
  private readonly cache = sharedKeyState.cache;
  private readonly inFlight = sharedKeyState.inFlight;
  private readonly generations = sharedKeyState.generations;
  private readonly retired = sharedKeyState.retired;
  private readonly transactionActiveKeys = new Map<string, StoredKey>();
  readonly mode: CryptoMode;
  private readonly cacheSize: number;
  private readonly cacheTTL: number;
  private readonly activeProvider: KeyEncryptionProvider | null;

  constructor(
    private readonly sql: SQL,
    options: {
      mode?: CryptoMode;
      activeProvider?: KeyEncryptionProvider | null;
      readableProviders?: KeyEncryptionProvider[];
      cacheSize?: number;
      cacheTTL?: number;
    } = {},
  ) {
    this.mode = options.mode ?? cryptoModeFromEnvironment();
    this.activeProvider = options.activeProvider === undefined
      ? providerFromEnvironment(this.mode)
      : options.activeProvider;
    for (const provider of options.readableProviders ?? registeredProviders.values()) {
      this.providers.set(provider.providerId, provider);
    }
    if (this.activeProvider) this.providers.set(this.activeProvider.providerId, this.activeProvider);
    if (this.mode !== "legacy" && !this.activeProvider) {
      throw new CryptoUnavailableError("envelope mode has no active key provider");
    }
    this.cacheSize = Math.max(1, options.cacheSize ?? boundedNumber(
      process.env.TOJ_DATA_KEY_CACHE_SIZE, DEFAULT_CACHE_SIZE, 1, 10_000,
    ));
    this.cacheTTL = Math.max(1, Math.min(MAX_CACHE_TTL_MS, options.cacheTTL ?? boundedNumber(
      process.env.TOJ_DATA_KEY_CACHE_TTL_MS, DEFAULT_CACHE_TTL_MS, 1, MAX_CACHE_TTL_MS,
    )));
  }

  private usesEnvelope(scope: KeyScope): boolean {
    if (this.mode === "envelope") return true;
    if (this.mode === "legacy") return false;
    if (scope.kind === "service") return true;
    const allowlist = new Set((process.env.TOJ_ENVELOPE_CANARY_ACCOUNTS ?? "")
      .split(",").map((value) => value.trim().toLowerCase()).filter(Boolean));
    if (allowlist.has(scope.accountId.toLowerCase())) return true;
    const percentage = boundedNumber(process.env.TOJ_ENVELOPE_CANARY_PERCENT, 0, 0, 100);
    if (percentage <= 0) return false;
    const bucket = createHash("sha256").update(`toj/envelope-canary|${scope.accountId}`).digest().readUInt32BE(0)
      / 0x1_0000_0000 * 100;
    return bucket < percentage;
  }

  private setCached(keyId: string, scope: KeyScope, plaintextKey: Buffer): void {
    if (this.retired.has(keyId)) throw new Error(`unknown key_id ${keyId}`);
    this.evictExpired();
    disposeCachedKey(keyId);
    while (this.cache.size >= this.cacheSize) {
      const oldest = [...this.cache.entries()].sort((left, right) =>
        left[1].lastUsedAt - right[1].lastUsedAt
      )[0];
      if (!oldest) break;
      disposeCachedKey(oldest[0], oldest[1]);
    }
    const now = Date.now();
    const cached: CachedKey = {
      key: Buffer.from(plaintextKey),
      scope,
      expiresAt: now + this.cacheTTL,
      lastUsedAt: now,
      expirationTimer: null,
    };
    cached.expirationTimer = setTimeout(() => disposeCachedKey(keyId, cached), this.cacheTTL);
    (cached.expirationTimer as unknown as { unref?: () => void }).unref?.();
    this.cache.set(keyId, cached);
  }

  private evictExpired(): void {
    const now = Date.now();
    for (const [keyId, cached] of this.cache) {
      if (cached.expiresAt > now) continue;
      disposeCachedKey(keyId, cached);
    }
  }

  private cachedCopy(keyId: string): Buffer | null {
    const cached = this.cachedEntry(keyId);
    return cached ? Buffer.from(cached.key) : null;
  }

  private cachedEntry(keyId: string): CachedKey | null {
    if (this.retired.has(keyId)) {
      disposeCachedKey(keyId);
      return null;
    }
    const cached = this.cache.get(keyId);
    if (!cached) return null;
    if (cached.expiresAt <= Date.now()) {
      disposeCachedKey(keyId, cached);
      return null;
    }
    cached.lastUsedAt = Date.now();
    return cached;
  }

  clearCache(): void {
    const keyIds = new Set([...this.cache.keys(), ...this.inFlight.keys()]);
    for (const keyId of keyIds) invalidateSharedKey(keyId);
  }

  async providerState(): Promise<"configured" | "development" | "disabled"> {
    if (!this.activeProvider) return "disabled";
    try {
      await this.activeProvider.healthCheck();
      return this.activeProvider.providerId === "local-development" ? "development" : "configured";
    } catch {
      return "disabled";
    }
  }

  private async storedKey(keyId: string, sql: SQL = this.sql): Promise<StoredKey> {
    const row = (await sql`
      SELECT id, account_id::text AS scope_name, 'account' AS scope_kind, version, state,
             provider_id, provider_key_reference, wrapped_key, revocation_started_at
      FROM account_data_keys WHERE id = ${keyId}
      UNION ALL
      SELECT id, service_name AS scope_name, 'service' AS scope_kind, version, state,
             provider_id, provider_key_reference, wrapped_key, revocation_started_at
      FROM service_data_keys WHERE id = ${keyId}`)[0];
    if (!row || row.state === "retired" || row.revocation_started_at) {
      invalidateSharedKey(keyId, row?.state === "retired");
      throw new Error(`unknown key_id ${keyId}`);
    }
    return {
      id: String(row.id),
      scope: row.scope_kind === "account"
        ? { kind: "account", accountId: String(row.scope_name) }
        : { kind: "service", serviceName: String(row.scope_name) },
      version: Number(row.version),
      state: row.state,
      providerId: row.provider_id,
      providerKeyReference: row.provider_key_reference,
      wrappedKey: Buffer.from(row.wrapped_key),
      revocationStartedAt: null,
    };
  }

  private async storedKeys(keyIds: string[]): Promise<Map<string, StoredKey>> {
    if (keyIds.length === 0) return new Map();
    const rows = await this.sql`
      SELECT id, account_id::text AS scope_name, 'account' AS scope_kind, version, state,
             provider_id, provider_key_reference, wrapped_key, revocation_started_at
      FROM account_data_keys WHERE id = ANY(${this.sql.array(keyIds, "uuid")}::uuid[])
      UNION ALL
      SELECT id, service_name AS scope_name, 'service' AS scope_kind, version, state,
             provider_id, provider_key_reference, wrapped_key, revocation_started_at
      FROM service_data_keys WHERE id = ANY(${this.sql.array(keyIds, "uuid")}::uuid[])`;
    const result = new Map<string, StoredKey>();
    for (const row of rows) {
      if (row.state === "retired" || row.revocation_started_at) {
        invalidateSharedKey(String(row.id), row.state === "retired");
        continue;
      }
      const stored: StoredKey = {
        id: String(row.id),
        scope: row.scope_kind === "account"
          ? { kind: "account", accountId: String(row.scope_name) }
          : { kind: "service", serviceName: String(row.scope_name) },
        version: Number(row.version),
        state: row.state,
        providerId: row.provider_id,
        providerKeyReference: row.provider_key_reference,
        wrappedKey: Buffer.from(row.wrapped_key),
        revocationStartedAt: null,
      };
      result.set(stored.id, stored);
    }
    for (const keyId of keyIds) {
      if (!result.has(keyId)) throw new Error(`unknown key_id ${keyId}`);
    }
    return result;
  }

  private async withScopeReadFence<T>(
    scope: KeyScope,
    operation: (sql: SQL) => Promise<T>,
  ): Promise<T> {
    const run = async (tx: SQL): Promise<T> => {
      await lockSharedMutationKeys(tx, [`envelope-key:${scopeLabel(scope)}`]);
      return await operation(tx);
    };
    const transactional = this.sql as SQL & {
      savepoint?: <U>(callback: (sql: SQL) => Promise<U>) => Promise<U>;
    };
    if (typeof transactional.savepoint === "function") {
      return await transactional.savepoint(run);
    }
    return await this.sql.begin(run);
  }

  private startUnwrap(stored: StoredKey): InFlightKey {
    const generation = this.generations.get(stored.id) ?? 0;
    const flight: InFlightKey = {
      promise: Promise.resolve(Buffer.alloc(0)),
      key: null,
      waiters: 0,
      settled: false,
      generation,
    };
    flight.promise = this.withScopeReadFence(stored.scope, async (tx) => {
      // Re-read under the shared fence. A stale row fetched before another process began the
      // durable revocation drain must never reach a provider or repopulate the plaintext cache.
      const current = await this.storedKey(stored.id, tx);
      if (scopeLabel(current.scope) !== scopeLabel(stored.scope)) {
        throw new Error(`ciphertext scope mismatch for key_id ${stored.id}`);
      }
      const provider = this.providers.get(current.providerId);
      if (!provider) throw new CryptoUnavailableError(`key provider unavailable: ${current.providerId}`);
      let key: Buffer | null = null;
      try {
        key = await provider.unwrap(current.scope, current.id, current);
      } catch (error) {
        throw cryptoUnavailable(error);
      }
      try {
        if (key.length !== DATA_KEY_BYTES) {
          throw new CryptoUnavailableError("provider returned invalid data key");
        }
        if (this.retired.has(stored.id)
          || (this.generations.get(stored.id) ?? 0) !== generation) {
          throw new Error(`unknown key_id ${stored.id}`);
        }
        this.setCached(stored.id, stored.scope, key);
        // `setCached` copied the key. This original is retained only as the single-flight
        // handoff so every already-joined caller can make its own eviction-safe copy.
        return key;
      } catch (error) {
        key.fill(0);
        throw error;
      }
    });
    this.inFlight.set(stored.id, flight);
    void flight.promise.then(
      (key) => {
        flight.key = key;
        flight.settled = true;
        this.releaseFlightIfIdle(stored.id, flight);
      },
      () => {
        flight.settled = true;
        this.releaseFlightIfIdle(stored.id, flight);
      },
    );
    return flight;
  }

  private releaseFlightIfIdle(keyId: string, flight: InFlightKey): void {
    if (!flight.settled || flight.waiters !== 0) return;
    flight.key?.fill(0);
    flight.key = null;
    if (this.inFlight.get(keyId) === flight) this.inFlight.delete(keyId);
  }

  private async copyFromFlight(keyId: string, flight: InFlightKey): Promise<Buffer> {
    flight.waiters += 1;
    try {
      const key = await flight.promise;
      if (this.retired.has(keyId)
        || (this.generations.get(keyId) ?? 0) !== flight.generation) {
        throw new Error(`unknown key_id ${keyId}`);
      }
      return Buffer.from(key);
    } finally {
      flight.waiters -= 1;
      this.releaseFlightIfIdle(keyId, flight);
    }
  }

  private async unwrapStoredUnderFence(
    stored: StoredKey,
    durableStateValidated = false,
  ): Promise<Buffer> {
    if (this.retired.has(stored.id)) throw new Error(`unknown key_id ${stored.id}`);
    // Never trust a pre-fence row or cache hit: revocation may have committed in another process
    // before this transaction acquired the fence. Active-key writers are the exception: their row
    // was already selected under this same exclusive fence and can be memoized for the transaction.
    const current = durableStateValidated ? stored : await this.storedKey(stored.id, this.sql);
    if (scopeLabel(current.scope) !== scopeLabel(stored.scope)) {
      throw new Error(`ciphertext scope mismatch for key_id ${stored.id}`);
    }
    const cached = this.cachedCopy(stored.id);
    if (cached) return cached;

    // A transaction holding the exclusive scope fence must not join the process-global flight:
    // that flight may itself be waiting for this transaction's shared counterpart. Unwrap on this
    // connection instead, then give the cache and caller independent buffers.
    const generation = this.generations.get(stored.id) ?? 0;
    const provider = this.providers.get(current.providerId);
    if (!provider) throw new CryptoUnavailableError(`key provider unavailable: ${current.providerId}`);
    let key: Buffer | null = null;
    try {
      try {
        key = await provider.unwrap(current.scope, current.id, current);
      } catch (error) {
        throw cryptoUnavailable(error);
      }
      if (key.length !== DATA_KEY_BYTES) {
        throw new CryptoUnavailableError("provider returned invalid data key");
      }
      if (this.retired.has(stored.id)
        || (this.generations.get(stored.id) ?? 0) !== generation) {
        throw new Error(`unknown key_id ${stored.id}`);
      }
      this.setCached(stored.id, current.scope, key);
      return key;
    } catch (error) {
      zeroize(key);
      throw error;
    }
  }

  private async unwrapStoredWithIndependentSharedFence(stored: StoredKey): Promise<Buffer> {
    const generation = this.generations.get(stored.id) ?? 0;
    return await this.withScopeReadFence(stored.scope, async (tx) => {
      const current = await this.storedKey(stored.id, tx);
      if (scopeLabel(current.scope) !== scopeLabel(stored.scope)) {
        throw new Error(`ciphertext scope mismatch for key_id ${stored.id}`);
      }
      const cached = this.cachedCopy(stored.id);
      if (cached) return cached;
      const provider = this.providers.get(current.providerId);
      if (!provider) {
        throw new CryptoUnavailableError(`key provider unavailable: ${current.providerId}`);
      }
      let key: Buffer | null = null;
      try {
        try {
          key = await provider.unwrap(current.scope, current.id, current);
        } catch (error) {
          throw cryptoUnavailable(error);
        }
        if (key.length !== DATA_KEY_BYTES) {
          throw new CryptoUnavailableError("provider returned invalid data key");
        }
        if (this.retired.has(stored.id)
          || (this.generations.get(stored.id) ?? 0) !== generation) {
          throw new Error(`unknown key_id ${stored.id}`);
        }
        this.setCached(stored.id, current.scope, key);
        return key;
      } catch (error) {
        zeroize(key);
        throw error;
      }
    });
  }

  private async unwrapStored(
    stored: StoredKey,
    scopeFenceHeld = false,
    durableStateValidated = false,
    avoidGlobalFlight = false,
  ): Promise<Buffer> {
    if (scopeFenceHeld) {
      return await this.unwrapStoredUnderFence(stored, durableStateValidated);
    }
    if (this.retired.has(stored.id)) throw new Error(`unknown key_id ${stored.id}`);
    const cached = this.cachedCopy(stored.id);
    if (cached) return cached;
    if (avoidGlobalFlight) {
      return await this.unwrapStoredWithIndependentSharedFence(stored);
    }
    const flight = this.inFlight.get(stored.id) ?? this.startUnwrap(stored);
    return await this.copyFromFlight(stored.id, flight);
  }

  private async activeKey(
    scope: KeyScope,
    memoizeForTransaction = false,
  ): Promise<{ stored: StoredKey; plaintextKey: Buffer }> {
    const label = scopeLabel(scope);
    const memoized = memoizeForTransaction ? this.transactionActiveKeys.get(label) : undefined;
    if (memoized) {
      const scopeFenceHeld = envelopeFenceHeld(this.sql, scope);
      if (!scopeFenceHeld) {
        throw new Error(`memoized envelope key has no transaction fence for ${label}`);
      }
      return {
        stored: memoized,
        plaintextKey: await this.unwrapStored(memoized, true, true),
      };
    }
    // Writers, rotation, migration, and retirement all use this scope fence. When this
    // instance is backed by an outer transaction the lock remains held through the row write.
    await lockMutationKeys(this.sql, [`envelope-key:${scopeLabel(scope)}`]);
    markEnvelopeFenceHeld(this.sql, scope);
    const scopeFenceHeld = envelopeFenceHeld(this.sql, scope);
    const lookup = async (sql: SQL): Promise<any | null> => scope.kind === "account"
      ? (await sql`
          SELECT id, account_id AS scope_name, 'account' AS scope_kind, version, state,
                 provider_id, provider_key_reference, wrapped_key
          FROM account_data_keys WHERE account_id = ${scope.accountId} AND state = 'active'
            AND revocation_started_at IS NULL`)[0] ?? null
      : (await sql`
          SELECT id, service_name AS scope_name, 'service' AS scope_kind, version, state,
                 provider_id, provider_key_reference, wrapped_key
          FROM service_data_keys WHERE service_name = ${scope.serviceName} AND state = 'active'
            AND revocation_started_at IS NULL`)[0] ?? null;
    let row = await lookup(this.sql);
    if (!row) {
      if (!this.activeProvider) throw new CryptoUnavailableError();
      const id = crypto.randomUUID();
      let generated: GeneratedDataKey;
      try {
        generated = await this.activeProvider.generateAndWrap(scope, id);
      } catch (error) {
        throw cryptoUnavailable(error);
      }
      validateGeneratedDataKey(generated, this.activeProvider.providerId);
      try {
        const inserted = scope.kind === "account"
          ? await this.sql`
              INSERT INTO account_data_keys (
                id, account_id, version, state, provider_id, provider_key_reference, wrapped_key
              )
              SELECT ${id}, ${scope.accountId}, COALESCE(max(version), 0) + 1, 'active',
                     ${generated.providerId}, ${generated.providerKeyReference}, ${generated.wrappedKey}
              FROM account_data_keys WHERE account_id = ${scope.accountId}
              ON CONFLICT DO NOTHING RETURNING id`
          : await this.sql`
              INSERT INTO service_data_keys (
                id, service_name, version, state, provider_id, provider_key_reference, wrapped_key
              )
              SELECT ${id}, ${scope.serviceName}, COALESCE(max(version), 0) + 1, 'active',
                     ${generated.providerId}, ${generated.providerKeyReference}, ${generated.wrappedKey}
              FROM service_data_keys WHERE service_name = ${scope.serviceName}
              ON CONFLICT DO NOTHING RETURNING id`;
        if (inserted.length) this.setCached(id, scope, generated.plaintextKey);
      } finally {
        zeroize(generated.plaintextKey);
      }
      row = await lookup(this.sql);
      if (!row) throw new CryptoUnavailableError("unable to establish an active data key");
    }
    const stored: StoredKey = {
      id: String(row.id),
      scope,
      version: Number(row.version),
      state: row.state,
      providerId: row.provider_id,
      providerKeyReference: row.provider_key_reference,
      wrappedKey: Buffer.from(row.wrapped_key),
      revocationStartedAt: null,
    };
    if (memoizeForTransaction && scopeFenceHeld) this.transactionActiveKeys.set(label, stored);
    return {
      stored,
      plaintextKey: await this.unwrapStored(stored, scopeFenceHeld, scopeFenceHeld),
    };
  }

  async seal(
    scope: KeyScope,
    plaintext: Buffer | string,
    aad: Buffer,
    forceEnvelope = false,
    memoizeForTransaction = false,
  ): Promise<Sealed> {
    if (!forceEnvelope && !this.usesEnvelope(scope)) return legacySeal(plaintext, aad);
    const { stored, plaintextKey } = await this.activeKey(scope, memoizeForTransaction);
    try {
      return { keyId: stored.id, ...encryptWithKey(
        plaintextKey, plaintext, payloadAAD(stored.scope, stored.id, aad),
      ) };
    } finally {
      plaintextKey.fill(0);
    }
  }

  async open(
    scope: KeyScope,
    sealed: Sealed,
    aad: Buffer,
    scopeFenceHeld = false,
  ): Promise<Buffer> {
    if (sealed.keyId === "dev-v1") return legacyOpen(sealed, aad);
    const effectiveScopeFenceHeld = scopeFenceHeld || envelopeFenceHeld(this.sql, scope);
    const avoidGlobalFlight = transactionHasEnvelopeFences(this.sql);
    // Under-fence callers must re-read durable revocation state even if this process has a cache
    // entry that predates the fence acquisition.
    const cached = effectiveScopeFenceHeld ? null : this.cachedEntry(sealed.keyId);
    let key: Buffer;
    if (cached) {
      if (scopeLabel(cached.scope) !== scopeLabel(scope)) {
        throw new Error(`ciphertext scope mismatch for key_id ${sealed.keyId}`);
      }
      key = Buffer.from(cached.key);
    } else {
      const stored = await this.storedKey(sealed.keyId);
      if (scopeLabel(stored.scope) !== scopeLabel(scope)) {
        throw new Error(`ciphertext scope mismatch for key_id ${sealed.keyId}`);
      }
      key = await this.unwrapStored(
        stored,
        effectiveScopeFenceHeld,
        effectiveScopeFenceHeld,
        avoidGlobalFlight,
      );
    }
    try {
      return decryptWithKey(key, sealed, payloadAAD(scope, sealed.keyId, aad));
    } catch {
      throw new Error(`ciphertext authentication failed for key_id ${sealed.keyId}`);
    } finally {
      key.fill(0);
    }
  }

  async preload(keyIds: string[]): Promise<void> {
    const unique = [...new Set(keyIds.filter((keyId) => keyId && keyId !== "dev-v1"))];
    const avoidGlobalFlight = transactionHasEnvelopeFences(this.sql);
    const candidates = avoidGlobalFlight ? unique : unique.filter((keyId) => !this.cachedEntry(keyId));
    const stored = await this.storedKeys(candidates);
    const missing = candidates.filter((keyId) => {
      const entry = stored.get(keyId)!;
      return envelopeFenceHeld(this.sql, entry.scope) || !this.cachedEntry(keyId);
    });
    let cursor = 0;
    const workers = Array.from({ length: Math.min(16, missing.length) }, async () => {
      while (cursor < missing.length) {
        const keyId = missing[cursor++];
        const entry = stored.get(keyId)!;
        const held = envelopeFenceHeld(this.sql, entry.scope);
        const key = await this.unwrapStored(entry, held, held, avoidGlobalFlight);
        key.fill(0);
      }
    });
    await Promise.all(workers);
  }

  async rotate(scope: KeyScope): Promise<{ previousKeyId: string | null; activeKeyId: string }> {
    if (!this.activeProvider) throw new CryptoUnavailableError();
    this.transactionActiveKeys.delete(scopeLabel(scope));
    return await this.sql.begin(async (tx) => {
      await lockMutationKeys(tx, [`envelope-key:${scopeLabel(scope)}`]);
      const current = scope.kind === "account"
        ? (await tx`SELECT id, version FROM account_data_keys
            WHERE account_id = ${scope.accountId} AND state = 'active' FOR UPDATE`)[0]
        : (await tx`SELECT id, version FROM service_data_keys
            WHERE service_name = ${scope.serviceName} AND state = 'active' FOR UPDATE`)[0];
      const version = Number(current?.version ?? 0) + 1;
      const id = crypto.randomUUID();
      let generated: GeneratedDataKey;
      try {
        generated = await this.activeProvider!.generateAndWrap(scope, id);
      } catch (error) {
        throw cryptoUnavailable(error);
      }
      try {
        validateGeneratedDataKey(generated, this.activeProvider!.providerId);
        if (scope.kind === "account") {
          await tx`UPDATE account_data_keys SET state = 'retiring', retiring_at = now()
            WHERE account_id = ${scope.accountId} AND state = 'active'`;
          await tx`INSERT INTO account_data_keys (
            id, account_id, version, state, provider_id, provider_key_reference, wrapped_key
          ) VALUES (${id}, ${scope.accountId}, ${version}, 'active', ${generated.providerId},
            ${generated.providerKeyReference}, ${generated.wrappedKey})`;
        } else {
          await tx`UPDATE service_data_keys SET state = 'retiring', retiring_at = now()
            WHERE service_name = ${scope.serviceName} AND state = 'active'`;
          await tx`INSERT INTO service_data_keys (
            id, service_name, version, state, provider_id, provider_key_reference, wrapped_key
          ) VALUES (${id}, ${scope.serviceName}, ${version}, 'active', ${generated.providerId},
            ${generated.providerKeyReference}, ${generated.wrappedKey})`;
        }
        this.setCached(id, scope, generated.plaintextKey);
      } finally {
        zeroize(generated.plaintextKey);
      }
      return { previousKeyId: current ? String(current.id) : null, activeKeyId: id };
    });
  }

  async rewrap(keyId: string): Promise<void> {
    if (!this.activeProvider) throw new CryptoUnavailableError();
    const initial = await this.storedKey(keyId);
    await this.sql.begin(async (tx) => {
      await lockMutationKeys(tx, [`envelope-key:${scopeLabel(initial.scope)}`]);
      const stored = await new EnvelopeCrypto(tx, {
        mode: this.mode,
        activeProvider: this.activeProvider,
        readableProviders: [...this.providers.values()],
        cacheSize: this.cacheSize,
        cacheTTL: this.cacheTTL,
      }).storedKey(keyId);
      if (scopeLabel(stored.scope) !== scopeLabel(initial.scope)) {
        throw new Error(`key scope changed for ${keyId}`);
      }
      const provider = this.providers.get(stored.providerId);
      if (!provider) {
        throw new CryptoUnavailableError(`key provider unavailable: ${stored.providerId}`);
      }
      let currentPlaintext: Buffer | null = null;
      let replacement: GeneratedDataKey | null = null;
      let verifiedReplacement: Buffer | null = null;
      try {
        try {
          currentPlaintext = await provider.unwrap(stored.scope, stored.id, stored);
        } catch (error) {
          throw cryptoUnavailable(error);
        }
        if (currentPlaintext.length !== DATA_KEY_BYTES) {
          throw new CryptoUnavailableError("provider returned invalid current data key");
        }
        try {
          replacement = await provider.rewrap(stored.scope, stored.id, stored);
        } catch (error) {
          throw cryptoUnavailable(error);
        }
        validateGeneratedDataKey(replacement, provider.providerId);
        try {
          verifiedReplacement = await provider.unwrap(stored.scope, stored.id, replacement);
        } catch (error) {
          throw cryptoUnavailable(error);
        }
        if (verifiedReplacement.length !== DATA_KEY_BYTES
          || !timingSafeEqual(currentPlaintext, replacement.plaintextKey)
          || !timingSafeEqual(currentPlaintext, verifiedReplacement)) {
          throw new CryptoUnavailableError("rewrapped material does not preserve the data key");
        }
        const updated = stored.scope.kind === "account"
          ? await tx`UPDATE account_data_keys SET provider_id = ${replacement.providerId},
              provider_key_reference = ${replacement.providerKeyReference},
              wrapped_key = ${replacement.wrappedKey}
              WHERE id = ${keyId} AND state <> 'retired' RETURNING id`
          : await tx`UPDATE service_data_keys SET provider_id = ${replacement.providerId},
              provider_key_reference = ${replacement.providerKeyReference},
              wrapped_key = ${replacement.wrappedKey}
              WHERE id = ${keyId} AND state <> 'retired' RETURNING id`;
        if (updated.length !== 1) throw new Error(`data key ${keyId} is no longer rewrappable`);
        this.setCached(keyId, stored.scope, replacement.plaintextKey);
      } finally {
        zeroize(currentPlaintext);
        zeroize(replacement?.plaintextKey);
        zeroize(verifiedReplacement);
      }
    });
  }
}

let instances = new WeakMap<object, EnvelopeCrypto>();

export function envelopeCrypto(sql: SQL): EnvelopeCrypto {
  const key = sql as unknown as object;
  let instance = instances.get(key);
  if (!instance) {
    instance = new EnvelopeCrypto(sql);
    instances.set(key, instance);
  }
  return instance;
}

export function resetEnvelopeCryptoInstancesForTests(): void {
  for (const [keyId, cached] of sharedKeyState.cache) disposeCachedKey(keyId, cached);
  sharedKeyState = {
    cache: new Map(), inFlight: new Map(), generations: new Map(), retired: new Set(),
  };
  transactionEnvelopeFences = new WeakMap<object, Set<string>>();
  instances = new WeakMap<object, EnvelopeCrypto>();
  registeredProviders.clear();
}

export function clearEnvelopeKeyCache(): void {
  const keyIds = new Set([
    ...sharedKeyState.cache.keys(),
    ...sharedKeyState.inFlight.keys(),
  ]);
  for (const keyId of keyIds) invalidateSharedKey(keyId);
}

export async function sealForScope(
  sql: SQL,
  scope: KeyScope,
  plaintext: Buffer | string,
  aad: Buffer,
  forceEnvelope = false,
  memoizeForTransaction = false,
): Promise<Sealed> {
  return await envelopeCrypto(sql).seal(
    scope, plaintext, aad, forceEnvelope, memoizeForTransaction,
  );
}

export async function openForScope(
  sql: SQL,
  scope: KeyScope,
  sealed: Sealed,
  aad: Buffer,
  scopeFenceHeld = false,
): Promise<Buffer> {
  return await envelopeCrypto(sql).open(scope, sealed, aad, scopeFenceHeld);
}

export async function preloadEnvelopeKeys(sql: SQL, keyIds: string[]): Promise<void> {
  await envelopeCrypto(sql).preload(keyIds);
}

export async function envelopeSchemaReadiness(sql: SQL): Promise<{ ready: boolean; missing: string[] }> {
  const required: Record<string, string[]> = {
    schema_migrations: ["name"],
    account_data_keys: [
      "id", "account_id", "version", "state", "provider_id", "provider_key_reference",
      "wrapped_key", "created_at", "activated_at", "retiring_at", "revocation_started_at",
      "retired_at",
    ],
    service_data_keys: [
      "id", "service_name", "version", "state", "provider_id", "provider_key_reference",
      "wrapped_key", "created_at", "activated_at", "retiring_at", "revocation_started_at",
      "retired_at",
    ],
    crypto_migration_cursors: ["domain", "cursor", "state", "rows_migrated", "updated_at"],
    crypto_write_state: ["singleton", "write_mode", "epoch", "updated_at"],
    accounts: ["phone_key_id", "phone_nonce", "phone_e164_ciphertext"],
    messages: ["body_key_id", "body_nonce", "body_ciphertext"],
    account_dialog_drafts: ["body_key_id", "body_nonce", "body_ciphertext"],
    draft_mutation_requests: ["response_key_id", "response_nonce", "response_ciphertext"],
    devices: [
      "push_token_key_id", "push_token_nonce", "push_token_ciphertext",
      "voip_push_token_key_id", "voip_push_token_nonce", "voip_push_token_ciphertext",
    ],
    media_objects: [
      "file_name_key_id", "file_name_nonce", "file_name_ciphertext",
      "thumbnail_key_id", "thumbnail_nonce", "thumbnail_ciphertext",
    ],
    media_chunks: ["key_id", "nonce", "ciphertext"],
    abuse_reports: ["evidence_key_id", "evidence_nonce", "evidence_ciphertext"],
    abuse_report_actions: ["note_key_id", "note_nonce", "note_ciphertext"],
    user_reports: [
      "message_snapshot_key_id", "message_snapshot_nonce", "message_snapshot_ciphertext",
    ],
    chat_folders: ["title_key_id", "title_nonce", "title_ciphertext"],
    scheduled_delivery_items: ["payload_key_id", "payload_nonce", "payload_ciphertext"],
    link_preview_cache_entries: ["url_key_id", "url_nonce", "url_ciphertext"],
    message_link_previews: [
      "original_url_key_id", "original_url_nonce", "original_url_ciphertext",
    ],
    link_preview_snapshots: [
      "url_key_id", "url_nonce", "url_ciphertext",
      "metadata_key_id", "metadata_nonce", "metadata_ciphertext",
    ],
    link_preview_assets: ["key_id", "nonce", "ciphertext"],
    message_polls: ["payload_key_id", "payload_nonce", "payload_ciphertext"],
    push_installations: [
      "normal_token_key_id", "normal_token_nonce", "normal_token_ciphertext",
      "voip_token_key_id", "voip_token_nonce", "voip_token_ciphertext",
    ],
    session_rotation_receipts: [
      "response_key_id", "response_nonce", "response_ciphertext",
    ],
  };
  const rows = await sql`
    SELECT table_name, column_name, is_nullable FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = ANY(${sql.array(Object.keys(required), "text")}::text[])`;
  const present = new Set(rows.map((row: any) => `${row.table_name}.${row.column_name}`));
  const missing = Object.entries(required).flatMap(([table, columns]) =>
    columns.filter((column) => !present.has(`${table}.${column}`)).map((column) => `${table}.${column}`)
  );
  const requiredNotNull: Record<string, string[]> = {
    account_data_keys: [
      "id", "account_id", "version", "state", "provider_id", "provider_key_reference",
      "wrapped_key", "created_at", "activated_at",
    ],
    service_data_keys: [
      "id", "service_name", "version", "state", "provider_id", "provider_key_reference",
      "wrapped_key", "created_at", "activated_at",
    ],
    crypto_migration_cursors: ["domain", "cursor", "state", "rows_migrated", "updated_at"],
    crypto_write_state: ["singleton", "write_mode", "epoch", "updated_at"],
  };
  const nullability = new Map(rows.map((row: any) => [
    `${row.table_name}.${row.column_name}`, String(row.is_nullable),
  ]));
  for (const [table, columns] of Object.entries(requiredNotNull)) {
    for (const column of columns) {
      if (nullability.get(`${table}.${column}`) === "YES") missing.push(`${table}.${column}.not_null`);
    }
  }
  const requiredIndexes = [
    "account_data_keys_one_active_idx", "account_data_keys_retirement_idx",
    "service_data_keys_one_active_idx", "service_data_keys_retirement_idx",
    "accounts_phone_key_migration_idx", "messages_body_key_migration_idx",
    "drafts_body_key_migration_idx", "draft_responses_key_migration_idx",
    "devices_push_key_migration_idx", "devices_voip_key_migration_idx",
    "media_file_name_key_migration_idx", "media_thumbnail_key_migration_idx",
    "media_chunks_key_migration_idx", "abuse_reports_evidence_key_migration_idx",
    "abuse_report_notes_key_migration_idx", "chat_folders_title_key_migration_idx",
    "scheduled_items_payload_key_migration_idx", "link_preview_cache_key_migration_idx",
    "message_link_preview_key_migration_idx", "link_preview_snapshot_url_key_migration_idx",
    "link_preview_snapshot_metadata_key_migration_idx", "link_preview_assets_key_migration_idx",
    "message_polls_payload_key_migration_idx", "push_installations_normal_key_migration_idx",
    "push_installations_voip_key_migration_idx", "session_rotation_receipts_key_migration_idx",
  ];
  const indexes = await sql`
    SELECT class.relname AS name, index.indisvalid, index.indisready, index.indislive
    FROM pg_index index
    JOIN pg_class class ON class.oid = index.indexrelid
    JOIN pg_namespace namespace ON namespace.oid = class.relnamespace
    WHERE namespace.nspname = current_schema()
      AND class.relname = ANY(${sql.array(requiredIndexes, "text")}::text[])`;
  const readyIndexes = new Set(indexes.filter((row: any) =>
    row.indisvalid && row.indisready && row.indislive
  ).map((row: any) => String(row.name)));
  for (const index of requiredIndexes) {
    if (!readyIndexes.has(index)) missing.push(index);
  }
  const requiredConstraints = [
    "account_data_keys_pkey", "account_data_keys_account_id_version_key",
    "account_data_keys_version_check", "account_data_keys_state_check",
    "service_data_keys_pkey", "service_data_keys_service_name_version_key",
    "service_data_keys_version_check", "service_data_keys_state_check",
    "crypto_migration_cursors_pkey", "crypto_migration_cursors_state_check",
    "crypto_migration_cursors_rows_migrated_check",
    "crypto_write_state_pkey", "crypto_write_state_singleton_check",
    "crypto_write_state_write_mode_check", "crypto_write_state_epoch_check",
  ];
  const constraints = await sql`
    SELECT constraint_row.conname AS name
    FROM pg_constraint constraint_row
    JOIN pg_namespace namespace ON namespace.oid = constraint_row.connamespace
    WHERE namespace.nspname = current_schema()
      AND constraint_row.conname = ANY(${sql.array(requiredConstraints, "text")}::text[])
      AND constraint_row.convalidated`;
  const presentConstraints = new Set(constraints.map((row: any) => String(row.name)));
  for (const constraint of requiredConstraints) {
    if (!presentConstraints.has(constraint)) missing.push(constraint);
  }
  const requiredTriggers: Record<string, { table: string; functionName: string; args: string }> = {
    crypto_write_state_guard: {
      table: "crypto_write_state", functionName: "toj_guard_crypto_write_state_v1", args: "",
    },
    crypto_write_fence_accounts_phone_key_id: {
      table: "accounts", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "phone_key_id\\000phone_nonce\\000phone_e164_ciphertext\\000",
    },
    crypto_write_fence_devices_push_token_key_id: {
      table: "devices", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "push_token_key_id\\000push_token_nonce\\000push_token_ciphertext\\000",
    },
    crypto_write_fence_devices_voip_push_token_key_id: {
      table: "devices", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "voip_push_token_key_id\\000voip_push_token_nonce\\000voip_push_token_ciphertext\\000",
    },
    crypto_write_fence_messages_body_key_id: {
      table: "messages", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "body_key_id\\000body_nonce\\000body_ciphertext\\000",
    },
    crypto_write_fence_account_dialog_drafts_body_key_id: {
      table: "account_dialog_drafts", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "body_key_id\\000body_nonce\\000body_ciphertext\\000",
    },
    crypto_write_fence_draft_mutation_requests_response_key_id: {
      table: "draft_mutation_requests", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "response_key_id\\000response_nonce\\000response_ciphertext\\000",
    },
    crypto_write_fence_media_objects_file_name_key_id: {
      table: "media_objects", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "file_name_key_id\\000file_name_nonce\\000file_name_ciphertext\\000",
    },
    crypto_write_fence_media_objects_thumbnail_key_id: {
      table: "media_objects", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "thumbnail_key_id\\000thumbnail_nonce\\000thumbnail_ciphertext\\000",
    },
    crypto_write_fence_media_chunks_key_id: {
      table: "media_chunks", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "key_id\\000nonce\\000ciphertext\\000",
    },
    crypto_write_fence_abuse_reports_evidence_key_id: {
      table: "abuse_reports", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "evidence_key_id\\000evidence_nonce\\000evidence_ciphertext\\000",
    },
    crypto_write_fence_abuse_report_actions_note_key_id: {
      table: "abuse_report_actions", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "note_key_id\\000note_nonce\\000note_ciphertext\\000",
    },
    crypto_write_fence_user_reports_message_snapshot_key_id: {
      table: "user_reports", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "message_snapshot_key_id\\000message_snapshot_nonce\\000message_snapshot_ciphertext\\000",
    },
    crypto_write_fence_chat_folders_title_key_id: {
      table: "chat_folders", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "title_key_id\\000title_nonce\\000title_ciphertext\\000",
    },
    crypto_write_fence_scheduled_delivery_items_payload_key_id: {
      table: "scheduled_delivery_items", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "payload_key_id\\000payload_nonce\\000payload_ciphertext\\000",
    },
    crypto_write_fence_link_preview_cache_entries_url_key_id: {
      table: "link_preview_cache_entries", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "url_key_id\\000url_nonce\\000url_ciphertext\\000",
    },
    crypto_write_fence_message_link_previews_original_url_key_id: {
      table: "message_link_previews", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "original_url_key_id\\000original_url_nonce\\000original_url_ciphertext\\000",
    },
    crypto_write_fence_link_preview_snapshots_url_key_id: {
      table: "link_preview_snapshots", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "url_key_id\\000url_nonce\\000url_ciphertext\\000",
    },
    crypto_write_fence_link_preview_snapshots_metadata_key_id: {
      table: "link_preview_snapshots", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "metadata_key_id\\000metadata_nonce\\000metadata_ciphertext\\000",
    },
    crypto_write_fence_link_preview_assets_key_id: {
      table: "link_preview_assets", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "key_id\\000nonce\\000ciphertext\\000",
    },
    crypto_write_fence_message_polls_payload_key_id: {
      table: "message_polls", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "payload_key_id\\000payload_nonce\\000payload_ciphertext\\000",
    },
    crypto_write_fence_push_installations_normal_token_key_id: {
      table: "push_installations", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "normal_token_key_id\\000normal_token_nonce\\000normal_token_ciphertext\\000",
    },
    crypto_write_fence_push_installations_voip_token_key_id: {
      table: "push_installations", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "voip_token_key_id\\000voip_token_nonce\\000voip_token_ciphertext\\000",
    },
    crypto_write_fence_session_rotation_receipts_response_key_id: {
      table: "session_rotation_receipts", functionName: "toj_reject_legacy_ciphertext_v1",
      args: "response_key_id\\000response_nonce\\000response_ciphertext\\000",
    },
  };
  const triggers = await sql`
    SELECT trigger.tgname, relation.relname, function.proname,
           encode(trigger.tgargs, 'escape') AS args, trigger.tgenabled
    FROM pg_trigger trigger
    JOIN pg_class relation ON relation.oid = trigger.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    JOIN pg_proc function ON function.oid = trigger.tgfoid
    WHERE namespace.nspname = current_schema() AND NOT trigger.tgisinternal
      AND trigger.tgname = ANY(${sql.array(Object.keys(requiredTriggers), "text")}::text[])`;
  const triggerTopology = new Map(triggers.map((row: any) => [String(row.tgname), row]));
  for (const [trigger, expected] of Object.entries(requiredTriggers)) {
    const actual = triggerTopology.get(trigger) as any;
    if (!actual || actual.tgenabled !== "O" || actual.relname !== expected.table
      || actual.proname !== expected.functionName || actual.args !== expected.args) {
      missing.push(trigger);
    }
  }
  if (present.has("schema_migrations.name")) {
    const marker = await sql`
      SELECT 1 FROM public.schema_migrations WHERE name = 'crypto-write-fence-v1'`;
    if (!marker.length) missing.push("schema_migrations.crypto-write-fence-v1");
  } else {
    missing.push("schema_migrations.crypto-write-fence-v1");
  }
  return { ready: missing.length === 0, missing };
}

export async function databaseCryptoWriteMode(sql: SQL): Promise<{
  mode: CryptoMode; epoch: number;
}> {
  const row = (await sql`
    SELECT write_mode, epoch FROM crypto_write_state WHERE singleton`)[0];
  if (!row || !["legacy", "envelope-canary", "envelope"].includes(row.write_mode)) {
    throw new CryptoUnavailableError("database crypto write state is unavailable");
  }
  const epoch = Number(row.epoch);
  if (!Number.isSafeInteger(epoch) || epoch <= 0) {
    throw new CryptoUnavailableError("database crypto write epoch is invalid");
  }
  return { mode: row.write_mode as CryptoMode, epoch };
}

export type EnvelopeReadinessState = {
  mode: CryptoMode;
  databaseMode: CryptoMode | "unavailable";
  databaseEpoch: number | null;
  legacyReferences: number | null;
  schema: { ready: boolean; missing: string[] };
  provider: "configured" | "development" | "disabled";
  ready: boolean;
  launchBlocking: boolean;
};

export async function envelopeReadiness(sql: SQL): Promise<EnvelopeReadinessState> {
  const mode = cryptoModeFromEnvironment();
  const schema = await envelopeSchemaReadiness(sql);
  let databaseMode: CryptoMode | "unavailable" = "unavailable";
  let databaseEpoch: number | null = null;
  let legacyReferences: number | null = null;
  if (schema.ready) {
    try {
      const database = await databaseCryptoWriteMode(sql);
      databaseMode = database.mode;
      databaseEpoch = database.epoch;
      legacyReferences = await keyReferenceCount(sql, "dev-v1");
    } catch { /* unavailable is explicit in the returned readiness state */ }
  }
  let provider: "configured" | "development" | "disabled" = "disabled";
  if (mode !== "legacy") {
    try {
      provider = await envelopeCrypto(sql).providerState();
    } catch {
      provider = "disabled";
    }
  }
  return {
    mode,
    databaseMode,
    databaseEpoch,
    legacyReferences,
    schema,
    provider,
    // Process mode deliberately leads the database fence during canary and final-writer rollout.
    // Production launch readiness below still requires the final fence to match exactly.
    ready: schema.ready && databaseMode !== "unavailable"
      && (mode === "legacy" || provider !== "disabled"),
    launchBlocking: process.env.NODE_ENV === "production"
      && (mode !== "envelope" || databaseMode !== "envelope"
        || !schema.ready || provider !== "configured" || legacyReferences !== 0),
  };
}

export async function envelopeMetrics(
  sql: SQL,
  snapshot?: EnvelopeReadinessState,
): Promise<string> {
  const state = snapshot ?? await envelopeReadiness(sql);
  return [
    "# HELP toj_envelope_crypto_schema_available Whether envelope-key schema is complete.",
    "# TYPE toj_envelope_crypto_schema_available gauge",
    `toj_envelope_crypto_schema_available ${state.schema.ready ? 1 : 0}`,
    "# HELP toj_envelope_crypto_mode_info Active server-side encryption write mode.",
    "# TYPE toj_envelope_crypto_mode_info gauge",
    `toj_envelope_crypto_mode_info{mode=\"${state.mode}\",database_mode=\"${state.databaseMode}\",provider=\"${state.provider}\"} 1`,
    "# TYPE toj_envelope_crypto_write_epoch gauge",
    `toj_envelope_crypto_write_epoch ${state.databaseEpoch ?? 0}`,
    "# HELP toj_envelope_crypto_legacy_references Ciphertext tuples that still require the legacy dev-v1 key.",
    "# TYPE toj_envelope_crypto_legacy_references gauge",
    `toj_envelope_crypto_legacy_references ${state.legacyReferences ?? -1}`,
    "# HELP toj_envelope_crypto_launch_blocking Whether production key management blocks launch.",
    "# TYPE toj_envelope_crypto_launch_blocking gauge",
    `toj_envelope_crypto_launch_blocking ${state.launchBlocking ? 1 : 0}`,
    "",
  ].join("\n");
}

export function assertCryptoConfiguration(): void {
  const mode = cryptoModeFromEnvironment();
  assertProtocolIdentifierConfiguration();
  if (mode !== "envelope") assertLegacyMessageKeyConfigured();
  if (mode === "legacy") return;
  void providerFromEnvironment(mode);
}

export async function keyReferenceCount(sql: SQL, keyId: string): Promise<number> {
  const row = (await sql`
    SELECT
      (SELECT count(*) FROM accounts WHERE phone_key_id = ${keyId})
      + (SELECT count(*) FROM devices WHERE push_token_key_id = ${keyId} OR voip_push_token_key_id = ${keyId})
      + (SELECT count(*) FROM messages WHERE body_key_id = ${keyId})
      + (SELECT count(*) FROM account_dialog_drafts WHERE body_key_id = ${keyId})
      + (SELECT count(*) FROM draft_mutation_requests WHERE response_key_id = ${keyId})
      + (SELECT count(*) FROM media_objects WHERE file_name_key_id = ${keyId} OR thumbnail_key_id = ${keyId})
      + (SELECT count(*) FROM media_chunks WHERE key_id = ${keyId})
      + (SELECT count(*) FROM abuse_reports WHERE evidence_key_id = ${keyId})
      + (SELECT count(*) FROM abuse_report_actions WHERE note_key_id = ${keyId})
      + (SELECT count(*) FROM user_reports WHERE message_snapshot_key_id = ${keyId})
      + (SELECT count(*) FROM chat_folders WHERE title_key_id = ${keyId})
      + (SELECT count(*) FROM scheduled_delivery_items WHERE payload_key_id = ${keyId})
      + (SELECT count(*) FROM link_preview_cache_entries WHERE url_key_id = ${keyId})
      + (SELECT count(*) FROM message_link_previews WHERE original_url_key_id = ${keyId})
      + (SELECT count(*) FROM link_preview_snapshots
          WHERE url_key_id = ${keyId} OR metadata_key_id = ${keyId})
      + (SELECT count(*) FROM link_preview_assets WHERE key_id = ${keyId})
      + (SELECT count(*) FROM message_polls WHERE payload_key_id = ${keyId})
      + (SELECT count(*) FROM push_installations
          WHERE normal_token_key_id = ${keyId} OR voip_token_key_id = ${keyId})
      + (SELECT count(*) FROM session_rotation_receipts WHERE response_key_id = ${keyId}) AS count`)[0];
  return Number(row.count);
}

export async function activateCryptoWriteMode(
  sql: SQL,
  target: CryptoMode,
): Promise<{ previousMode: CryptoMode; mode: CryptoMode; epoch: number; duplicate: boolean }> {
  if (!["legacy", "envelope-canary", "envelope"].includes(target)) {
    throw new Error("invalid crypto write mode");
  }
  const processMode = cryptoModeFromEnvironment();
  if (target !== "legacy" && processMode !== target) {
    throw new Error(`TOJ_CRYPTO_MODE must be ${target} before activating that database mode`);
  }
  const schema = await envelopeSchemaReadiness(sql);
  if (!schema.ready) throw new Error(`envelope schema is incomplete: ${schema.missing.join(", ")}`);
  if (target !== "legacy") {
    const provider = await envelopeCrypto(sql).providerState();
    if (provider === "disabled"
      || (process.env.NODE_ENV === "production" && provider !== "configured")) {
      throw new CryptoUnavailableError("a healthy production key provider is required");
    }
  }
  return await sql.begin(async (tx) => {
    await lockMutationKeys(tx, ["crypto-write-mode"]);
    const current = (await tx`
      SELECT write_mode, epoch FROM crypto_write_state WHERE singleton FOR UPDATE`)[0];
    if (!current) throw new Error("database crypto write state is unavailable");
    const previousMode = current.write_mode as CryptoMode;
    const previousEpoch = Number(current.epoch);
    if (previousMode === target) {
      return { previousMode, mode: target, epoch: previousEpoch, duplicate: true };
    }
    if (previousMode === "envelope") throw new Error("final envelope mode cannot be downgraded");
    if (target === "envelope" && previousMode !== "envelope-canary") {
      throw new Error("activate envelope-canary before final envelope mode");
    }
    if (target === "envelope") {
      await tx`SET LOCAL lock_timeout = '5s'`;
      // This is the bounded final writer cutover. Blocking writers while the mode flip commits
      // prevents a canary/legacy transaction from slipping in behind the database trigger fence.
      // Existing dev-v1 rows remain readable and migrate in bounded batches; readiness stays
      // launch-blocking until their reference count reaches zero.
      await tx.unsafe(`LOCK TABLE
        abuse_report_actions, abuse_reports, account_dialog_drafts, accounts, chat_folders,
        devices, draft_mutation_requests, link_preview_assets, link_preview_cache_entries,
        link_preview_snapshots, media_chunks, media_objects, message_link_previews, message_polls,
        messages, push_installations, scheduled_delivery_items, session_rotation_receipts,
        user_reports
        IN SHARE ROW EXCLUSIVE MODE`);
      const unsupportedLegacyReports = await tx`
        SELECT 1 FROM user_reports WHERE message_snapshot_key_id IS NOT NULL LIMIT 1`;
      if (unsupportedLegacyReports.length) {
        throw new Error(
          "legacy user_reports snapshots must be resolved before final envelope activation",
        );
      }
    }
    const updated = (await tx`
      UPDATE crypto_write_state
      SET write_mode = ${target}, epoch = epoch + 1, updated_at = now()
      WHERE singleton RETURNING epoch`)[0];
    return {
      previousMode,
      mode: target,
      epoch: Number(updated.epoch),
      duplicate: false,
    };
  });
}

export type DataKeyRetirementResult = {
  keyId: string;
  state: "draining" | "retired";
  finalizeAfter: string | null;
};

export async function retireDataKey(sql: SQL, keyId: string): Promise<DataKeyRetirementResult> {
  const result = await sql.begin(async (tx): Promise<DataKeyRetirementResult> => {
    let row = (await tx`
      SELECT id, account_id::text AS scope_name, 'account' AS scope_kind, state, retiring_at,
             revocation_started_at
      FROM account_data_keys WHERE id = ${keyId}
      UNION ALL
      SELECT id, service_name AS scope_name, 'service' AS scope_kind, state, retiring_at,
             revocation_started_at
      FROM service_data_keys WHERE id = ${keyId}`)[0];
    if (!row) throw new Error("data key not found");
    const scope: KeyScope = row.scope_kind === "account"
      ? { kind: "account", accountId: String(row.scope_name) }
      : { kind: "service", serviceName: String(row.scope_name) };
    await lockMutationKeys(tx, [`envelope-key:${scopeLabel(scope)}`]);
    row = scope.kind === "account"
      ? (await tx`SELECT id, state, retiring_at, revocation_started_at FROM account_data_keys
          WHERE id = ${keyId} FOR UPDATE`)[0]
      : (await tx`SELECT id, state, retiring_at, revocation_started_at FROM service_data_keys
          WHERE id = ${keyId} FOR UPDATE`)[0];
    if (!row) throw new Error("data key not found");
    if (row.state === "retired") {
      return { keyId, state: "retired", finalizeAfter: null };
    }
    if (row.state !== "retiring") throw new Error("only a retiring key can be retired");
    const graceDays = boundedNumber(process.env.TOJ_CRYPTO_RETIREMENT_GRACE_DAYS, 30, 1, 3650);
    if (!row.retiring_at || Date.now() - new Date(row.retiring_at).getTime() < graceDays * 86_400_000) {
      throw new Error(`data key has not completed the ${graceDays}-day rollback and backup window`);
    }
    const references = await keyReferenceCount(tx, keyId);
    if (references !== 0) throw new Error(`data key still has ${references} ciphertext references`);

    if (!row.revocation_started_at) {
      const started = scope.kind === "account"
        ? (await tx`UPDATE account_data_keys SET revocation_started_at = clock_timestamp()
            WHERE id = ${keyId} AND state = 'retiring'
            RETURNING revocation_started_at`)[0]
        : (await tx`UPDATE service_data_keys SET revocation_started_at = clock_timestamp()
            WHERE id = ${keyId} AND state = 'retiring'
            RETURNING revocation_started_at`)[0];
      if (!started) throw new Error(`data key ${keyId} could not begin cache revocation`);
      const finalizeAfter = new Date(
        new Date(started.revocation_started_at).getTime() + RETIREMENT_CACHE_DRAIN_MS,
      ).toISOString();
      return { keyId, state: "draining", finalizeAfter };
    }

    const drain = (await tx`
      SELECT clock_timestamp() >= ${row.revocation_started_at}::timestamptz
        + (${RETIREMENT_CACHE_DRAIN_MS}::bigint * interval '1 millisecond') AS complete,
        (${row.revocation_started_at}::timestamptz
          + (${RETIREMENT_CACHE_DRAIN_MS}::bigint * interval '1 millisecond')) AS finalize_after`)[0];
    if (drain?.complete !== true) {
      return {
        keyId,
        state: "draining",
        finalizeAfter: new Date(drain.finalize_after).toISOString(),
      };
    }
    await tx`UPDATE account_data_keys SET state = 'retired', retired_at = now(), wrapped_key = '\\x'::bytea
      WHERE id = ${keyId}`;
    await tx`UPDATE service_data_keys SET state = 'retired', retired_at = now(), wrapped_key = '\\x'::bytea
      WHERE id = ${keyId}`;
    return { keyId, state: "retired", finalizeAfter: null };
  });
  invalidateSharedKey(keyId, result.state === "retired");
  return result;
}
