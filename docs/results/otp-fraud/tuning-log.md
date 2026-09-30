# OTP fraud rules: tuning log

Tuning seeds 0 to 14 only; held-out seeds 15 to 19 are not run until the thresholds are frozen.
Objective (pre-registration amendment 2): mean over shapes A to D of (attack sends blocked %) minus
10 x (real sign-ups refused by rules %). Every run:
`cd server && bun run scripts/otp-fraud-replay.ts run --seeds 0-14 --shapes A,B,C,D --configs <configs> [--rules <file>] --workers 8 --out <file>`,
scored with `bun run scripts/otp-fraud-replay.ts score --in <file>`. Machine: Apple M5 Pro, 24 GB,
macOS 27.0.1, Bun 1.3.11, PostgreSQL 17.10.

| Iteration | Code | Started (UTC) | Thresholds changed | Blocked % | Refused % | Score | Results |
|---|---|---|---|---|---|---|---|
| 0 | `a8e3bb2213b3d54355f41fa9d7f27cfc593b08a1` | 2026-09-30T20:17:18Z | none (registered table) | 45.54 | 1.445 | 31.08 | `iteration-0-tuning.jsonl` (all three configurations) |
| 1 | `615fd6043c3cbf138a865dceeb6724cd2257b98c` | 2026-09-30T20:29:16Z | foreignPrefixPerHour 20 to 5, verifyRateMinSends 50 to 15 | 63.24 | 2.227 | 40.97 | `iteration-1-tuning.jsonl`, `rules-iteration-1.json` |
| 2 | `0519b70b937d78cff3ead3a2a5687a76fe3564db` | 2026-09-30T20:35:43Z | verifyRateFloor 0.6 to 0.5 | 58.18 | 1.676 | 41.42 | `iteration-2-tuning.jsonl`, `rules-iteration-2.json` |
