# Pre-registration: OTP fraud rules on replayed SMS pumping

Committed before the replay harness first ran and before any threshold was tuned. The commit that
adds this file is the registration; later commits may add results but must not edit anything above
the "Amendments" heading. Any change after registration is appended there, with its reason and the
date, and the report states which numbers it affects.

Everything here is simulated. Toj has zero real users, and the legitimate traffic, attack traffic,
network layout and delivery behaviour below are assumptions, not measurements.

## 1. What is evaluated

`server/src/otp-risk.ts` maps request features to exactly one of `allow`, `require_channel`,
`block`, `shadow`, always with a rule id and a reason. It is called from `startVerification` before
the daily budget, through a clock seam, against local PostgreSQL. The harness,
`server/scripts/otp-fraud-replay.ts`, drives the real `startVerification` and the real code-check
path with a fake delivery provider that records every billed message.

## 2. Prices

- SMS: **$0.4505** per message (Twilio's published price to +992), billed on every send because
  Tajik routes return no delivery receipts, so a send can never be shown to have failed.
- Telegram Gateway: **$0.01** per message.
- Money is counted in integer micro-dollars.

## 3. Legitimate traffic

- Horizon: **4 simulated days** per seed, starting 00:00 Asia/Dushanbe (UTC+5) on day 1. Day 1 has
  no attack and serves as warm-up for the trailing-window features.
- Volume: **2,000 sign-up attempts per day**, the main condition. Sensitivity runs at 500 and
  5,000 per day are reported but never tuned on.
- Diurnal curve: arrivals per local hour follow these weights (hours 00 to 23):
  `2,1,1,1,1,2,3,5,6,6,6,6,6,6,6,6,6,7,8,9,9,8,6,4`.
- Operators, by share of attempts: **Tcell 36%, MegaFon 28%, ZET-Mobile 20%, Babilon-M 15%**, and
  **1% foreign** numbers (Russia, +7, the largest diaspora). Each operator is assigned two
  illustrative +992 two-digit ranges; the mapping is not checked against the national numbering
  plan and nothing depends on which range is which. Numbers are drawn uniformly inside a range.
- Networks: **85% of attempts arrive over mobile data** from their operator's carrier-grade NAT
  pool of **64 shared addresses**; 15% arrive over home Wi-Fi from an address of their own.
- Delivery: 60% of users are urban and 40% rural. Each SMS reaches an urban user with probability
  **0.97** and a rural user with **0.87**. A Telegram code reaches its user with probability 0.99.
- Behaviour: a user who receives a code enters it after 30 to 240 seconds with probability 0.97,
  and otherwise abandons. A user whose code does not arrive asks again after 60 to 180 seconds, up
  to **3 requests** in total, then abandons. This yields a per-request verify rate between 85% and
  95% depending on the mix, which the report states per seed.
- Telegram: a user holds a Telegram account with probability **0.5** (sensitivity 0.2 and 0.8,
  reported, never tuned). Holders pick Telegram first with probability 0.3; everyone else picks SMS.
  A user told `require_channel` switches to Telegram if they hold it, and otherwise fails.

## 4. Attack shapes

Every attacker requests SMS only, never enters a code, and starts at a seeded random time between
the start of day 2 and the start of day 3. Attacks that would run past day 4 are cut at the horizon.

| Id | Shape | Numbers | Rate | Networks |
|---|---|---|---|---|
| A | Burst to a foreign premium range | random in `+88216` | 400 requests over 2 hours | 50 rotating proxy addresses |
| B | Pumping inside a Tajik prefix (the hard case) | random in one Tcell range | 20 per hour for 48 hours, following the diurnal curve | 200 rotating residential addresses |
| C | Low and slow, foreign | random in 10 foreign ranges | 3 per hour per range for 48 hours | 500 rotating addresses |
| D | Spread across Tajik prefixes | random across all 8 Tajik ranges | 40 per hour for 24 hours | 200 rotating residential addresses |

A and B are required; C and D run if time allows. Each shape is replayed on its own on top of
legitimate traffic. The per-phone limit (5 per 15 minutes) and the 30-second cooldown still apply
to attackers; attackers pick fresh numbers, so they rarely bind.

## 5. Rules and their registered thresholds

These are the evaluation thresholds before tuning. Production thresholds are loaded from
`TOJ_OTP_RISK_RULES` and never committed.

| Rule | Fires when | Action |
|---|---|---|
| `foreign_prefix_velocity` | a non-+992 prefix has more than **20** requests in the trailing hour | `block` |
| `prefix_verify_rate` | a prefix has at least **50** SMS sends in the trailing 6 hours, counting only sends at least 10 minutes old, and fewer than **60%** of them verified | `require_channel` for +992, `block` otherwise |
| `network_velocity` | one network key has more than **30** requests in the trailing hour | `require_channel` |
| `prefix_surge` | a prefix's trailing-hour count exceeds **3x** its mean hourly count over the preceding 23 hours plus **20** | `require_channel` |

A request matching several rules takes the strictest action (`block` over `require_channel` over
`allow`); the rule id reported is the first strictest match in the order above. `require_channel`
refuses SMS and allows Telegram. In `shadow` mode every decision is logged and the request allowed.

A prefix is the country calling code plus the next two digits (`+99292`, `+7916`, `+88216`); the
full number is never stored beside it. All windows read `otp_challenges`, which cleanup retains for
more than 24 hours.

Tuning may change only the numbers in this table and the window lengths. It may not add, remove
or reorder rules, change an action, or look at held-out seeds.

## 6. Seeds

Seeds **0 to 19**. Seeds **0 to 14** are for tuning. Seeds **15 to 19** are held out: they are run
exactly once, after the thresholds are frozen in a commit, and every headline number comes from
them. The number of tuning iterations is recorded.

## 7. Metrics

Per shape, as the mean over seeds, with the minimum and maximum:

1. **Attack sends blocked**: attack SMS requests that produced no billed SMS, over all attack SMS
   requests. A request refused by an existing control counts as blocked, and the report separates
   blocks by the new rules from blocks by existing controls.
2. **Real sign-ups blocked**: legitimate users who never verified because a risk decision refused
   them (`block`, or `require_channel` without Telegram), over all legitimate users. Reported
   beside the no-rule failure rate, which comes from delivery loss alone.
3. **Users steered to Telegram**: legitimate users who got `require_channel` and then verified
   through Telegram, over all legitimate users.
4. **Dollars saved**: total spend under the no-rule configuration minus total spend under the
   evaluated configuration, SMS at $0.4505 and Telegram at $0.01.

## 8. Configurations compared

1. **Today's controls**: the per-phone window (5 per 15 minutes), per-network window (20 per 15
   minutes, keyed on the client address) and 30-second cooldown, with no daily budget.
2. **Global budget**: today's controls plus the global 10-per-day challenge budget.
3. **Rules**: today's controls plus the four rules above, enforcing.

## Amendments

None.
