#!/usr/bin/env bash
# Local-only opt-in stress test. Creates synthetic Wander objects to approximate
# a larger persistent state; does not copy or touch production data.
set -euo pipefail
cd "$(dirname "$0")/.."
NETWORK="${NETWORK:-local}"
if [[ "$NETWORK" != "local" ]]; then
  echo "Refusing non-local network: $NETWORK" >&2
  exit 1
fi
COUNT="${COUNT:-400}"
DESCRIPTION_BYTES="${DESCRIPTION_BYTES:-180000}"
PREFIX="${PREFIX:-obj-photo-memory-stress}"
if ! [[ "$COUNT" =~ ^[0-9]+$ && "$DESCRIPTION_BYTES" =~ ^[0-9]+$ ]]; then
  echo "COUNT and DESCRIPTION_BYTES must be positive integers" >&2
  exit 1
fi
if (( COUNT < 1 || COUNT > 1000 || DESCRIPTION_BYTES < 1 || DESCRIPTION_BYTES > 250000 )); then
  echo "Limits: COUNT=1..1000 DESCRIPTION_BYTES=1..250000" >&2
  exit 1
fi
echo "Target: network=local; count=$COUNT; description bytes=$DESCRIPTION_BYTES"
echo "This writes synthetic objects to the existing LOCAL backend and is not automatically reversible."
echo "Use a disposable local canister only. To continue set CONFIRM_LOCAL_STRESS=YES."
if [[ "${CONFIRM_LOCAL_STRESS:-}" != "YES" ]]; then exit 1; fi
dfx canister id backend --network local
dfx canister status backend --network local
# Generate one reusable Candid argument file, then vary only the object ID.
# Plain ASCII payload avoids Candid escaping overhead.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 - "$DESCRIPTION_BYTES" "$tmp/description" <<'PY'
import sys
n = int(sys.argv[1])
prefix = "alltracks:object:v1:"
with open(sys.argv[2], "w") as f:
    f.write(prefix + "x" * max(0, n-len(prefix)))
PY
desc="$(cat "$tmp/description")"
for ((i=1; i<=COUNT; i++)); do
  id="${PREFIX}-$(printf '%05d' "$i")"
  printf '(record { id = "%s"; name = "Memory stress"; description = "%s"; length = 0.0; elevation = 0.0; duration = 0.0; startime = 0; isPublic = true; groupId = null; trackfile = record { fileType = ""; url = "" }; startPoint = record { latitude = 0.0; longitude = 0.0 }; trackType = variant { other } })' "$id" "$desc" > "$tmp/args"
  result="$(dfx canister call backend createTrack --argument-file "$tmp/args" --network local)"
  if [[ "$result" != *"ok = record"* ]]; then
    echo "Create failed at $id: $result" >&2
    exit 1
  fi
  if (( i % 25 == 0 || i == COUNT )); then
    echo "Created $i/$COUNT objects"
    dfx canister status backend --network local | grep -E 'Memory Size:|Balance:'
  fi
done
echo "Stress records created. Run the probes on $PREFIX-00001 with the SAME dfx identity."
