/**
 * Explainable fraud rules for OTP requests.
 *
 * `decideOtpRisk` is a pure function from request features to one action, always with the id of
 * the rule that produced it and a human-readable reason, so an operator reading the decision log
 * can see exactly why a request was refused and which number to change. Feature collection and
 * enforcement live in `startVerification` (auth.ts).
 *
 * Thresholds are data, not code. The evaluation ruleset below is what the replay in
 * `scripts/otp-fraud-replay.ts` was registered and tuned against; a deployment supplies its own in
 * `TOJ_OTP_RISK_RULES`, which is never committed, so the public repository never states where the
 * live lines are.
 */

export type OtpRiskAction = "allow" | "require_channel" | "block" | "shadow";
export type OtpRiskMode = "off" | "shadow" | "enforce";

export type OtpRiskRules = {
  /** `foreign_prefix_velocity`: requests per trailing hour to one non-home prefix. */
  foreignPrefixPerHour: number;
  /** `prefix_verify_rate`: minimum settled SMS sends in the window before the rate is trusted. */
  verifyRateMinSends: number;
  /** `prefix_verify_rate`: verified share below which the prefix is treated as pumped. */
  verifyRateFloor: number;
  verifyRateWindowMinutes: number;
  /** Sends younger than this are still in flight and count neither way. */
  verifyRateSettleMinutes: number;
  /** `network_velocity`: requests per trailing hour from one network key. */
  networkPerHour: number;
  /** `prefix_surge`: trailing-hour count above multiplier x (mean hourly count over the prior 23h) + floor. */
  surgeMultiplier: number;
  surgeFloor: number;
};

export type OtpRiskFeatures = {
  channel: string;
  phonePrefix: string;
  domestic: boolean;
  prefixLastHour: number;
  /** Requests to the prefix in the 23 hours before the trailing hour. */
  prefixPrior23Hours: number;
  prefixSettledSmsSends: number;
  prefixSettledSmsVerified: number;
  /** Null when the request carried no network key. */
  networkLastHour: number | null;
};

export type OtpRiskDecision = {
  /** What was recorded: in shadow mode this is `shadow` whenever a rule fired. */
  action: OtpRiskAction;
  /** What the rules would do when enforcing. */
  wouldAction: Exclude<OtpRiskAction, "shadow">;
  ruleId: string;
  reason: string;
};

export const HOME_COUNTRY_CODE = "992";

/**
 * The evaluation ruleset: the table registered in docs/results/otp-fraud-preregistration.md after
 * five tuning iterations on seeds 0 to 14 (docs/results/otp-fraud/tuning-log.md), frozen before the
 * held-out seeds ran. Illustrative for a deployment: set TOJ_OTP_RISK_RULES instead.
 */
export const EVALUATION_OTP_RISK_RULES: OtpRiskRules = {
  foreignPrefixPerHour: 3,
  verifyRateMinSends: 10,
  verifyRateFloor: 0.5,
  verifyRateWindowMinutes: 720,
  verifyRateSettleMinutes: 10,
  networkPerHour: 30,
  surgeMultiplier: 3,
  surgeFloor: 20,
};

/** The registered, untuned table (iteration 0), kept so the tuning log can be reproduced. */
export const REGISTERED_OTP_RISK_RULES: OtpRiskRules = {
  foreignPrefixPerHour: 20,
  verifyRateMinSends: 50,
  verifyRateFloor: 0.6,
  verifyRateWindowMinutes: 360,
  verifyRateSettleMinutes: 10,
  networkPerHour: 30,
  surgeMultiplier: 3,
  surgeFloor: 20,
};

// ITU-T E.164 calling codes are one digit (1, 7), one of these two-digit codes, or three digits.
const TWO_DIGIT_CALLING_CODES = new Set([
  "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47",
  "48", "49", "51", "52", "53", "54", "55", "56", "57", "58", "60", "61", "62", "63", "64", "65",
  "66", "81", "82", "84", "86", "90", "91", "92", "93", "94", "95", "98",
]);

export function callingCode(e164: string): string {
  const digits = e164.startsWith("+") ? e164.slice(1) : e164;
  if (!/^[1-9]\d{6,14}$/.test(digits)) throw new Error("phone must be E.164");
  if (digits[0] === "1" || digits[0] === "7") return digits[0];
  if (TWO_DIGIT_CALLING_CODES.has(digits.slice(0, 2))) return digits.slice(0, 2);
  return digits.slice(0, 3);
}

/**
 * Calling code plus the next two digits: an operator range inside Tajikistan, a region or carrier
 * block elsewhere. Coarse on purpose. It is the only phone-derived value the risk tables keep, and
 * it cannot be turned back into a number.
 */
export function phonePrefix(e164: string): string {
  const code = callingCode(e164);
  const digits = e164.replace(/^\+/, "");
  return `+${digits.slice(0, code.length + 2)}`;
}

const STRICTNESS: Record<Exclude<OtpRiskAction, "shadow">, number> = {
  allow: 0, require_channel: 1, block: 2,
};

export function decideOtpRisk(
  features: OtpRiskFeatures,
  rules: OtpRiskRules,
  mode: Exclude<OtpRiskMode, "off"> = "enforce",
): OtpRiskDecision {
  const fired: { ruleId: string; action: "require_channel" | "block"; reason: string }[] = [];
  const prefix = features.phonePrefix;

  if (!features.domestic && features.prefixLastHour > rules.foreignPrefixPerHour) {
    fired.push({
      ruleId: "foreign_prefix_velocity",
      action: "block",
      reason: `${prefix}: ${features.prefixLastHour} requests in the last hour, limit ${rules.foreignPrefixPerHour}`,
    });
  }
  if (features.prefixSettledSmsSends >= rules.verifyRateMinSends) {
    const rate = features.prefixSettledSmsVerified / features.prefixSettledSmsSends;
    if (rate < rules.verifyRateFloor) {
      fired.push({
        ruleId: "prefix_verify_rate",
        action: features.domestic ? "require_channel" : "block",
        reason: `${prefix}: ${features.prefixSettledSmsVerified} of ${features.prefixSettledSmsSends} SMS `
          + `verified (${(rate * 100).toFixed(1)}%), floor ${(rules.verifyRateFloor * 100).toFixed(1)}%`,
      });
    }
  }
  if (features.networkLastHour != null && features.networkLastHour > rules.networkPerHour) {
    fired.push({
      ruleId: "network_velocity",
      action: "require_channel",
      reason: `network: ${features.networkLastHour} requests in the last hour, limit ${rules.networkPerHour}`,
    });
  }
  const baseline = features.prefixPrior23Hours / 23;
  const surgeLimit = rules.surgeMultiplier * baseline + rules.surgeFloor;
  if (features.prefixLastHour > surgeLimit) {
    fired.push({
      ruleId: "prefix_surge",
      action: "require_channel",
      reason: `${prefix}: ${features.prefixLastHour} requests in the last hour against a `
        + `${baseline.toFixed(1)}/hour baseline, limit ${surgeLimit.toFixed(1)}`,
    });
  }

  if (fired.length === 0) {
    return { action: "allow", wouldAction: "allow", ruleId: "none", reason: "no rule fired" };
  }
  // Strictest action wins; among equals, the first rule in registered order.
  const strictest = fired.reduce((best, next) =>
    STRICTNESS[next.action] > STRICTNESS[best.action] ? next : best);
  let wouldAction: Exclude<OtpRiskAction, "shadow"> = strictest.action;
  let reason = strictest.reason;
  if (wouldAction === "require_channel" && features.channel !== "sms") {
    wouldAction = "allow";
    reason = `${reason}; ${features.channel} already avoids SMS`;
  }
  return {
    action: mode === "shadow" && wouldAction !== "allow" ? "shadow" : wouldAction,
    wouldAction,
    ruleId: strictest.ruleId,
    reason,
  };
}

export type OtpRiskConfig = {
  mode: OtpRiskMode;
  rules: OtpRiskRules;
  /** Integer micro-dollars per message, by channel. A channel without a price reserves nothing. */
  pricesMicros: Partial<Record<string, number>>;
  /** Integer micro-dollars per UTC day across all channels, or null for no ceiling. */
  dailySpendCeilingMicros: number | null;
};

export const DEFAULT_OTP_PRICES_MICROS = {
  sms: 450_500,      // $0.4505, Twilio's published price to +992
  telegram: 10_000,  // $0.01, Telegram Gateway
  whatsapp: 3_400,   // $0.0034, Meta authentication template
} as const;

function nonNegativeInteger(value: string | undefined, name: string): number | null {
  if (value == null || value === "") return null;
  if (!/^\d+$/.test(value)) throw new Error(`${name} must be a non-negative integer`);
  return Number(value);
}

export function parseOtpRiskRules(raw: string): OtpRiskRules {
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  const rules = { ...EVALUATION_OTP_RISK_RULES };
  for (const key of Object.keys(parsed)) {
    if (!(key in rules)) throw new Error(`TOJ_OTP_RISK_RULES: unknown field ${key}`);
    const value = parsed[key];
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
      throw new Error(`TOJ_OTP_RISK_RULES: ${key} must be a non-negative number`);
    }
    (rules as Record<string, number>)[key] = value;
  }
  if (rules.verifyRateFloor > 1) throw new Error("TOJ_OTP_RISK_RULES: verifyRateFloor must be at most 1");
  return rules;
}

/**
 * Off unless TOJ_OTP_RISK_MODE says otherwise. A hosted deployment that turns the rules on must
 * also supply its own thresholds: silently running on the published evaluation numbers would hand
 * attackers the exact limits.
 */
export function otpRiskConfigFromEnvironment(env: Record<string, string | undefined> = process.env): OtpRiskConfig {
  const mode = (env.TOJ_OTP_RISK_MODE ?? "off") as OtpRiskMode;
  if (!["off", "shadow", "enforce"].includes(mode)) {
    throw new Error("TOJ_OTP_RISK_MODE must be off, shadow or enforce");
  }
  const hosted = env.NODE_ENV === "production" || env.NODE_ENV === "staging";
  if (mode !== "off" && hosted && !env.TOJ_OTP_RISK_RULES) {
    throw new Error("TOJ_OTP_RISK_RULES is required when TOJ_OTP_RISK_MODE is not off");
  }
  const pricesMicros: Partial<Record<string, number>> = { ...DEFAULT_OTP_PRICES_MICROS };
  for (const channel of Object.keys(DEFAULT_OTP_PRICES_MICROS)) {
    const name = `TOJ_OTP_PRICE_MICROS_${channel.toUpperCase()}`;
    const override = nonNegativeInteger(env[name], name);
    if (override != null) pricesMicros[channel] = override;
  }
  return {
    mode,
    rules: env.TOJ_OTP_RISK_RULES ? parseOtpRiskRules(env.TOJ_OTP_RISK_RULES) : EVALUATION_OTP_RISK_RULES,
    pricesMicros,
    dailySpendCeilingMicros: nonNegativeInteger(
      env.TOJ_OTP_DAILY_SPEND_CEILING_MICROS, "TOJ_OTP_DAILY_SPEND_CEILING_MICROS",
    ),
  };
}
