import type { OTPDelivery } from "./auth";
import { normalizePhone } from "./crypto";

const PHONE = /^\+[1-9]\d{7,14}$/;
const ERROR_CODE = /^[A-Z][A-Z0-9_]{2,63}$/;
// A shape check alone would also admit CODE_012345 or PHONE_12025550101. Only emit known
// diagnostic constants, never arbitrary provider strings, even when they resemble an enum.
// https://www.infobip.com/docs/essentials/api-essentials/api-authentication
// https://www.infobip.com/docs/essentials/api-essentials/api-authorization
const SERVICE_ERRORS = new Set(["UNAUTHORIZED", "FORBIDDEN", "BAD_REQUEST", "TOO_MANY_REQUESTS"]);

function serviceErrorCode(body: unknown): string {
  const value = (body as { requestError?: { serviceException?: { messageId?: unknown } } } | null)
    ?.requestError?.serviceException?.messageId;
  return typeof value === "string" && ERROR_CODE.test(value) && SERVICE_ERRORS.has(value)
    ? value : "unrecognized";
}

// SMS-level rejection can arrive inside an HTTP 200. Map numeric IDs to local constants rather
// than trusting status.name/description; a missing mapping stays generic and fails closed.
const SMS_REJECTIONS: Readonly<Record<number, string>> = {
  11: "REJECTED_SOURCE",
  12: "REJECTED_NOT_ENOUGH_CREDITS",
  13: "REJECTED_SENDER",
  17: "REJECTED_PREPAID_PACKAGE_EXPIRED",
  18: "REJECTED_DESTINATION_NOT_REGISTERED",
  19: "REJECTED_ROUTE_NOT_AVAILABLE",
};
const PURPOSE_TEXT = {
  login: "sign-in",
  security_change: "security change",
} as const;

type InfobipOTPOptions = {
  baseUrl: string;
  apiKey: string;
  sender: string;
  /** Exact E.164 numbers verified in the Infobip trial account. No wildcard/default recipients. */
  phones: readonly string[];
};

/**
 * Restricted trial transport only: no environment activation, registry wiring or provider fallback.
 * API contract: https://www.infobip.com/docs/tutorials/send-your-first-sms-message-using-infobip-api
 * Status groups: https://www.infobip.com/docs/essentials/api-essentials/response-status-and-error-codes
 * Resolving send means provider acceptance, not handset delivery or proof of phone ownership.
 */
export class InfobipOTPDelivery implements OTPDelivery {
  readonly channel = "sms" as const;
  // startVerification enforces this against retained otp_challenges across restarts. Row deletion
  // would reopen the budget; account_deletion is rejected below for the same reason as Telegram.
  // This is a daily request cap, NOT a lifetime cap on the account's free trial credits.
  readonly dailyRequestLimit = 10;
  private readonly endpoint: string;
  private readonly apiKey: string;
  private readonly sender: string;
  private readonly phones: ReadonlySet<string>;

  constructor(
    options: InfobipOTPOptions,
    private readonly transport: (url: string, init: RequestInit) => Promise<Response> = fetch,
  ) {
    let url: URL;
    try { url = new URL(options.baseUrl); } catch { throw new Error("Invalid Infobip base URL"); }
    if (url.protocol !== "https:" || url.username || url.password || url.port
      || url.pathname !== "/" || url.search || url.hash
      || !/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)?api\.infobip\.com$/.test(url.hostname)) {
      throw new Error("Invalid Infobip base URL");
    }
    if (!options.apiKey || /[^\x21-\x7e]/.test(options.apiKey)) {
      throw new Error("Invalid Infobip API key");
    }
    // Trial ServiceSMS and approved alphanumeric senders only; no implied registration of Toj.
    if (!/^[A-Za-z0-9]{3,11}$/.test(options.sender) || !/[A-Za-z]/.test(options.sender)) {
      throw new Error("Invalid Infobip sender");
    }
    if (!options.phones.length || options.phones.length > 5
      || options.phones.some((phone) => !PHONE.test(phone))) {
      throw new Error("Infobip requires 1 to 5 exact international test numbers");
    }
    this.endpoint = new URL("/sms/3/messages", url).href;
    this.apiKey = options.apiKey;
    this.sender = options.sender;
    this.phones = new Set(options.phones);
  }

  allows(phone: string): boolean { return this.phones.has(phone); }

  async send(phone: string, code: string, purpose: Parameters<OTPDelivery["send"]>[2]): Promise<void> {
    if (!PHONE.test(phone) || !this.allows(phone) || !/^\d{6}$/.test(code)
      || (purpose !== "login" && purpose !== "security_change")) {
      throw new Error("Infobip OTP request rejected");
    }
    let reason = "transport_error";
    try {
      // No preflight, retries or redirects: a lost response may already have dispatched/billed SMS.
      const response = await this.transport(this.endpoint, {
        method: "POST",
        headers: { authorization: `App ${this.apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ messages: [{
          sender: this.sender,
          destinations: [{ to: phone.slice(1) }],
          content: { text: `Your Toj ${PURPOSE_TEXT[purpose]} code is ${code}. Do not share this code.` },
        }] }),
        signal: AbortSignal.timeout(10_000),
        redirect: "error",
      });
      const body = await response.json().catch(() => null);
      if (!response.ok) {
        reason = `http_${response.status}:${serviceErrorCode(body)}`;
        throw new Error(reason);
      }
      const messages = body?.messages;
      const message = Array.isArray(messages) && messages.length === 1 ? messages[0] : null;
      const status = message?.status;
      if (typeof message?.messageId !== "string" || !message.messageId.trim()
        || typeof message.destination !== "string" || !/^\+?[1-9]\d{7,14}$/.test(message.destination)
        || !Number.isInteger(status?.groupId) || !Number.isInteger(status?.id)) {
        reason = "malformed_response";
        throw new Error(reason);
      }
      if (message.destination.replace(/^\+/, "") !== phone.slice(1)) {
        reason = "phone_mismatch";
        throw new Error(reason);
      }
      const pending = status.groupId === 1 && status.groupName === "PENDING" && [3, 7, 26].includes(status.id);
      const delivered = status.groupId === 3 && status.groupName === "DELIVERED" && [2, 5].includes(status.id);
      if (!pending && !delivered) {
        // Never echo provider descriptions/names/body: they may contain the recipient or OTP.
        const diagnostic = status.groupId === 5 ? SMS_REJECTIONS[status.id] : undefined;
        reason = diagnostic ? `provider_status_rejected:${diagnostic}` : "provider_status_rejected";
        throw new Error(reason);
      }
      // Do not poll reports here: accepted sends must not become failures just because a slow
      // network delays handset delivery. The existing OTP verification authenticates the user.
    } catch (error) {
      if (reason === "transport_error") {
        const name = error instanceof Error ? error.name : "";
        if (name === "TimeoutError" || name === "AbortError") reason = "timeout";
        else if (name === "TypeError") reason = "network";
      }
      console.error(new Date().toISOString(), "auth.otp.infobip_failed", reason);
      throw new Error("Infobip OTP delivery unavailable");
    }
  }
}

/**
 * Restricted staging pilot only, and deliberately separate from merely storing credentials: an API
 * key sitting in the environment must never start sending on its own. Mirrors the Telegram rule.
 */
export function infobipOTPFromEnvironment(
  env: NodeJS.ProcessEnv = process.env,
): InfobipOTPDelivery | null {
  if (env.TOJ_INFOBIP_ENABLED !== "1") return null;
  if (env.NODE_ENV !== "staging") throw new Error("Infobip OTP is restricted to staging");
  if (env.TOJ_RETURN_OTP !== "0") throw new Error("Infobip OTP requires TOJ_RETURN_OTP=0");
  // Separators are normalized exactly as the login path normalizes them, so a privately pasted
  // "+992 93 123 4567" configures the pilot instead of crash-looping the deployment.
  const phones = (env.TOJ_INFOBIP_TEST_ALLOWLIST ?? "")
    .split(",").map((phone) => normalizePhone(phone.trim())).filter((phone) => phone.length > 0);
  return new InfobipOTPDelivery({
    baseUrl: env.TOJ_INFOBIP_BASE_URL ?? "",
    apiKey: env.TOJ_INFOBIP_API_KEY ?? "",
    sender: env.TOJ_INFOBIP_SENDER ?? "",
    phones,
  });
}
