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

# Object comments: default on, owner-only pause, and canister-side redaction.
dfx canister call backend getObjectCommentsEnabled "(\"$object_id\")" --query | grep -q 'true'
not_owner_comments="$(dfx --identity unrelated canister call backend setObjectCommentsEnabled "(\"$object_id\", false)")"
echo "$not_owner_comments" | grep -q 'Only owner'
dfx canister call backend setObjectCommentsEnabled "(\"$object_id\", false)" | grep -q 'ok'
dfx canister call backend getObjectCommentsEnabled "(\"$object_id\")" --query | grep -q 'false'

# Closing comments does not close location-only signed-in check-ins.
closed_cp="$(dfx --identity unrelated canister call backend createCheckpoint \
  '(record {
    trackId = "obj-11111111-1111-4111-8111-111111111111";
    latitude = 49.5; longitude = -122.5; elevation = 0.0;
    note = "alltracks:object-checkin:v1:{\"action\":\"found\",\"note\":\"private note should be stripped\"}";
    groupId = null; photo = opt "https://example.com/photo.jpg";
    timestamp = 1760000000000000010; isPublic = true
  })')"
echo "$closed_cp" | grep -q 'ok'
stops="$(dfx canister call backend getCheckPointsByTrackId "(\"$object_id\")" --query)"
echo "$stops" | grep -q '49.5'
! echo "$stops" | grep -q 'private note should be stripped'
! echo "$stops" | grep -q 'example.com/photo.jpg'

# Reopening comments enables new notes, which the owner can moderate.
dfx canister call backend setObjectCommentsEnabled "(\"$object_id\", true)" | grep -q 'ok'
dfx --identity unrelated canister call backend createCheckpoint \
  '(record {
    trackId = "obj-11111111-1111-4111-8111-111111111111";
    latitude = 49.6; longitude = -122.6; elevation = 0.0;
    note = "alltracks:object-checkin:v1:{\"action\":\"left\",\"note\":\"Delete my comment\"}";
    groupId = null; photo = null;
    timestamp = 1760000000000000011; isPublic = true
  })' | grep -q 'ok'
unrelated_principal="$(dfx --identity unrelated identity get-principal)"
unauthorized_delete="$(dfx --identity guest-relay canister call backend deleteObjectComment \
  "(\"$object_id\", 1760000000000000011, principal \"$unrelated_principal\")")"
echo "$unauthorized_delete" | grep -q 'Not authorized'
dfx canister call backend deleteObjectComment \
  "(\"$object_id\", 1760000000000000011, principal \"$unrelated_principal\")" | grep -q 'ok'
stops="$(dfx canister call backend getCheckPointsByTrackId "(\"$object_id\")" --query)"
echo "$stops" | grep -q '49.6'
! echo "$stops" | grep -q 'Delete my comment'

# Comment authors may also redact their own check-in; repeated delete fails.
dfx --identity unrelated canister call backend createCheckpoint \
  '(record {
    trackId = "obj-11111111-1111-4111-8111-111111111111";
    latitude = 49.7; longitude = -122.7; elevation = 0.0;
    note = "alltracks:object-checkin:v1:{\"action\":\"carried\",\"note\":\"My own note\"}";
    groupId = null; photo = null;
    timestamp = 1760000000000000012; isPublic = true
  })' | grep -q 'ok'
dfx --identity unrelated canister call backend deleteObjectComment \
  "(\"$object_id\", 1760000000000000012, principal \"$unrelated_principal\")" | grep -q 'ok'
dfx --identity unrelated canister call backend deleteObjectComment \
  "(\"$object_id\", 1760000000000000012, principal \"$unrelated_principal\")" | grep -q 'already removed'
dfx canister call backend setObjectCommentsEnabled "(\"$object_id\", false)" | grep -q 'ok'

dfx canister install backend --mode upgrade --wasm-memory-persistence keep
dfx canister call backend getCheckPointsByTrackId "(\"$object_id\")" --query | grep -q 'First stop'
dfx canister call backend getObjectGuestPolicy "(\"$object_id\")" --query | grep -q 'false'
dfx canister call backend getObjectCommentsEnabled "(\"$object_id\")" --query | grep -q 'false'
echo 'Guest check-in backend integration tests passed.'
