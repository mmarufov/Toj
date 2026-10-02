# Toj documentation

Start with the [README](../README.md) for what Toj is and how to build it.

> This directory is also the publishing source for the
> [tojchat.tech](https://tojchat.tech) site (`index.html`, `assets/`, `CNAME`). Edit the source under
> `scripts/website/` and rebuild. See the [website guide](../scripts/website/README.md).
> Leave these files alone unless you mean to change the site.

## Design and architecture

| Document | What it covers |
| --- | --- |
| [Architecture](architecture.md) | How the system fits together and why: data model, offline-first client, transport, encryption at rest, verification |
| [Design system](design-system.md) | Color, typography, spacing, shape, motion, and the Liquid Glass rules |
| [Privacy data map](privacy-data-map.md) | Collected data categories, checked against the app's privacy manifest by `scripts/verify-privacy-manifest.py` in CI. Edit both together or the build fails |

## Running and operating

| Document | What it covers |
| --- | --- |
| [iOS staging](ios-staging.md) | Running the app against the staging backend, and the device/data boundary |
| [Backend staging](../server/STAGING.md) | Render + Supabase deployment runbook |
| [Backend operations](../server/OPERATIONS.md) | Retention, security conventions, rollout and rollback flags |
| [TURN relay](../infra/coturn/README.md) | coturn deployment template and capacity gates |

## Release records

Evidence for features that are written but not enabled. Each one separates
automated repository evidence from gates that need provisioned infrastructure
and physical devices. The unchecked boxes are why the feature flags are refused
at startup.

| Document | What it covers |
| --- | --- |
| [Voice calls v1](releases/voice-calls-v1.md) | Release plan and scope |
| [Voice calls v1 follow-up](releases/voice-calls-v1-follow-up.md) | Deferred work and pre-beta rollout gates |
| [Video calls v1](releases/video-calls-v1.md) | Release report, automated evidence, open external gates |

## Measured results

Each result lists the exact command, commit, date and machine that produced it. All of them are
local measurements.

| Document | What it covers |
| --- | --- |
| [Session, receipt, client-address and fan-out hardening](results/step1-hardening.md) | Render client-address verification, statements per group send, overlapping-send deadlock test, negative controls |
| [Sync under injected network faults](results/sync-chaos.md) | Toxiproxy sweep of the sync protocol: messages lost, duplicated and mismatched, and convergence time ([pre-registration](results/sync-chaos-preregistration.md)) |
| [OTP fraud rules on replayed SMS pumping](results/otp-fraud-replay.md) | Simulated SMS-pumping attacks against the sign-in fraud rules, reported on held-out seeds ([pre-registration](results/otp-fraud-preregistration.md)) |

## Implementation plans

Historical design documents for features that have since shipped. They record
why a design is the way it is. They are not maintained; where they disagree
with the code, the code is right.

| Document | Feature |
| --- | --- |
| [Groups v1](plans/groups-v1.md) | Group messaging |
| [Saved Messages](plans/saved-messages.md) | Saved Messages and the self-dialog |
| [Group calls and screen share](plans/group-calls-screen-share.md) | SFU group calling, ReplayKit broadcast |

## Contributing and security

- [Contributing guide](../.github/CONTRIBUTING.md): conventions this codebase is held to
- [Security policy](../.github/SECURITY.md): how to report a vulnerability privately
- [Changelog](../CHANGELOG.md)
