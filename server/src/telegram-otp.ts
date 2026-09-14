import type { OTPDelivery } from "./auth";
import { normalizePhone } from "./crypto";

const ENDPOINT = "https://gatewayapi.telegram.org/sendVerificationMessage";
const PHONE = /^\+[1-9]\d{7,14}$/;
// Telegram documents `error` as an uppercase code (e.g. ACCESS_TOKEN_INVALID) but publishes no
// enum, so only that exact shape is ever logged. A phone number, a six-digit code, and a gateway
// token all fail this pattern, so an unexpected provider string is reported as "unrecognized".
const ERROR_CODE = /^[A-Z][A-Z0-9_]{2,63}$/;

const digitsOf = (phone: string): string => phone.replace(/\D/g, "");

/** The only provider detail ever logged: a fixed tag, an HTTP status, or an uppercase error code. */
function errorCode(body: unknown): string {
  const value = (body as { error?: unknown } | null)?.error;
  return typeof value === "string" && ERROR_CODE.test(value) ? value : "unrecognized";
}

/** Private staging only. Configuration is deliberately separate from merely storing a token. */
export function telegramOTPFromEnvironment(env: NodeJS.ProcessEnv = process.env): TelegramOTPDelivery | null {
  if (env.TOJ_OTP_PROVIDER !== "telegram") return null;
  if (env.NODE_ENV !== "staging") throw new Error("Telegram OTP is restricted to staging");
  if (env.TOJ_RETURN_OTP !== "0") throw new Error("Telegram OTP requires TOJ_RETURN_OTP=0");
  const token = env.TOJ_TELEGRAM_GATEWAY_TOKEN ?? "";
  if (!token || /\s/.test(token)) throw new Error("TOJ_TELEGRAM_GATEWAY_TOKEN is missing or malformed");
  // Separators are normalized exactly as the login path normalizes them, so a privately pasted
  // "+992 93 123 4567" configures the pilot instead of crash-looping the deployment.
  const phones = (env.TOJ_TELEGRAM_TEST_ALLOWLIST ?? "")
    .split(",").map((phone) => normalizePhone(phone.trim()));
  if (phones.length > 5 || phones.some((phone) => !PHONE.test(phone))) {
    throw new Error("TOJ_TELEGRAM_TEST_ALLOWLIST requires 1 to 5 exact international phone numbers");
  }
  return new TelegramOTPDelivery(token, phones);
}

export class TelegramOTPDelivery implements OTPDelivery {
  readonly channel = "telegram" as const;
  // Counts all OTP challenges in this database, including failed sends, across restarts.
  readonly dailyRequestLimit = 10;
  private readonly phones: ReadonlySet<string>;

  constructor(
    private readonly token: string,
    phones: readonly string[],
    private readonly transport: (url: string, init: RequestInit) => Promise<Response> = fetch,
  ) {
    this.phones = new Set(phones);
  }

  allows(phone: string): boolean { return this.phones.has(phone); }

  async send(phone: string, code: string, purpose: "login" | "account_deletion" | "security_change"): Promise<void> {
    // Second, independent enforcement of the purpose scope decided in startVerification: deletion
    // codes would reopen the request budget as resettable, because deleteAccount clears the very
    // otp_challenges rows the budget counts.
    if (!this.allows(phone) || !PHONE.test(phone) || !/^\d{6}$/.test(code)
      || (purpose !== "login" && purpose !== "security_change")) {
      throw new Error("Telegram OTP request rejected");
    }
    // Stays "transport_error" until a response is classified, so a thrown reason below is never
    // re-derived from an exception message that could quote provider input.
    let reason = "transport_error";
    try {
      // No checkSendAbility preflight: successful checks are billable. No retries or redirects:
      // ambiguous failures may already have dispatched a message and must not double-charge.
      const response = await this.transport(ENDPOINT, {
        method: "POST",
        headers: { authorization: `Bearer ${this.token}`, "content-type": "application/json" },
        body: JSON.stringify({ phone_number: phone, code, ttl: 300 }),
        signal: AbortSignal.timeout(10_000),
        redirect: "error",
      });
      const body = await response.json().catch(() => null) as any;
      if (!response.ok || body?.ok !== true) {
        reason = `http_${response.status}:${errorCode(body)}`;
        throw new Error(reason);
      }
      const result = body.result;
      if (typeof result?.request_id !== "string" || !result.request_id
        || !Number.isFinite(result.request_cost) || result.request_cost < 0) {
        reason = "malformed_response";
        throw new Error(reason);
      }
      // Telegram echoes E.164 but does not guarantee the leading "+" survives verbatim. Comparing
      // digits keeps an accepted — and possibly already billed and delivered — send from being
      // discarded over formatting, which would strand the recipient with an unusable code.
      if (digitsOf(String(result.phone_number ?? "")) !== digitsOf(phone)) {
        reason = "phone_mismatch";
        throw new Error(reason);
      }
      const status = result.delivery_status?.status;
      if (status === "expired" || status === "revoked") {
        reason = `delivery_${status}`;
        throw new Error(reason);
      }
      // Acceptance is not proof of delivery/phone ownership. Only our OTP check authenticates.
      // Do not return or log provider JSON: it contains the phone and potentially entered codes.
    } catch (error) {
      if (reason === "transport_error") {
        const name = error instanceof Error ? error.name : "";
        if (name === "TimeoutError" || name === "AbortError") reason = "timeout";
        else if (name === "TypeError") reason = "network";
      }
      // Operators need to tell an invalid token from an empty balance from a timeout; the tag
      // above is the whole diagnostic, and it never carries the token, phone, or code.
      console.error(new Date().toISOString(), "auth.otp.telegram_failed", reason);
      throw new Error("Telegram OTP delivery unavailable");
    }
  }
}
