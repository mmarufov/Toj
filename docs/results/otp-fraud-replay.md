# Results: OTP fraud rules on replayed SMS pumping

**Everything here is simulated.** Toj has zero real users. The legitimate traffic, the attacks, the
network layout and the delivery behaviour are the assumptions registered in
[`otp-fraud-preregistration.md`](otp-fraud-preregistration.md), not measurements, and the attacks
were written by the same person who wrote the rules.

| | |
|---|---|
| Registration | `6a1bf30`, pushed 2026-09-30 19:59 UTC, before the harness existed; amendments 1 to 3 committed before any replay on seeds 0 to 19 |
| Thresholds frozen | `2abaf59` ([`rules-frozen.json`](otp-fraud/rules-frozen.json)), after 5 tuning iterations on seeds 0 to 14 ([tuning log](otp-fraud/tuning-log.md)) |
| Held-out run | seeds 15 to 19, run once, started 2026-09-30 22:34 UTC at `2abaf59`; 60 runs, 3 min 30 s |
| Command | `cd server && bun run scripts/otp-fraud-replay.ts run --seeds 15-19 --shapes A,B,C,D --configs today,budget,rules --workers 8 --out ../docs/results/otp-fraud/heldout.jsonl` |
| Table | `bun run scripts/otp-fraud-replay.ts report --in ../docs/results/otp-fraud/heldout.jsonl` |
| Machine | Apple M5 Pro, 24 GB, macOS 27.0.1; Bun 1.3.11; PostgreSQL 17.10, local |

Each run is 4 simulated days, about 8,000 legitimate sign-ups at 2,000 a day, and one attack shape,
replayed through the real `startVerification` and code check with a fake provider that bills
$0.4505 per SMS and $0.01 per Telegram code. `today` is the per-phone and per-network windows and
the 30-second cooldown. `budget` adds the global 10-per-day challenge budget. `rules` adds the four
rules in `server/src/otp-risk.ts`, enforcing.

## Held-out results

Mean over the 5 held-out seeds, with the range in brackets.

| Shape | Config | Seeds | Attack sends blocked % | of which by new rules % | Real sign-ups refused by rules % | Refused by existing controls % | Steered to Telegram and verified % | Real users verified % | Legit SMS verify rate % | Dollars saved vs today |
|---|---|---|---|---|---|---|---|---|---|---|
| A | budget | 5 | 99.5 (97.8-100.0) | 0.0 (0.0-0.0) | 0.00 (0.00-0.00) | 99.56 (99.51-99.63) | 0.00 (0.00-0.00) | 0.4 (0.4-0.5) | 88.0 (82.8-94.1) | 3470 (3425-3501) |
| A | rules | 5 | 98.0 (98.0-98.0) | 98.0 (98.0-98.0) | 0.04 (0.00-0.10) | 0.00 (0.00-0.00) | 0.03 (0.00-0.06) | 97.0 (96.6-97.3) | 89.9 (89.1-90.6) | 180 (177-181) |
| A | today | 5 | 0.0 (0.0-0.0) | 0.0 (0.0-0.0) | 0.00 (0.00-0.00) | 0.00 (0.00-0.00) | 0.00 (0.00-0.00) | 97.1 (96.7-97.4) | 89.9 (89.1-90.6) | 0 (0-0) |
| B | budget | 5 | 99.4 (99.3-99.6) | 0.0 (0.0-0.0) | 0.00 (0.00-0.00) | 99.60 (99.56-99.64) | 0.00 (0.00-0.00) | 0.4 (0.3-0.4) | 87.3 (81.5-97.0) | 3723 (3677-3770) |
| B | rules | 5 | 84.0 (77.4-88.0) | 84.0 (77.4-88.0) | 4.37 (4.02-4.88) | 0.00 (0.00-0.00) | 3.13 (3.00-3.30) | 92.8 (91.9-93.3) | 89.9 (89.1-90.7) | 657 (627-704) |
| B | today | 5 | 0.0 (0.0-0.0) | 0.0 (0.0-0.0) | 0.00 (0.00-0.00) | 0.00 (0.00-0.00) | 0.00 (0.00-0.00) | 97.1 (96.7-97.4) | 89.9 (89.1-90.6) | 0 (0-0) |
| C | budget | 5 | 99.3 (99.0-99.6) | 0.0 (0.0-0.0) | 0.00 (0.00-0.00) | 99.66 (99.63-99.73) | 0.00 (0.00-0.00) | 0.3 (0.2-0.4) | 87.7 (80.8-100.0) | 3943 (3897-3979) |
| C | rules | 5 | 71.5 (71.3-71.8) | 71.5 (71.3-71.8) | 0.04 (0.00-0.10) | 0.00 (0.00-0.00) | 0.03 (0.00-0.06) | 97.0 (96.6-97.3) | 89.9 (89.1-90.6) | 471 (461-477) |
| C | today | 5 | 0.0 (0.0-0.0) | 0.0 (0.0-0.0) | 0.00 (0.00-0.00) | 0.00 (0.00-0.00) | 0.00 (0.00-0.00) | 97.1 (96.7-97.4) | 89.9 (89.1-90.6) | 0 (0-0) |
| D | budget | 5 | 99.4 (99.2-99.7) | 0.0 (0.0-0.0) | 0.00 (0.00-0.00) | 99.60 (99.57-99.64) | 0.00 (0.00-0.00) | 0.4 (0.4-0.4) | 88.4 (83.3-93.5) | 3726 (3680-3759) |
| D | rules | 5 | 17.2 (10.6-27.2) | 17.2 (10.6-27.2) | 2.54 (1.87-3.35) | 0.00 (0.00-0.00) | 1.67 (1.12-2.19) | 94.6 (93.4-95.5) | 89.9 (89.2-90.5) | 240 (160-341) |
| D | today | 5 | 0.0 (0.0-0.0) | 0.0 (0.0-0.0) | 0.00 (0.00-0.00) | 0.00 (0.00-0.00) | 0.00 (0.00-0.00) | 97.1 (96.7-97.4) | 89.9 (89.1-90.6) | 0 (0-0) |

Reading it:

- **A, a burst to a foreign premium range:** 98.0% of attack sends stopped, all by
  `foreign_prefix_velocity`; 0.04% of real sign-ups refused.
- **B, pumping inside a Tajik prefix (the hard case):** 84.0% stopped, but **4.37% of all real
  sign-ups were refused**, and 3.13% more had to switch to Telegram. `prefix_verify_rate` cannot
  tell a real user from a pumped number inside the range it has marked, so during the attack
  everyone in that range loses SMS; the half without Telegram fail.
- **C, low and slow across 10 foreign ranges:** 71.5% stopped, 0.04% refused. It stays under the
  hourly foreign limit most of the time and is caught by the verify-rate rule once a range has 10
  settled, unverified sends.
- **D, spread across all 8 Tajik ranges:** only 17.2% stopped, for 2.54% refused. At about 5 sends an
  hour per range it barely moves the larger ranges' verify rates. The rules do not handle this shape.
- **The global budget** stops about 99% of every attack and refuses about 99.6% of real users. It
  is a kill switch for a 5-number pilot, not a control for a launch.
- Pooled over every attack send in all four shapes: **63.6% stopped, 1.75% of real sign-ups
  refused** (the shapes have different sizes, so this is not the mean of the rows above).

Rule decisions that refused a request, summed over the 5 held-out runs of each shape:
`foreign_prefix_velocity` 1,961 in A, 374 in C and 1 each in B and D (a legitimate +7 number);
`prefix_verify_rate` 7,040 in B, 4,817 in C, 2,511 in D; `prefix_surge` 30 to 35 per shape, all on
legitimate traffic in the first simulated hours, when no prefix has a baseline yet.

## Where the money goes

"Dollars saved vs today" is total spend under `today` minus total spend under `rules`, over 4
simulated days. It is not all attack money. Mean per held-out run:

| Shape | Attack SMS spend, today | Attack SMS spend, rules | Change in legitimate spend | Saved |
|---|---|---|---|---|
| A | $180 | $4 | -$3 | $180 |
| B | $433 | $69 | -$293 | $657 |
| C | $654 | $186 | -$3 | $471 |
| D | $437 | $362 | -$164 | $240 |

In B and D a large part of the saving is legitimate users who were refused or moved to Telegram,
which costs $0.01 a code instead of $0.4505. That is a real saving only for the users who switched;
for the ones refused it is a lost sign-up counted as money saved.

## Tuning and held-out agreement

The objective (amendment 2) went from 31.08 with the registered thresholds to 49.91 after 5
iterations on seeds 0 to 14. The held-out per-shape results are within about 1 point of the tuning
seeds for A, B and C, and within the tuning seeds' range for D. That shows the thresholds were not
fitted to noise in particular seeds. It does not show they are right, because every seed comes
from the same simulator.

## Sensitivity (held-out seeds, frozen thresholds, never tuned on)

Same held-out seeds and frozen thresholds; only one registered assumption changed per row. Command:
`bun run scripts/otp-fraud-replay.ts run --seeds 15-19 --shapes A,B,C,D
--configs today,rules --workers 8 --volume <n> | --telegram <p> --out
../docs/results/otp-fraud/sensitivity-<condition>.jsonl`, run 2026-09-30 22:39 to 22:55 UTC at
`d8cfac0` (source, replay code and thresholds identical to `2abaf59`; that commit only merged main). Cells: attack sends stopped % / real
sign-ups refused by the rules %, mean over 5 seeds.

| Condition | A | B | C | D |
|---|---|---|---|---|
| Main (2,000 a day, Telegram 0.5) | 98.0 / 0.04 | 84.0 / 4.37 | 71.5 / 0.04 | 17.2 / 2.54 |
| 500 sign-ups a day | 98.0 / 0.00 | 92.4 / 4.61 | 71.5 / 0.00 | 73.9 / 10.76 |
| 5,000 sign-ups a day | 98.0 / 0.64 | **0.0** / 0.64 | 71.5 / 0.64 | **0.5** / 0.70 |
| Telegram held by 20% | 98.0 / 0.02 | 79.9 / 6.70 | 71.5 / 0.02 | 14.2 / 3.02 |
| Telegram held by 80% | 98.0 / 0.01 | 83.9 / 1.72 | 71.5 / 0.01 | 19.4 / 1.15 |

**The thresholds do not transfer across volume.** They are absolute counts and a fixed ratio, tuned
at 2,000 sign-ups a day:

- At 5,000 a day, legitimate traffic dilutes the pumped range: its verify rate stays above the 0.5
  floor, and the rules stop none of shape B and almost none of D. The same volume also refuses
  0.64% of real sign-ups with no attack involved: the surge rule fired 967 times in the first
  simulated hours, before any prefix had a baseline, and legitimate `+7` numbers passed the
  3-per-hour foreign limit 46 times.
- At 500 a day the opposite happens: the rules catch 73.9% of D, and refuse 10.76% of real users to
  do it.
- Fewer Telegram users make every `require_channel` decision more expensive: at 20%, shape B costs
  6.70% of real sign-ups instead of 4.37%.

A deployment would need thresholds that scale with each prefix's own traffic (the surge rule already
does, apart from its floor), or rules re-tuned whenever volume changes by a large factor. That is the
most important thing this replay found.


## Negative controls

Each claim about the rules is pinned by a test in `server/src/otp-risk.test.ts`, and each test is
shown to fail with the behaviour removed: `cd server && bun run scripts/negative-controls.ts N13 N14
N15 N16 N17 N18`, all six caught at `05d93c7`. For the replay, the `today` rows are the counterfactual:
the same traffic with the rules off stops 0% of every shape.

## What this does not show

- **Circularity.** The attacks were designed by the defender. The registration and the held-out
  seeds stop the thresholds from being fitted to particular seeds, not to the shapes themselves. A
  real attacker adapts; none of these attackers react to being refused.
- **Traffic model.** Operator shares come from public estimates; the prefix-to-operator mapping,
  carrier NAT pool sizes, delivery rates, retry behaviour and the 50% Telegram assumption are
  guesses. Telegram's share in Tajikistan is estimated at 14% as a primary messenger, so 50% holding
  an account may be generous; see the 0.2 sensitivity row.
- **Refused requests leave no row.** The rules read `otp_challenges`, and a refused request is never
  written, so a marked range recovers as its unverified sends age out of the window and the attack
  resumes. That oscillation is part of why B and C are not higher.
- **Cold start.** With no history the surge rule allows only its floor per prefix per hour; the
  refusals it caused here were all in the first simulated hours.
- **No shadow period, no real carrier data, no WhatsApp channel.** A deployment should run
  `TOJ_OTP_RISK_MODE=shadow` first and choose its own thresholds (`TOJ_OTP_RISK_RULES`); the
  published ones are the evaluation set.
