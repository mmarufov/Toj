// Headless sync client for the chaos harness. It speaks the same HTTP + WebSocket protocol as the
// iOS app, but it is not the iOS app: it models the outbox (one send in flight, retried with the
// same clientMsgId until acknowledged) and the catch-up loop (a pts cursor paged through
// /v1/sync/difference, triggered by WebSocket hints and reconnects). What it proves is about the
// server and the protocol, not about CloudAppModel or CloudLocalStore.

import { createHash } from "node:crypto";

export type ClientEndpoints = {
  /** Base URL for measured traffic, normally the Toxiproxy listener. */
  apiBase: string;
  /** Base URL for sign-in and dialog setup, which is not part of the measurement. */
  setupBase: string;
};

export type ClientStats = {
  sendAttempts: number;
  sendFailures: number;
  /** A retry whose reply said duplicate: true, i.e. an earlier attempt had committed. */
  duplicateAcks: number;
  /** An HTTP send attempt that failed after this device had already applied its own echo. */
  lateFailuresAfterEcho: number;
  syncCalls: number;
  syncFailures: number;
  /** Updates received whose pts this device had already applied. */
  redeliveredUpdates: number;
  /** A clientMsgId that arrived with a second, different msg_id. */
  conflictingEchoes: number;
  wsConnects: number;
  wsHints: number;
  fatalErrors: string[];
};

type StoredMessage = { msgId: number; senderAccountId: string; textHash: string };

type WireUpdate = {
  pts: number;
  type: string;
  message?: {
    dialog_id: string;
    msg_id: number;
    sender_account_id: string;
    client_msg_id: string;
    text?: string;
  } | null;
};

type WireDifference =
  | { kind: "difference_too_long"; state: { pts: number } }
  | { kind: "difference" | "difference_slice"; state: { pts: number }; updates: WireUpdate[] };

// Measured requests each open a fresh TCP connection. Toxiproxy rolls a toxic's toxicity once per
// link, so reuse would make a 20% fault hit one long-lived link or none; and Bun's fetch silently
// re-sends a request whose reused keep-alive socket closed, which hides the failure from the
// outbox logic this client exists to exercise.
const SEND_TIMEOUT_MS = 8_000;
const SYNC_TIMEOUT_MS = 20_000;
const PING_INTERVAL_MS = 5_000;
const WS_DEAD_AFTER_MS = 12_000;

export function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

/** Canonical state digest: one line per message, sorted, so two devices compare by value. */
export function stateDigest(messages: Iterable<[string, StoredMessage]>): string {
  const lines = [...messages]
    .map(([clientMsgId, m]) => `${m.msgId}|${clientMsgId}|${m.senderAccountId}|${m.textHash}`)
    .sort();
  return sha256(lines.join("\n"));
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function backoff(attempt: number): number {
  const base = Math.min(2_000, 100 * 2 ** Math.min(attempt, 5));
  return base / 2 + Math.random() * (base / 2);
}

/** Retryable in the same sense as the iOS client: transport errors, 408, 425, 429 and 5xx. */
function retryableStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

export class SyncClient {
  readonly name: string;
  readonly endpoints: ClientEndpoints;
  accountId = "";
  deviceId = "";
  private token = "";
  dialogId = "";

  pts = 0;
  private readonly appliedPts = new Set<number>();
  readonly messages = new Map<string, StoredMessage>();
  private readonly echoApplied = new Set<string>();
  readonly stats: ClientStats = {
    sendAttempts: 0, sendFailures: 0, duplicateAcks: 0, lateFailuresAfterEcho: 0,
    syncCalls: 0, syncFailures: 0, redeliveredUpdates: 0, conflictingEchoes: 0,
    wsConnects: 0, wsHints: 0, fatalErrors: [],
  };

  private ws: WebSocket | null = null;
  private wsLastSeen = 0;
  private wsTimer: ReturnType<typeof setInterval> | null = null;
  private stopped = false;
  private syncRunning: Promise<void> | null = null;
  private syncDirty = false;

  constructor(name: string, endpoints: ClientEndpoints) {
    this.name = name;
    this.endpoints = endpoints;
  }

  // Sign-in uses the non-production OTP path: outside production, /v1/auth/start returns the code.
  async signIn(phone: string, displayName: string): Promise<void> {
    const started = await this.setupPost("/v1/auth/start", { phone });
    if (typeof started.code !== "string") throw new Error("auth/start did not return a code");
    const session = await this.setupPost("/v1/auth/check", {
      phone, code: started.code, platform: "ios", deviceName: this.name, displayName,
    });
    this.accountId = String(session.accountId);
    this.deviceId = String(session.deviceId);
    this.token = String(session.token);
  }

  async openDirectDialog(peerAccountId: string): Promise<string> {
    const result = await this.setupPost("/v1/dialogs/direct", { peerAccountId }, true);
    return String(result.dialogId);
  }

  private async setupPost(path: string, body: unknown, authed = false): Promise<Record<string, unknown>> {
    const response = await fetch(`${this.endpoints.setupBase}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(authed ? { authorization: `Bearer ${this.token}` } : {}),
      },
      body: JSON.stringify(body),
    });
    if (!response.ok) throw new Error(`${path} failed with ${response.status}`);
    return await response.json() as Record<string, unknown>;
  }

  start(): void {
    this.connect();
    this.wsTimer = setInterval(() => this.keepAlive(), PING_INTERVAL_MS);
    this.requestSync();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.wsTimer) clearInterval(this.wsTimer);
    this.ws?.close();
    await this.syncRunning?.catch(() => undefined);
  }

  private connect(): void {
    if (this.stopped) return;
    const url = `${this.endpoints.apiBase.replace(/^http/, "ws")}/v1/ws`;
    // Bun's WebSocket accepts headers, so the bearer token never goes in the URL.
    const ws = new WebSocket(url, { headers: { authorization: `Bearer ${this.token}` } });
    this.ws = ws;
    this.wsLastSeen = Date.now();
    let reconnecting = false;
    const reconnect = () => {
      if (reconnecting || this.stopped) return;
      reconnecting = true;
      if (this.ws === ws) this.ws = null;
      setTimeout(() => this.connect(), 250 + Math.random() * 750);
    };
    ws.onopen = () => {
      this.stats.wsConnects += 1;
      this.wsLastSeen = Date.now();
      // A reconnect may have missed hints, so it always pages catch-up.
      this.requestSync();
    };
    ws.onmessage = (event) => {
      this.wsLastSeen = Date.now();
      const text = String(event.data);
      if (text === "pong") return;
      try {
        const hint = JSON.parse(text) as { type?: string; pts?: number };
        if (hint.type === "sync_hint") {
          this.stats.wsHints += 1;
          if (Number(hint.pts) > this.pts) this.requestSync();
        }
      } catch {
        // Non-JSON frames are not part of the sync protocol.
      }
    };
    ws.onclose = reconnect;
    ws.onerror = () => { try { ws.close(); } catch { /* already closed */ } reconnect(); };
  }

  // A proxy that silently drops data leaves the socket open; the ping deadline finds it.
  private keepAlive(): void {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    if (Date.now() - this.wsLastSeen > WS_DEAD_AFTER_MS) {
      ws.close();
      return;
    }
    try { ws.send("ping"); } catch { ws.close(); }
  }

  /** Coalesces triggers: at most one catch-up loop runs, and a trigger during it reruns it. */
  requestSync(): void {
    this.syncDirty = true;
    if (this.syncRunning || this.stopped) return;
    this.syncRunning = (async () => {
      try {
        while (this.syncDirty && !this.stopped) {
          this.syncDirty = false;
          await this.catchUp();
        }
      } finally {
        this.syncRunning = null;
      }
    })();
  }

  get syncing(): boolean {
    return this.syncRunning != null;
  }

  private async catchUp(): Promise<void> {
    let attempt = 0;
    while (!this.stopped) {
      this.stats.syncCalls += 1;
      let difference: WireDifference;
      try {
        const response = await fetch(`${this.endpoints.apiBase}/v1/sync/difference`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${this.token}` },
          body: JSON.stringify({ sincePts: this.pts, maxEvents: 200 }),
          signal: AbortSignal.timeout(SYNC_TIMEOUT_MS),
          keepalive: false,
        });
        if (!response.ok) throw new Error(`difference ${response.status}`);
        difference = await response.json() as WireDifference;
      } catch {
        this.stats.syncFailures += 1;
        await sleep(backoff(attempt++));
        continue;
      }
      attempt = 0;
      if (difference.kind === "difference_too_long") {
        this.stats.fatalErrors.push("difference_too_long");
        return;
      }
      for (const update of difference.updates) this.apply(update);
      // Mirror the iOS client: the server's returned state is the cursor.
      this.pts = difference.state.pts;
      if (difference.kind === "difference") return;
    }
  }

  private apply(update: WireUpdate): void {
    if (this.appliedPts.has(update.pts)) {
      this.stats.redeliveredUpdates += 1;
      return;
    }
    this.appliedPts.add(update.pts);
    const message = update.message;
    if (update.type !== "message.new" || !message || message.dialog_id !== this.dialogId) return;
    const existing = this.messages.get(message.client_msg_id);
    if (existing && existing.msgId !== Number(message.msg_id)) this.stats.conflictingEchoes += 1;
    this.messages.set(message.client_msg_id, {
      msgId: Number(message.msg_id),
      senderAccountId: message.sender_account_id,
      textHash: sha256(message.text ?? ""),
    });
    if (message.sender_account_id === this.accountId) this.echoApplied.add(message.client_msg_id);
  }

  /**
   * One outbox item: POST until the server acknowledges it, always with the same clientMsgId.
   * Returns once acknowledged. A reply lost after the server committed shows up here as a failed
   * attempt followed by a duplicate: true acknowledgement.
   */
  async send(clientMsgId: string, body: string): Promise<void> {
    let attempt = 0;
    while (!this.stopped) {
      this.stats.sendAttempts += 1;
      try {
        const response = await fetch(`${this.endpoints.apiBase}/v1/messages/send`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${this.token}` },
          body: JSON.stringify({ dialogId: this.dialogId, clientMsgId, body }),
          signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
          keepalive: false,
        });
        if (response.ok) {
          const result = await response.json() as { duplicate?: boolean };
          if (result.duplicate === true) this.stats.duplicateAcks += 1;
          return;
        }
        if (!retryableStatus(response.status)) {
          this.stats.fatalErrors.push(`send ${response.status}`);
          return;
        }
        throw new Error(`send ${response.status}`);
      } catch {
        this.stats.sendFailures += 1;
        // This is the window the iOS markFailed fix covers: sync already has the echo, and the
        // HTTP attempt still reports failure.
        if (this.echoApplied.has(clientMsgId)) this.stats.lateFailuresAfterEcho += 1;
        await sleep(backoff(attempt++));
      }
    }
  }

  digest(): string {
    return stateDigest(this.messages);
  }
}
