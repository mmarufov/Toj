import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification, type OTPDelivery, type OTPDeliveryRegistry } from "./auth";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { setOtpClock } from "./otp-clock";
import {
  callingCode,
  decideOtpRisk,
  EVALUATION_OTP_RISK_RULES,
  otpRiskConfigFromEnvironment,
  phonePrefix,
  type OtpRiskConfig,
  type OtpRiskFeatures,
} from "./otp-risk";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);
const rules = EVALUATION_OTP_RISK_RULES;

function features(overrides: Partial<OtpRiskFeatures> = {}): OtpRiskFeatures {
  return {
    channel: "sms", phonePrefix: "+99292", domestic: true,
    prefixLastHour: 0, prefixPrior23Hours: 0, prefixSettledSmsSends: 0, prefixSettledSmsVerified: 0,
    networkLastHour: 0, ...overrides,
  };
}

describe("phone prefixes", () => {
  test("keep the calling code and two digits, whatever the code's length", () => {
    expect(phonePrefix("+992921234567")).toBe("+99292");
    expect(phonePrefix("+79161234567")).toBe("+791");
    expect(phonePrefix("+16505550100")).toBe("+165");
    expect(phonePrefix("+442071234567")).toBe("+4420");
    expect(phonePrefix("+882161234567")).toBe("+88216");
    expect(callingCode("+992921234567")).toBe("992");
    expect(() => phonePrefix("+0123")).toThrow();
  });
});

describe("decideOtpRisk", () => {
  test("every decision names a rule and a reason", () => {
    for (const input of [features(), features({ domestic: false, phonePrefix: "+88216", prefixLastHour: 99 })]) {
      const decision = decideOtpRisk(input, rules);
      expect(decision.ruleId.length).toBeGreaterThan(0);
      expect(decision.reason.length).toBeGreaterThan(0);
    }
    expect(decideOtpRisk(features(), rules)).toEqual({
      action: "allow", wouldAction: "allow", ruleId: "none", reason: "no rule fired",
    });
  });

  test("foreign_prefix_velocity blocks a foreign prefix past its hourly limit, never a home one", () => {
    const foreign = { domestic: false, phonePrefix: "+88216" };
    expect(decideOtpRisk(features({ ...foreign, prefixLastHour: rules.foreignPrefixPerHour }), rules).action)
      .toBe("allow");
    expect(decideOtpRisk(features({ ...foreign, prefixLastHour: rules.foreignPrefixPerHour + 1 }), rules))
      .toMatchObject({ action: "block", ruleId: "foreign_prefix_velocity" });
    // The same volume inside +992 is left to the surge rule, which scales with the prefix's own baseline.
    expect(decideOtpRisk(features({ prefixLastHour: rules.foreignPrefixPerHour + 1, prefixPrior23Hours: 23 * 30 }), rules)
      .action).toBe("allow");
  });

  test("prefix_verify_rate needs its minimum sample, then steers home prefixes and blocks foreign ones", () => {
    const floorVerified = Math.ceil(rules.verifyRateMinSends * rules.verifyRateFloor);
    expect(decideOtpRisk(features({ prefixSettledSmsSends: rules.verifyRateMinSends - 1 }), rules).action)
      .toBe("allow");
    expect(decideOtpRisk(features({
      prefixSettledSmsSends: rules.verifyRateMinSends, prefixSettledSmsVerified: floorVerified,
    }), rules).action).toBe("allow");
    expect(decideOtpRisk(features({
      prefixSettledSmsSends: rules.verifyRateMinSends, prefixSettledSmsVerified: floorVerified - 1,
    }), rules)).toMatchObject({ action: "require_channel", ruleId: "prefix_verify_rate" });
    expect(decideOtpRisk(features({
      domestic: false, phonePrefix: "+88216",
      prefixSettledSmsSends: rules.verifyRateMinSends, prefixSettledSmsVerified: 0,
    }), rules)).toMatchObject({ action: "block", ruleId: "prefix_verify_rate" });
  });

  test("network_velocity steers past its hourly limit, and a request without a network key is not counted", () => {
    expect(decideOtpRisk(features({ networkLastHour: rules.networkPerHour }), rules).action).toBe("allow");
    expect(decideOtpRisk(features({ networkLastHour: rules.networkPerHour + 1 }), rules))
      .toMatchObject({ action: "require_channel", ruleId: "network_velocity" });
    expect(decideOtpRisk(features({ networkLastHour: null }), rules).action).toBe("allow");
  });

  test("prefix_surge compares the last hour with the prefix's own 23-hour baseline", () => {
    const prior = 23 * 10;
    const limit = rules.surgeMultiplier * 10 + rules.surgeFloor;
    expect(decideOtpRisk(features({ prefixLastHour: limit, prefixPrior23Hours: prior }), rules).action)
      .toBe("allow");
    expect(decideOtpRisk(features({ prefixLastHour: limit + 1, prefixPrior23Hours: prior }), rules))
      .toMatchObject({ action: "require_channel", ruleId: "prefix_surge" });
  });

  test("the strictest action wins, and a cheaper channel satisfies require_channel", () => {
    const both = features({
      domestic: false, phonePrefix: "+88216", prefixLastHour: 500, networkLastHour: 500,
    });
    expect(decideOtpRisk(both, rules)).toMatchObject({ action: "block", ruleId: "foreign_prefix_velocity" });
    const steered = features({ networkLastHour: rules.networkPerHour + 1, channel: "telegram" });
    const decision = decideOtpRisk(steered, rules);
    expect(decision).toMatchObject({ action: "allow", wouldAction: "allow", ruleId: "network_velocity" });
    expect(decision.reason).toContain("telegram already avoids SMS");
  });

  test("shadow mode records what would have happened and allows the request", () => {
    const decision = decideOtpRisk(features({ networkLastHour: 999 }), rules, "shadow");
    expect(decision).toMatchObject({ action: "shadow", wouldAction: "require_channel", ruleId: "network_velocity" });
  });
});

describe("risk configuration", () => {
  test("off by default, and a hosted deployment must bring its own thresholds", () => {
    expect(otpRiskConfigFromEnvironment({}).mode).toBe("off");
    expect(() => otpRiskConfigFromEnvironment({ NODE_ENV: "staging", TOJ_OTP_RISK_MODE: "enforce" })).toThrow();
    const config = otpRiskConfigFromEnvironment({
      NODE_ENV: "staging", TOJ_OTP_RISK_MODE: "shadow", TOJ_OTP_RISK_RULES: '{"networkPerHour": 7}',
      TOJ_OTP_DAILY_SPEND_CEILING_MICROS: "5000000",
    });
    expect(config.rules.networkPerHour).toBe(7);
    expect(config.rules.foreignPrefixPerHour).toBe(rules.foreignPrefixPerHour);
    expect(config.dailySpendCeilingMicros).toBe(5_000_000);
    expect(config.pricesMicros.sms).toBe(450_500);
    expect(() => otpRiskConfigFromEnvironment({ TOJ_OTP_RISK_RULES: '{"typo": 1}' })).toThrow();
    expect(() => otpRiskConfigFromEnvironment({ TOJ_OTP_RISK_MODE: "on" })).toThrow();
    expect(() => otpRiskConfigFromEnvironment({ TOJ_OTP_DAILY_SPEND_CEILING_MICROS: "1.5" })).toThrow();
  });
});

class RecordingDelivery implements OTPDelivery {
  readonly sent: { phone: string; code: string }[] = [];
  fail = false;
  constructor(readonly channel: "sms" | "telegram") {}
  async send(phone: string, code: string): Promise<void> {
    if (this.fail) throw new Error("provider down");
    this.sent.push({ phone, code });
  }
}

describe("risk rules inside startVerification", () => {
  let clock = new Date("2026-10-05T12:00:00Z");
  const sms = new RecordingDelivery("sms");
  const telegram = new RecordingDelivery("telegram");
  const deliveries: OTPDeliveryRegistry = new Map([["sms", sms], ["telegram", telegram]]);
  const config = (overrides: Partial<OtpRiskConfig> = {}): OtpRiskConfig => ({
    mode: "enforce", rules, pricesMicros: { sms: 450_500, telegram: 10_000 },
    dailySpendCeilingMicros: null, ...overrides,
  });
  const start = (phone: string, channel: "sms" | "telegram", risk = config(), networkKey: string | null = null) =>
    startVerification(db, phone, { deliveries, deliveryChannel: channel, risk, networkKey });

  const returnOTP = process.env.TOJ_RETURN_OTP;
  beforeEach(async () => {
    // The Telegram channel refuses to send unless OTP return is explicitly off.
    process.env.TOJ_RETURN_OTP = "0";
    await db`TRUNCATE accounts, otp_challenges, otp_risk_decisions, otp_spend_reservations RESTART IDENTITY CASCADE`;
    clock = new Date("2026-10-05T12:00:00Z");
    setOtpClock(() => clock);
    sms.sent.length = 0;
    telegram.sent.length = 0;
    sms.fail = false;
  });
  afterEach(() => {
    setOtpClock(null);
    if (returnOTP == null) delete process.env.TOJ_RETURN_OTP; else process.env.TOJ_RETURN_OTP = returnOTP;
  });

  test("a pumped home prefix is steered off SMS, Telegram still works, and both are logged", async () => {
    // 50 settled SMS sends in +99292, 20 verified: 40%, under the 60% floor. Four minutes apart,
    // so no hour holds more than 15 and the surge rule (floor 20 with no baseline) stays quiet.
    for (let i = 0; i < 50; i += 1) {
      await start(`+99292${String(100000 + i)}`, "sms");
      clock = new Date(clock.getTime() + 4 * 60_000);
    }
    await db`UPDATE otp_challenges SET verified_at = created_at
      WHERE id IN (SELECT id FROM otp_challenges ORDER BY created_at LIMIT 20)`;
    clock = new Date(clock.getTime() + 11 * 60_000);

    await expect(start("+992929999999", "sms")).rejects.toMatchObject({ status: 409, code: "sms_unavailable" });
    await expect(start("+992929999999", "telegram")).resolves.toBeDefined();
    // Another operator's range is unaffected.
    await expect(start("+992939999999", "sms")).resolves.toBeDefined();

    const logged = await db`
      SELECT phone_prefix, channel, action, would_action, rule_id FROM otp_risk_decisions
      WHERE rule_id = 'prefix_verify_rate' ORDER BY id`;
    expect(logged).toEqual([
      { phone_prefix: "+99292", channel: "sms", action: "require_channel", would_action: "require_channel", rule_id: "prefix_verify_rate" },
      { phone_prefix: "+99292", channel: "telegram", action: "allow", would_action: "allow", rule_id: "prefix_verify_rate" },
    ]);
    // The log keeps the prefix and nothing more of the number.
    const columns = await db`
      SELECT column_name FROM information_schema.columns WHERE table_name = 'otp_risk_decisions'`;
    expect(columns.map((row: any) => row.column_name).sort()).toEqual([
      "action", "channel", "created_at", "id", "phone_prefix", "purpose", "reason", "rule_id", "would_action",
    ]);
  });

  test("a foreign burst is blocked once the prefix passes its hourly limit, and only within the hour", async () => {
    for (let i = 0; i <= rules.foreignPrefixPerHour; i += 1) {
      await start(`+88216${String(1000000 + i)}`, "sms");
    }
    await expect(start("+882169999999", "sms")).rejects.toMatchObject({
      status: 429, code: "verification_unavailable",
    });
    clock = new Date(clock.getTime() + 61 * 60_000);
    await expect(start("+882169999999", "sms")).resolves.toBeDefined();
  });

  test("verified_at marks a correct code only, never a resend or a failed delivery", async () => {
    const phone = "+992921234567";
    await start(phone, "sms");
    clock = new Date(clock.getTime() + 31_000);
    await start(phone, "sms");
    sms.fail = false;
    await checkVerification(db, phone, sms.sent.at(-1)!.code, "ios", "iPhone", "Risk");
    sms.fail = true;
    clock = new Date(clock.getTime() + 31_000);
    await expect(start("+992921234568", "sms")).rejects.toMatchObject({ status: 503 });
    const rows = await db`SELECT phone_prefix, consumed_at IS NOT NULL AS consumed, verified_at IS NOT NULL AS verified
      FROM otp_challenges ORDER BY created_at`;
    expect(rows).toEqual([
      { phone_prefix: "+99292", consumed: true, verified: false },
      { phone_prefix: "+99292", consumed: true, verified: true },
      { phone_prefix: "+99292", consumed: true, verified: false },
    ]);
  });

  test("spend is reserved in micro-dollars per UTC day, kept on delivery failure, and capped", async () => {
    await start("+992921111111", "sms");
    await start("+992921111112", "telegram");
    sms.fail = true;
    await expect(start("+992921111113", "sms")).rejects.toMatchObject({ status: 503 });
    sms.fail = false;
    const reserved = await db`SELECT channel, reserved_micros::int AS micros, sends::int AS sends
      FROM otp_spend_reservations ORDER BY channel`;
    expect(reserved).toEqual([
      { channel: "sms", micros: 901_000, sends: 2 },
      { channel: "telegram", micros: 10_000, sends: 1 },
    ]);

    // 911,000 reserved. A ceiling that fits one more Telegram code but not one more SMS.
    const capped = config({ dailySpendCeilingMicros: 921_000 });
    await expect(start("+992921111114", "sms", capped)).rejects.toMatchObject({
      status: 429, code: "verification_unavailable",
    });
    await expect(start("+992921111115", "telegram", capped)).resolves.toBeDefined();
    // A new UTC day starts from zero.
    clock = new Date("2026-10-06T00:00:01Z");
    await expect(start("+992921111114", "sms", capped)).resolves.toBeDefined();
  });

  test("off records nothing, shadow records and allows", async () => {
    const noisy = "10.0.0.9";
    // One a minute: 31 in the hour trips network_velocity, 15 per quarter hour stays under the
    // existing 20-per-15-minute network window.
    for (let i = 0; i <= rules.networkPerHour; i += 1) {
      await start(`+99293${String(100000 + i)}`, "sms", config({ mode: "off" }), noisy);
      clock = new Date(clock.getTime() + 60_000);
    }
    expect(await db`SELECT id FROM otp_risk_decisions`).toHaveLength(0);
    await expect(start("+992939999999", "sms", config({ mode: "shadow" }), noisy)).resolves.toBeDefined();
    const [logged] = await db`SELECT action, would_action, rule_id FROM otp_risk_decisions`;
    expect(logged).toEqual({ action: "shadow", would_action: "require_channel", rule_id: "network_velocity" });
    await expect(start("+992939999998", "sms", config(), noisy)).rejects.toMatchObject({ code: "sms_unavailable" });
  });

  test("the clock seam moves the cooldown and the windows together", async () => {
    const phone = "+992921234500";
    await start(phone, "sms");
    await expect(start(phone, "sms")).rejects.toMatchObject({ status: 429 });
    clock = new Date(clock.getTime() + 31_000);
    await expect(start(phone, "sms")).resolves.toBeDefined();
    const [row] = await db`SELECT max(created_at) AS latest FROM otp_challenges`;
    expect(new Date(row.latest).toISOString()).toBe(clock.toISOString());
  });
});

describe("OTP schema readiness", () => {
  test("/ready fails closed when the risk columns are missing", async () => {
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    try {
      const base = `http://127.0.0.1:${server.port}`;
      const healthy = await (await fetch(`${base}/ready`)).json() as any;
      expect(healthy.otpSchema).toBe("ready");
      expect(healthy.status).toBe("ready");
      await db`ALTER TABLE otp_challenges DROP COLUMN phone_prefix`;
      try {
        const response = await fetch(`${base}/ready`);
        const drifted = await response.json() as any;
        expect(response.status).toBe(503);
        expect(drifted.otpSchema).toBe("incomplete");
        expect(drifted.otpSchemaMissing).toEqual(["otp_challenges_phone_prefix"]);
      } finally {
        await db`ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS phone_prefix TEXT`;
      }
    } finally {
      await server.stop(true);
    }
  });
});
