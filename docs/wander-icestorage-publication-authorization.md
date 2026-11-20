# Wander photo publication: ICEStorage authorization gap

## Verified against ICEStorage `main` (2026-11-20)

`Container.mo::createResource` requires the **calling principal** to
have an uploader entry and nonzero byte quota, then checks
`ObjectRegistry.allObjectRefsMatch(..., resource.key.storage.owner, ...)`
and `ResourceRegistry.create(..., caller)`.

`ResourceRegistry.owns(caller,key)` only accepts
`#principal(owner)` when `owner == caller`; `#group` fails closed.
`ResourceRegistry.create` rejects a non-owner. Its `canWrite` grants
apply to existing resources and do **not** authorize initial creation.

Thus the registered Alltracks backend cannot create a resource whose
`StorageKey.owner` is the **browser user**. Creating a backend-owned
resource instead does not work for a user-owned uploaded ObjectRef.
The project uploader quota does not grant delegation for `createResource`.

## Required decision before implementing publish

Preferred: extend ICEStorage with a narrow **project-authorized resource
publication transaction** that binds a completed project-upload session
to the registered project backend, verifies the browser uploader Principal
and matching ObjectRef, checks project status/quota, and creates/updates
the resource atomically on the ICEStorage side. It must enforce:
- project-backend caller matches the original upload grant's backend;
- ObjectRef owner and metadata match the completed session;
- stable idempotency key, immutable resource owner and resource ID;
- no arbitrary user objects, no arbitrary manifests or security grants;
- public visibility only after explicit approved publication;
- revision-safe retry and read-back reconciliation;
- deletion/refcount/cleanup permissions consistent with project uploads.

Alternative: allow the **browser user** to publish with their own identity
after provisioning a direct uploader/quota. This changes the onboarding
and abuse-control model, so it must be an explicit product decision.

Do not wire `createResource` from Alltracks Backend until this
authorization gap is closed and integration-tested. The existing
`prepareOwnedWanderPhotoPublication` is only a non-public intent.
