#!/usr/bin/env bash
set -euo pipefail

# Local-only integration exercise for the EXISTING backend, never mainnet.
object_id="obj-11111111-1111-4111-8111-111111111111"
dfx canister install backend
dfx identity new guest-relay --storage-mode plaintext
dfx identity new unrelated --storage-mode plaintext
relay="$(dfx --identity guest-relay identity get-principal)"

track="$(dfx canister call backend createTrack \
  '(record {
    id = "obj-11111111-1111-4111-8111-111111111111";
    name = "Wandering Cup";
    description = "alltracks:object:v1:{\"description\":\"Test cup\",\"emoji\":\"cup\"}";
    length = 0.0; elevation = 0.0; duration = 0.0;
    startime = 1760000000000000000; isPublic = true;
    groupId = null;
    trackfile = record { fileType = "application/x.alltracks.object+json"; url = "" };
    startPoint = record { latitude = 0.0; longitude = 0.0 };
    trackType = variant { other }
  })')"
echo "$track" | grep -q 'ok'

# Duplicate public object IDs must not allow QR shadowing.
dfx canister call backend createTrack \
  '(record { id = "obj-11111111-1111-4111-8111-111111111111"; name = "Hijack";
    description = "alltracks:object:v1:{}"; length = 0.0; elevation = 0.0;
    duration = 0.0; startime = 1760000000000000000; isPublic = true;
    groupId = null; trackfile = record {fileType = "object"; url = ""};
    startPoint = record {latitude = 0.0; longitude = 0.0}; trackType = variant {other}
  })' | grep -q 'Object ID already exists'

dfx canister call backend getObjectGuestPolicy "(\"$object_id\")" --query | grep -q 'null'

not_owner="$(dfx --identity unrelated canister call backend setObjectGuestPolicy \
  "(\"$object_id\", true, principal \"$relay\")")"
echo "$not_owner" | grep -q 'err'

owner="$(dfx canister call backend setObjectGuestPolicy \
  "(\"$object_id\", true, principal \"$relay\")")"
echo "$owner" | grep -q 'ok'

payload='(record {
  objectId = "obj-11111111-1111-4111-8111-111111111111";
  latitude = 49.177777; longitude = -122.633333; accuracyMeters = 20;
  action = variant { found };
  note = "First stop";
  requestId = "22222222-2222-4222-8222-222222222222"
})'
anon="$(dfx --identity anonymous canister call backend submitGuestCheckin "$payload")"
echo "$anon" | grep -q 'unauthorized'

impostor="$(dfx --identity unrelated canister call backend submitGuestCheckin "$payload")"
echo "$impostor" | grep -q 'unauthorized'

ok="$(dfx --identity guest-relay canister call backend submitGuestCheckin "$payload")"
echo "$ok" | grep -q 'ok'

readback="$(dfx canister call backend getCheckPointsByTrackId "(\"$object_id\")" --query)"
echo "$readback" | grep -q 'First stop'
echo "$readback" | grep -q '49.178'
echo "$readback" | grep -q 'createdBy'

repeat="$(dfx --identity guest-relay canister call backend submitGuestCheckin "$payload")"
echo "$repeat" | grep -q 'duplicate'

# A fresh request for the same object within 30 seconds hits the quota gap.
gap_payload="$(printf '%s' "$payload" | sed 's/22222222-2222-4222-8222-222222222222/44444444-4444-4444-8444-444444444444/')"
gap="$(dfx --identity guest-relay canister call backend submitGuestCheckin "$gap_payload")"
echo "$gap" | grep -q 'rateLimited'

# Ordinary anonymous Checkpoint writes must remain rejected.
anon_cp="$(dfx --identity anonymous canister call backend createCheckpoint   '(record {
    trackId = "obj-11111111-1111-4111-8111-111111111111";
    latitude = 49.1; longitude = -122.6; elevation = 0.0; note = "forged";
    groupId = null; photo = null; timestamp = 1760000000000000000; isPublic = true
  })')"
echo "$anon_cp" | grep -q 'Anonymous users are not allowed'

invalid="$(dfx --identity guest-relay canister call backend submitGuestCheckin \
  '(record {
    objectId = "obj-11111111-1111-4111-8111-111111111111";
    latitude = 999.0; longitude = -122.63; accuracyMeters = 20;
    action = variant { found };
    note = "Forged location";
    requestId = "33333333-3333-4333-8333-333333333333"
  })')"
echo "$invalid" | grep -q 'invalid'

disabled="$(dfx canister call backend setObjectGuestPolicy \
  "(\"$object_id\", false, principal \"$relay\")")"
echo "$disabled" | grep -q 'ok'
blocked="$(dfx --identity guest-relay canister call backend submitGuestCheckin "$payload")"
echo "$blocked" | grep -q 'disabled'

dfx canister install backend --mode upgrade --wasm-memory-persistence keep
dfx canister call backend getCheckPointsByTrackId "(\"$object_id\")" --query | grep -q 'First stop'
dfx canister call backend getObjectGuestPolicy "(\"$object_id\")" --query | grep -q 'false'
echo 'Guest check-in backend integration tests passed.'
