import type { OTPDelivery } from "./auth";
import { normalizePhone } from "./crypto";

const PHONE = /^\+[1-9]\d{7,14}$/;
// The Cloud API has exactly one host, so unlike Infobip's per-account subdomains there is nothing
// to configure. Pinning it rather than accepting a base URL removes the failure mode where a typo
// or a tampered environment ships the access token AND the OTP to somebody else's server.
const HOST = "https://graph.facebook.com";
// Graph versions sunset roughly two years after release; v26.0 shipped 2026-07-29. Pinning is
// deliberate — an unpinned "latest" silently changes request and response shape underneath us —
// but it expires, so review it against Meta's Graph API changelog rather than waiting for 400s.
const DEFAULT_GRAPH_VERSION = "v26.0";
const GRAPH_VERSION = /^v\d{1,3}\.\d{1,3}$/;
const PHONE_NUMBER_ID = /^\d{1,32}$/;
const TEMPLATE_NAME = /^[a-z0-9_]{1,512}$/;
const TEMPLATE_LANGUAGE = /^[a-z]{2,3}(?:_[A-Z]{2})?$/;

// Meta reports failures as a *numeric* `error.code`, and a six-digit OTP is also numeric — so
// echoing an unexpected integer is exactly the shape this file must never emit. The map is an
// allowlist: anything unmapped degrades to "unrecognized", which makes an incomplete list safe by
// construction rather than merely tidy. Extend it from Meta's reference as codes are encountered.
// https://developers.facebook.com/documentation/business-messaging/whatsapp/support/error-codes
const API_ERRORS: Readonly<Record<number, string>> = {
  190: "ACCESS_TOKEN_INVALID",
  368: "ACCOUNT_RESTRICTED",
  130429: "RATE_LIMIT",
  // The one that matters most: recipient not on WhatsApp, or on an old client, or Meta declined to
  // deliver. Meta buckets all of those deliberately and does not disclose which. Billing is on
  // delivery, so this costs nothing — but it is a fallback *signal*, never a reachability statistic.
  131026: "MESSAGE_UNDELIVERABLE",
  131042: "BUSINESS_ELIGIBILITY_PAYMENT",
  131047: "REENGAGEMENT_WINDOW",
  132001: "TEMPLATE_NOT_FOUND",
  133010: "PHONE_NUMBER_NOT_REGISTERED",
};

// Documented send-acknowledgement values. "accepted" is the only one that means the code is on its
// way; a held message may never arrive inside OTP_TTL_MS, so it fails closed and the user re-picks.
const HELD = "held_for_quality_assessment";

function apiErrorCode(body: unknown): string {
  const value = (body as { error?: { code?: unknown } } | null)?.error?.code;
  return typeof value === "number" && Number.isInteger(value) && value in API_ERRORS
    ? API_ERRORS[value]! : "unrecognized";
}

type WhatsAppOTPOptions = {
  accessToken: string;
  phoneNumberId: string;
  /** Approved authentication template. Its body text is fixed by Meta and cannot be reworded. */
  template: string;
  /** Meta has no Tajik (`tg`) template locale, so this is `ru` in practice. Founder-accepted. */
  templateLanguage: string;
  graphVersion?: string;
  /** Exact E.164 numbers cleared for the pilot. No wildcard, no default recipient. */
  phones: readonly string[];
};

/**
 * Restricted pilot transport only: no environment activation, registry wiring or provider fallback.
 *
 * Deliberately absent: `sendSecurityAlert`. An authentication template's body is fixed by Meta and
 * carries only a code, and a security-change notice would need a separately approved utility
 * template. Silently sending a verification code where an alert was meant would be worse than
 * sending nothing, so this channel declines the capability instead of approximating it.
 *
 * Also absent: any reachability preflight. The Cloud API has no contacts endpoint — the one Meta
 * retired with On-Premises — so there is nothing here that could probe a number before the user has
 * picked this channel, which is the disclosure the picker exists to prevent.
 *
 * Resolving means Meta accepted the message. It is not handset delivery and not proof of phone
 * ownership; only the OTP check in auth.ts authenticates.
 */
export class WhatsAppOTPDelivery implements OTPDelivery {
  readonly channel = "whatsapp" as const;
  // startVerification enforces this against retained otp_challenges across restarts. Row deletion
  // would reopen the budget; account_deletion is rejected below for the same reason as Telegram.
  // A daily request cap, NOT a monetary cap on the Meta account.
  readonly dailyRequestLimit = 10;
  private readonly endpoint: string;
  private readonly accessToken: string;
  private readonly template: string;
  private readonly templateLanguage: string;
  private readonly phones: ReadonlySet<string>;

  constructor(
    options: WhatsAppOTPOptions,
    private readonly transport: (url: string, init: RequestInit) => Promise<Response> = fetch,
  ) {
    const version = options.graphVersion ?? DEFAULT_GRAPH_VERSION;
    if (!GRAPH_VERSION.test(version)) throw new Error("Invalid WhatsApp Graph API version");
    if (!PHONE_NUMBER_ID.test(options.phoneNumberId)) {
      throw new Error("Invalid WhatsApp phone number ID");
    }
    // Printable ASCII without spaces: a token carrying CR/LF would be header injection, and one
    // carrying a space is a paste accident that would otherwise fail as an opaque 401 much later.
    if (!options.accessToken || /[^\x21-\x7e]/.test(options.accessToken)) {
      throw new Error("Invalid WhatsApp access token");
    }
    if (!TEMPLATE_NAME.test(options.template)) throw new Error("Invalid WhatsApp template name");
    if (!TEMPLATE_LANGUAGE.test(options.templateLanguage)) {
      throw new Error("Invalid WhatsApp template language");
    }
    if (!options.phones.length || options.phones.length > 5
      || options.phones.some((phone) => !PHONE.test(phone))) {
      throw new Error("WhatsApp requires 1 to 5 exact international test numbers");
    }
    this.endpoint = `${HOST}/${version}/${options.phoneNumberId}/messages`;
    this.accessToken = options.accessToken;
    this.template = options.template;
    this.templateLanguage = options.templateLanguage;
    this.phones = new Set(options.phones);
  }

  allows(phone: string): boolean { return this.phones.has(phone); }

  async send(phone: string, code: string, purpose: Parameters<OTPDelivery["send"]>[2]): Promise<void> {
    // Second, independent enforcement of the purpose scope startVerification already applies:
    // deletion codes would reopen the request budget as resettable, because deleteAccount clears
    // the very otp_challenges rows the budget counts.
    if (!PHONE.test(phone) || !this.allows(phone) || !/^\d{6}$/.test(code)
      || (purpose !== "login" && purpose !== "security_change")) {
      throw new Error("WhatsApp OTP request rejected");
    }
    // Stays "transport_error" until a response is classified, so a thrown reason below is never
    // re-derived from an exception message that could quote provider input.
    let reason = "transport_error";
    try {
      // No preflight, retries or redirects: an ambiguous failure may already have dispatched a
      // message, and Meta bills on delivery, so a retry risks a second charge and a second code.
      const response = await this.transport(this.endpoint, {
        method: "POST",
        headers: {
          authorization: `Bearer ${this.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: phone.slice(1),
          type: "template",
          template: {
            name: this.template,
            language: { code: this.templateLanguage },
            components: [
              { type: "body", parameters: [{ type: "text", text: code }] },
              // The code appears twice by design: once in the fixed body, once as the copy-code
              // button's value. Meta documents the button component as sub_type "url" with a
              // string index even for an OTP button; it is not a typo.
              {
                type: "button", sub_type: "url", index: "0",
                parameters: [{ type: "text", text: code }],
              },
            ],
          },
        }),
        signal: AbortSignal.timeout(10_000),
        redirect: "error",
      });
      const body = await response.json().catch(() => null) as any;
      if (!response.ok) {
        reason = `http_${response.status}:${apiErrorCode(body)}`;
        throw new Error(reason);
      }
      const contact = Array.isArray(body?.contacts) && body.contacts.length === 1
        ? body.contacts[0] : null;
      const message = Array.isArray(body?.messages) && body.messages.length === 1
        ? body.messages[0] : null;
      if (body?.messaging_product !== "whatsapp" || typeof contact?.input !== "string"
        || typeof message?.id !== "string" || !message.id.trim()) {
        reason = "malformed_response";
        throw new Error(reason);
      }
      // `input` is our own number echoed back, so it must match. `wa_id` deliberately is NOT
      // compared: Meta normalizes it per country (the Argentine 9, the Mexican 1), so an equality
      // check there would discard an accepted — and already billable — send over a transformation
      // we do not control. Same lesson as Telegram's dropped "+".
      if (contact.input.replace(/^\+/, "") !== phone.slice(1)) {
        reason = "phone_mismatch";
        throw new Error(reason);
      }
      const status = message.message_status;
      // Absent means an older acknowledgement shape, not a failure — do not discard a send over a
      // field Meta may stop returning. Present means it must say the message is on its way.
      if (status !== undefined && status !== "accepted") {
        reason = status === HELD ? "provider_status_held" : "provider_status_unrecognized";
        throw new Error(reason);
      }
      // Acceptance is not proof of delivery or phone ownership. Only our OTP check authenticates.
      // Do not return or log provider JSON: it contains the phone and, on error, echoed input.
    } catch (error) {
      if (reason === "transport_error") {
        const name = error instanceof Error ? error.name : "";
        if (name === "TimeoutError" || name === "AbortError") reason = "timeout";
        else if (name === "TypeError") reason = "network";
      }
      // Operators need to tell an invalid token from an unpaid account from an unreachable
      // recipient; this tag is the whole diagnostic and never carries the token, phone, or code.
      console.error(new Date().toISOString(), "auth.otp.whatsapp_failed", reason);
      throw new Error("WhatsApp OTP delivery unavailable");
    }
  }
}

/**
 * Restricted staging pilot only, and deliberately separate from merely storing credentials: an
 * access token sitting in the environment must never start sending on its own. Mirrors Telegram
 * and Infobip, including the normalization that keeps a pasted "+992 93 123 4567" from
 * crash-looping the deployment instead of configuring it.
 */
export function whatsappOTPFromEnvironment(
  env: NodeJS.ProcessEnv = process.env,
): WhatsAppOTPDelivery | null {
  if (env.TOJ_WHATSAPP_ENABLED !== "1") return null;
  if (env.NODE_ENV !== "staging") throw new Error("WhatsApp OTP is restricted to staging");
  if (env.TOJ_RETURN_OTP !== "0") throw new Error("WhatsApp OTP requires TOJ_RETURN_OTP=0");
  const phones = (env.TOJ_WHATSAPP_TEST_ALLOWLIST ?? "")
    .split(",").map((phone) => normalizePhone(phone.trim())).filter((phone) => phone.length > 0);
  return new WhatsAppOTPDelivery({
    accessToken: env.TOJ_WHATSAPP_ACCESS_TOKEN ?? "",
    phoneNumberId: env.TOJ_WHATSAPP_PHONE_NUMBER_ID ?? "",
    template: env.TOJ_WHATSAPP_TEMPLATE ?? "",
    templateLanguage: env.TOJ_WHATSAPP_TEMPLATE_LANGUAGE ?? "",
    graphVersion: env.TOJ_WHATSAPP_GRAPH_VERSION || undefined,
    phones,
  });
}
