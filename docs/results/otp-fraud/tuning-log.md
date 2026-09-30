# OTP fraud rules: tuning log

Tuning seeds 0 to 14 only; held-out seeds 15 to 19 are not run until the thresholds are frozen.
Objective (pre-registration amendment 2): mean over shapes A to D of (attack sends blocked %) minus
10 x (real sign-ups refused by rules %). Every run:
`cd server && bun run scripts/otp-fraud-replay.ts run --seeds 0-14 --shapes A,B,C,D --configs <configs> [--rules <file>] --workers 8 --out <file>`,
scored with `bun run scripts/otp-fraud-replay.ts score --in <file>`. Iteration 0 ran before the
freeze, when the default was the registered table; reproduce it now with `--rules registered`. Each
results row records its exact thresholds in `rulesDigest`. Machine: Apple M5 Pro, 24 GB,
macOS 27.0.1, Bun 1.3.11, PostgreSQL 17.10.

| Iteration | Code | Started (UTC) | Thresholds changed | Blocked % | Refused % | Score | Results |
|---|---|---|---|---|---|---|---|
| 0 | `a8e3bb2213b3d54355f41fa9d7f27cfc593b08a1` | 2026-09-30T20:17:18Z | none (registered table) | 45.54 | 1.445 | 31.08 | `iteration-0-tuning.jsonl` (all three configurations) |
| 1 | `615fd6043c3cbf138a865dceeb6724cd2257b98c` | 2026-09-30T20:29:16Z | foreignPrefixPerHour 20 to 5, verifyRateMinSends 50 to 15 | 63.24 | 2.227 | 40.97 | `iteration-1-tuning.jsonl`, `rules-iteration-1.json` |
| 2 | `0519b70b937d78cff3ead3a2a5687a76fe3564db` | 2026-09-30T20:35:43Z | verifyRateFloor 0.6 to 0.5 | 58.18 | 1.676 | 41.42 | `iteration-2-tuning.jsonl`, `rules-iteration-2.json` |
| 3 | `9656ec940fd098a54ff78a8851d8b7e354083eb2` | 2026-09-30T20:41:24Z | foreignPrefixPerHour 5 to 3 | 58.95 | 1.680 | 42.14 | `iteration-3-tuning.jsonl`, `rules-iteration-3.json` |
| 4 | `ecac89d9eb1b4c5e73df8acdd2bd04aa834e6fe1` | 2026-09-30T20:47:38Z | verifyRateMinSends 15 to 10 | 64.88 | 1.773 | 47.15 | `iteration-4-tuning.jsonl`, `rules-iteration-4.json` |
| 5 | `473b11f` | 2026-09-30T20:53Z (commit time; the run started right after it) | verifyRateWindowMinutes 360 to 720 | 67.59 | 1.768 | 49.91 | `iteration-5-tuning.jsonl`, `rules-iteration-5.json` |

Iteration 5 scores best and is frozen (`rules-frozen.json`, identical to `rules-iteration-5.json`),
as amendment 2 requires. Five tuning iterations were used, the registered maximum.

Per-shape tuning-seed results for the frozen iteration (`report --in iteration-5-tuning.jsonl`):
A 98.0% of attack sends blocked, B 83.6%, C 71.2%, D 17.7%; real sign-ups refused by rules
0.03%, 4.42%, 0.03% and 2.60%.
