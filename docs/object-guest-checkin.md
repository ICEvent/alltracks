# Object Tracking — existing AllTracks ICP backend

This repository holds the restored Motoko source. These changes belong in the **existing** `backend` canister (published frontend ID: `r6cnt-kyaaa-aaaal-aab3a-cai`) — no separate canister is created.

## Canonical integrations
- Frontend draft PR: https://github.com/bytesun/alltracks/pull/38
- Backend draft PR: https://github.com/ICEvent/alltracks/pull/1
- The existing public `Track`/`CheckPoint` Candid types and stable fields remain unchanged.
- Object metadata is a public `Track` with `obj-<UUID>`, `trackType=#other`, `isPublic=true` and description prefix `alltracks:object:v1:`.
- Object guest check-in records reuse the public `CheckPoint` type, `trackId=objectId`, `createdBy=the gateway Principal`, `isPublic=true`, note prefix `alltracks:object-checkin:v1:`. Location is rounded to 3 decimals before storage; time is assigned by `Time.now()`.

## New Candid methods
```candid
type GuestAction = variant { found; carried; left };
type GuestCheckinInput = record {
  objectId : text;
  latitude : float64;
  longitude : float64;
  accuracyMeters : nat;
  action : GuestAction;
  note : text;
  requestId : text;
};
type GuestError = variant {
  unauthorized; notFound; disabled; invalid; duplicate; rateLimited
};
getObjectGuestPolicy : (text) -> (opt record {enabled:bool;gateway:principal}) query;
setObjectGuestPolicy : (text, bool, principal) -> (variant {ok:bool;err:text});
submitGuestCheckin : (GuestCheckinInput) -> (variant {ok:nat;err:GuestError});
```

## Security model

Only the **owner of a genuine public Object Track** may enable or disable Guest Check-in and select the dedicated gateway Principal. The owner must sign in. No global admin bootstrap is required; each object has its own explicit allowlist entry. The default is disabled.

`submitGuestCheckin` only accepts the currently owner-approved Principal for that object, rejects other Principals including anonymous, enforces object existence, location bounds, accuracy ≤2 km, note ≤280 scalar characters and ≤1200 UTF-8 bytes, UUID-shaped request IDs (length 36, frontend additionally validates UUID syntax), per-object 30-second gap, 30 accepted daily writes and deduplication against the recent (up to 3000) seven-day request receipt window. This endpoint has **no awaits** and writes data and quotas together.

A caller can still forge GPS values. Cloudflare Turnstile and edge WAF on the frontend's Vercel gateway provide extra filtering but do not prove physical possession. The gateway identity MUST be a separate dedicated, unprivileged identity. **Important:** the existing AllTracks public authenticated APIs generally authorize any signed-in Principal; compromising this gateway identity would grant the attacker the same generic rights as a normal signed-in user, not only the guest method. Before wide release, review those legacy interfaces and avoid using any privileged key. Enforce gateway isolation, monitor spending and provide rapid revocation.

## Local tests

Run the workflow `.github/workflows/backend-ci.yml` or:

```bash
dfx start --background --clean
dfx canister create backend
dfx build backend
bash scripts/test-object-guest.sh
```

The test creates a local object and relay identity, verifies owner-only policy changes, unauthorized anonymous and unrelated calls, accepted relay check-in, correct JSON/public output, repeat request, invalid coordinates, owner disabling, and persistence after a local canister upgrade.

## Mainnet release gate

**Do not upgrade mainnet solely because CI passed.** The source was just restored from a local snapshot. Before deploying, verify the current production canister ID and code hash, verify stable type compatibility against the *actual deployed* module, reconcile any differences from the restored snapshot, create a recovery and backups plan, review controller identities/cycles, and test with a realistic copy of existing data on a local replica or test environment. Deploy the frontend Candid binding and the owner toggle in the coordinated release. Keep guest feature flags off until the Turnstile server secret, WAF rate limits, relay identity and owner opt-in are in place. Confirm a real two-phone anonymous report on a non-sensitive approved physical item and monitor errors.
