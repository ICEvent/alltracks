#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Guest ACL test failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

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

# Guests are read-only even when a legacy gateway policy is enabled.
dfx canister call backend getObjectGuestPolicy "(\"$object_id\")" --query | grep -q 'null'
dfx canister call backend setObjectGuestPolicy \
  "(\"$object_id\", true, principal \"$relay\")" | grep -q 'ok'
payload='(record { objectId = "obj-11111111-1111-4111-8111-111111111111"; latitude = 49.177777; longitude = -122.633333; accuracyMeters = 20; action = variant { found }; note = "No guest writes"; requestId = "22222222-2222-4222-8222-222222222222" })'
for identity in anonymous guest-relay unrelated; do
  response="$(dfx --identity "$identity" canister call backend submitGuestCheckin "$payload")"
  echo "$response" | grep -q 'disabled'
done
# An authenticated participant can still create their own Checkpoint.
dfx --identity unrelated canister call backend createCheckpoint \
  '(record { trackId = "obj-11111111-1111-4111-8111-111111111111"; latitude = 49.1; longitude = -122.6; elevation = 0.0; note = "alltracks:object-checkin:v1:{\"action\":\"found\",\"note\":\"Participant\"}"; groupId = null; photo = null; timestamp = 1760000000000000010; isPublic = true })' | grep -q 'ok'
dfx canister call backend getCheckPointsByTrackId "(\"$object_id\")" --query | grep -q 'Participant'
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

# Legacy policy remains readable but never grants write authority.
dfx canister call backend getObjectGuestPolicy "(\"$object_id\")" --query | grep -q 'true'
dfx canister install backend --mode upgrade --wasm-memory-persistence keep
dfx canister call backend getCheckPointsByTrackId "(\"$object_id\")" --query | grep -q 'Participant'
dfx --identity guest-relay canister call backend submitGuestCheckin "$payload" | grep -q 'disabled'
echo 'Read-only guest ACL integration tests passed.'
