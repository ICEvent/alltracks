# Wander × ICEStorage photo lifecycle: local verification gate

This feature branch is **not production-ready**. No mainnet deployment or merge until the following tests pass on a local replica using the real Alltracks and ICEStorage canisters.

## Compile and interface
- Run `dfx build --check` in both projects and generate Candid declarations.
- Verify the cross-canister signatures for `issueProjectUploadGrant`, `getProjectUploadedObjectInfo`, `publishProjectPhoto`, `revokeProjectPhoto`, and `deleteProjectPhoto`.
- Upgrade Alltracks from its currently deployed stable-state layout and verify old objects/checkpoints still load. Do not assume a clean install represents an upgrade.

## Owner upload and publication
- Owner grant succeeds; anonymous and non-owner grants fail.
- Valid JPEG/PNG/WebP <=10 MiB uploads; invalid type/size and mismatched owner fail.
- Completed upload can be prepared and published once; repeated publish returns the same result.
- Simulate a lost publish acknowledgement and an upgrade while state is `#publishing`; retry must reconcile.
- Simulate object deletion/ownership change during cross-canister await; never expose a stale binding.
- Verify public reader accepts only the trusted ResourceKey and cannot read pending/revoked/deleted photos.

## Checkpoint association
- Bind only an existing, unique, eligible Checkpoint to an owner-published photo.
- Duplicate binding is idempotent; rebinding the same storage object to another Checkpoint fails.
- Deleting the Checkpoint removes its public photo reference and tombstones the linked intent before returning.
- A guest deleting their own Checkpoint cannot initiate arbitrary photo deletion.

## Recovery and quota
- `retryWanderPhotoCleanup` rejects anonymous callers and live/non-tombstoned photos.
- Verify global 5-second throttle under concurrent calls and across an upgrade.
- Simulate lost revoke and delete acknowledgements; retry until logical `#deleted`.
- Verify actual ICEStorage object reclamation and byte quota recovery separately; logical deletion is not proof of physical reclamation.
- Verify multiple concurrent cleanup requests do not resurrect public access.
- Exercise the pending-cleanup inventory limit and the stable intent capacity limit.

## Outstanding implementation
- No automatic background cleanup scheduler yet; recovery needs an authenticated caller.
- No automatic client integration for the Checkpoint photo workflow yet.
- Guest-upload authorization is deliberately not supported.
- Add real E2E scripts and CI before removing draft status.
