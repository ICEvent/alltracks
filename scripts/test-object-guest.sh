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
