## What this changes

<!-- One paragraph, written for someone who was not in the conversation that produced it. -->

## Why

<!-- The problem. Link the issue if there is one. -->

## How it was verified

<!-- Which tests, on what. "CI is green" alone is not verification of behaviour. -->

- [ ] Backend suite passes (`cd server && bun test`)
- [ ] iOS suite passes
- [ ] Tested on a simulator or device, not only in unit tests

## Risk

<!-- What breaks if this is wrong, and how it rolls back. Delete lines that do not apply. -->

- [ ] Touches cryptography, key handling, or anything at rest
- [ ] Touches auth, sessions, or rate limiting
- [ ] Adds or changes a database migration
- [ ] Changes behaviour on a slow or dropping connection
- [ ] Changes a TTL, expiry, or cleanup query — **row absence is load-bearing**;
      tests pin both directions and the post-expiry outcome is benign

## Checklist

- [ ] No plaintext, keys, or full phone numbers are logged
- [ ] New test files registered (`scripts/add_test_files.rb`)
- [ ] Any new GitHub Action is pinned to a full commit SHA
- [ ] Nothing in this diff is something I would later want to force-push away
