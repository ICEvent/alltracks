import Types "types";
import Principal "mo:base/Principal";
import List "mo:base/List";
import Text "mo:base/Text";
import Buffer "mo:base/Buffer";

import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Result "mo:base/Result";
import Random "mo:base/Random";
import Float "mo:base/Float";
import Blob "mo:base/Blob";
import Char "mo:base/Char";
import Nat8 "mo:base/Nat8";

import HashMap "mo:base/HashMap";

persistent actor {
  private  var nextTrailId : Nat = 1;
  private  var nextSpotId : Nat = 1;
  private  var groupsEntries : [(Text, Types.Group)] = [];
  private  var userStatsEntries : [(Text, Types.UserStats)] = [];
  private  var trackathonEntries : [(Text, Types.Trackathon)] = [];
  private  var trackathonParticipantsEntries : [(Text, [(Principal, Types.TrackathonParticipant)])] = [];
  private  var tracks : List.List<Types.Track> = List.nil();
  private  var trails : List.List<Types.Trail> = List.nil();
  private  var photos : List.List<Types.Photo> = List.nil();
  private  var savedPoints : List.List<Types.SavedPoint> = List.nil();
  private  var spots : List.List<Types.Spot> = List.nil();
  private  var spotsV2 : List.List<Types.SpotV2> = List.nil();
  private  var checkpointComments : List.List<Types.CheckpointComment> = List.nil();

  private  var checkpoints : List.List<Types.CheckPoint> = List.nil();
  private  var incidentPoints : List.List<Types.IncidentPoint> = List.nil();
  private  var userCredentialsEntries : [(Principal, Types.UserCredential)] = [];
  // Additive stable fields: compatible with the existing Track/Checkpoint model.
  private var objectGuestPolicies : [(Text, Principal, Bool)] = [];
  // Additive stable field. A closed Object still accepts location-only check-ins.
  private var objectCommentsClosed : [Text] = [];
  private var guestRequestReceipts : [(Text, Text, Int)] = [];
  private var guestDailyUsage : [(Text, Int, Nat, Int)] = [];
  // Durable publication intents are NOT public photo bindings. They provide
  // idempotency and a recovery inventory before ICEStorage manifest writes.
  public type WanderPhotoPublicationIntent = {
    objectId : Text;
    storageObjectId : Text;
    requestedBy : Principal;
    requestedAt : Int;
    state : { #pending; #publishing; #published; #revoking; #deleted; #cancelled };
  };
  private var wanderPhotoPublicationIntents : [WanderPhotoPublicationIntent] = [];
  private let wanderPhotoIntentLimit : Nat = 5000;
  public type WanderCheckpointPhotoBinding = {
    objectId : Text;
    timestamp : Time.Time;
    author : Principal;
    storageObjectId : Text;
  };
  private var wanderCheckpointPhotoBindings : [WanderCheckpointPhotoBinding] = [];




  private transient var userCredentials = HashMap.HashMap<Principal, Types.UserCredential>(1, Principal.equal, Principal.hash);

  private transient var groups = HashMap.HashMap<Text, Types.Group>(1, Text.equal, Text.hash);
  private transient var userStats = HashMap.HashMap<Text, Types.UserStats>(1, Text.equal, Text.hash);
  private transient var trackathons = HashMap.HashMap<Text, Types.Trackathon>(1, Text.equal, Text.hash);
  private transient var trackathonParticipants = HashMap.HashMap<Text, HashMap.HashMap<Principal, Types.TrackathonParticipant>>(1, Text.equal, Text.hash);

  //=========================================================
  // migration stables
  //========================================================
  
  //==========================================================
  // system
  //==========================================================

  system func preupgrade() {
    groupsEntries := Iter.toArray(groups.entries());
    userStatsEntries := Iter.toArray(userStats.entries());
    userCredentialsEntries := Iter.toArray(userCredentials.entries());
    trackathonEntries := Iter.toArray(trackathons.entries());
    
    let participantsBuffer = Buffer.Buffer<(Text, [(Principal, Types.TrackathonParticipant)])>(0);
    for ((trackathonId, participants) in trackathonParticipants.entries()) {
      participantsBuffer.add((trackathonId, Iter.toArray(participants.entries())));
    };
    trackathonParticipantsEntries := Buffer.toArray(participantsBuffer);
  };

  system func postupgrade() {
    let groupsIter = Iter.fromArray<(Text, Types.Group)>(groupsEntries);
    let userStatsIter = Iter.fromArray<(Text, Types.UserStats)>(userStatsEntries);

    groups := HashMap.fromIter<Text, Types.Group>(groupsIter, 1, Text.equal, Text.hash);
    userStats := HashMap.fromIter<Text, Types.UserStats>(userStatsIter, 1, Text.equal, Text.hash);
    userCredentials := HashMap.fromIter<Principal, Types.UserCredential>(
      Iter.fromArray(userCredentialsEntries),
      1,
      Principal.equal,
      Principal.hash,
    );
    userCredentialsEntries := [];
    groupsEntries := [];
    userStatsEntries := [];

    // Restore trackathons
    trackathons := HashMap.fromIter<Text, Types.Trackathon>(
      Iter.fromArray(trackathonEntries),
      1,
      Text.equal,
      Text.hash
    );
    
    // Restore trackathon participants
    for ((trackathonId, participantsList) in trackathonParticipantsEntries.vals()) {
      let participantsMap = HashMap.fromIter<Principal, Types.TrackathonParticipant>(
        Iter.fromArray(participantsList),
        1,
        Principal.equal,
        Principal.hash
      );
      trackathonParticipants.put(trackathonId, participantsMap);
    };
    
    trackathonEntries := [];
    trackathonParticipantsEntries := [];

    // Migrate old `spots` (original shape) into `spotsV2` with numeric ids if needed
    if (List.size(spotsV2) == 0 and List.size(spots) > 0) {
      let arr = List.toArray(spots);
      var id : Nat = nextSpotId;
      for (s in arr.vals()) {
        let sp2 : Types.SpotV2 = {
          id = id;
          name = s.name;
          description = s.description;
          tags = s.tags;
          createdBy = s.createdBy;
          createdAt = s.createdAt;
        };
        spotsV2 := List.push(sp2, spotsV2);
        id += 1;
      };
      nextSpotId := id;
    };

  };


  // Object guest check-ins are owner-opted-in, gateway-only and bounded.
  // They reuse the existing CheckPoint store and DO NOT weaken createCheckpoint.
  public type GuestAction = { #found; #carried; #left };
  public type GuestCheckinInput = {
    objectId : Text;
    latitude : Float;
    longitude : Float;
    accuracyMeters : Nat;
    action : GuestAction;
    note : Text;
    requestId : Text;
  };
  public type GuestCheckinError = {
    #unauthorized;
    #notFound;
    #disabled;
    #invalid;
    #duplicate;
    #rateLimited;
  };
  private let guestDailyLimit : Nat = 30;
  private let guestMinimumGapNs : Int = 30_000_000_000;
  private let guestDayNs : Int = 86_400_000_000_000;
  private let guestMaxReceipts : Nat = 3000;
  private let guestMaxPolicies : Nat = 5000;
  private let objectMetadataPrefix = "alltracks:object:v1:";
  private let guestCheckpointPrefix = "alltracks:object-checkin:v1:";

  private func objectTrack(id : Text) : ?Types.Track {
    if (not Text.startsWith(id, #text "obj-")) return null;
    switch (List.find<Types.Track>(tracks, func(t) { t.id == id })) {
      case (?track) {
        if (track.isPublic and track.trackType == #other and
            Text.startsWith(track.description, #text objectMetadataPrefix)) {
          ?track
        } else { null }
      };
      case null { null };
    }
  };

  // Stage 1: only the Wander object owner can request a photo grant.
  // Public/guest check-in uploads need a separate abuse-resistant authorization path.
  // Persist grant throttle across upgrades. Reserve before the cross-canister
  // await so concurrent requests cannot bypass the per-user limit.
  private var wanderPhotoGrantAttempts : [(Principal, Int)] = [];
  private let wanderPhotoGrantCooldownNs : Int = 30_000_000_000;
  private let wanderPhotoGrantRetentionNs : Int = 86_400_000_000_000;
  private let wanderPhotoGrantMaxEntries : Nat = 5000;

  public type WanderStorageObjectInfo = {
    objectId : Text;
    owner : Principal;
    mimeType : Text;
    size : Nat;
    status : { #uploading; #complete; #aborted };
  };

  private let wanderStorage : actor {
    issueProjectUploadGrant : shared (Principal, Text, Text, Nat, ?Blob) -> async {
      #ok : Text;
      #err : Text;
    };
    publishProjectPhoto : shared (Text, Text) -> async {
      #ok : {
        key : {
          resourceId : Text;
          storage : { storageId : Text; owner : { #principal : Principal; #group : { id : Text; namespace : Text } } };
        };
        status : { #active; #draft; #revoked; #deleted };
        visibility : { #private_; #unlisted; #public_; #restricted };
        metadata : [(Text, Text)];
      };
      #err : {
        #alreadyExists; #conflict : { currentRevision : Nat64 };
        #forbidden; #internal : Text; #invalid : Text; #notFound;
      };
    };
    revokeProjectPhoto : shared (Text, Text) -> async {
      #ok : {
        key : {
          resourceId : Text;
          storage : { storageId : Text; owner : { #principal : Principal; #group : { id : Text; namespace : Text } } };
        };
        status : { #active; #draft; #revoked; #deleted };
        visibility : { #private_; #unlisted; #public_; #restricted };
        metadata : [(Text, Text)];
      };
      #err : {
        #alreadyExists; #conflict : { currentRevision : Nat64 };
        #forbidden; #internal : Text; #invalid : Text; #notFound;
      };
    };
    deleteProjectPhoto : shared (Text, Text) -> async {
      #ok : {
        key : {
          resourceId : Text;
          storage : { storageId : Text; owner : { #principal : Principal; #group : { id : Text; namespace : Text } } };
        };
        status : { #active; #draft; #revoked; #deleted };
        visibility : { #private_; #unlisted; #public_; #restricted };
        metadata : [(Text, Text)];
      };
      #err : {
        #alreadyExists; #conflict : { currentRevision : Nat64 };
        #forbidden; #internal : Text; #invalid : Text; #notFound;
      };
    };
    getProjectUploadedObjectInfo : shared query (Text, Text) -> async {
      #ok : WanderStorageObjectInfo;
      #err : {
        #alreadyExists;
        #conflict : { currentRevision : Nat64 };
        #forbidden;
        #internal : Text;
        #invalid : Text;
        #notFound;
      };
    };
  } = actor ("5pqgi-saaaa-aaaal-aaavq-cai");

  public shared ({ caller }) func requestWanderPhotoUploadGrant(
    objectId : Text,
    mimeType : Text,
    size : Nat,
  ) : async Result.Result<Text, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    switch (objectTrack(objectId)) {
      case null { return #err("Wander object not found") };
      case (?item) {
        if (item.createdBy != caller) return #err("Only the object owner can upload in this phase");
      };
    };
    if (size == 0 or size > 10_485_760) return #err("Invalid photo size");
    if (mimeType != "image/jpeg" and mimeType != "image/png" and
        mimeType != "image/webp") return #err("Unsupported photo type");

    let now = Time.now();
    // Drop old reservations and enforce a bounded stable table.
    let recent = Array.filter<(Principal, Int)>(
      wanderPhotoGrantAttempts,
      func(entry) { entry.1 <= now and now - entry.1 < wanderPhotoGrantRetentionNs },
    );
    for ((user, timestamp) in recent.vals()) {
      if (user == caller and now - timestamp < wanderPhotoGrantCooldownNs) {
        return #err("Please wait before requesting another photo upload");
      };
    };
    if (recent.size() >= wanderPhotoGrantMaxEntries) {
      return #err("Photo upload authorization is temporarily busy");
    };
    wanderPhotoGrantAttempts := Array.append<(Principal, Int)>(recent, [(caller, now)]);

    try {
      switch (await wanderStorage.issueProjectUploadGrant(
        caller, objectId, mimeType, size, null,
      )) {
        case (#ok(grantId)) { #ok(grantId) };
        case (#err(message)) { #err(message) };
      }
    } catch (_) {
      #err("Photo authorization service unavailable")
    }
  };

  // Read-only verification; this does NOT publish the photo or bind it to a
  // Checkpoint. ObjectInfo is authoritative for upload completion and owner.
  public shared ({ caller }) func verifyOwnedWanderPhotoUpload(
    objectId : Text,
    storageObjectId : Text,
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    switch (objectTrack(objectId)) {
      case null { return #err("Wander object not found") };
      case (?item) {
        if (item.createdBy != caller) return #err("Only the object owner may verify uploads");
      };
    };
    if (Text.size(storageObjectId) == 0 or Text.size(storageObjectId) > 256) {
      return #err("Invalid storage object ID");
    };
    try {
      switch (await wanderStorage.getProjectUploadedObjectInfo(storageObjectId, objectId)) {
        case (#err(_)) { #err("Storage object unavailable") };
        case (#ok(info)) {
          // The object may have been removed or changed while awaiting
          // ICEStorage. Never trust only the pre-await authorization check.
          switch (objectTrack(objectId)) {
            case null { return #err("Wander object no longer exists") };
            case (?current) {
              if (current.createdBy != caller) {
                return #err("Wander object ownership changed");
              };
            };
          };
          if (info.objectId != storageObjectId or info.owner != caller) {
            return #err("Storage object owner mismatch");
          };
          if (info.status != #complete) return #err("Photo upload is incomplete");
          if (info.size == 0 or info.size > 10_485_760) {
            return #err("Invalid stored photo size");
          };
          if (info.mimeType != "image/jpeg" and info.mimeType != "image/png" and
              info.mimeType != "image/webp") {
            return #err("Unsupported stored photo type");
          };
          #ok(true)
        };
      }
    } catch (_) { #err("Photo verification service unavailable") }
  };

  // This reserves a durable, non-public publication intent. It does NOT
  // assert that the upload is complete or that ICEStorage has published it.
  public shared ({ caller }) func prepareOwnedWanderPhotoPublication(
    objectId : Text,
    storageObjectId : Text,
  ) : async Result.Result<WanderPhotoPublicationIntent, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    switch (objectTrack(objectId)) {
      case null { return #err("Wander object not found") };
      case (?item) {
        if (item.createdBy != caller) return #err("Only the object owner may prepare publication");
      };
    };
    if (Text.size(storageObjectId) == 0 or Text.size(storageObjectId) > 256) {
      return #err("Invalid storage object ID");
    };
    // Confirm the upload before reserving an intent. A client-supplied
    // object ID is never proof that ICEStorage contains a completed photo.
    let verified = try {
      switch (await wanderStorage.getProjectUploadedObjectInfo(storageObjectId, objectId)) {
        case (#err(_)) { false };
        case (#ok(info)) {
          info.objectId == storageObjectId and info.owner == caller and
          info.status == #complete and info.size > 0 and
          info.size <= 10_485_760 and
          (info.mimeType == "image/jpeg" or info.mimeType == "image/png" or
           info.mimeType == "image/webp")
        };
      }
    } catch (_) { false };
    if (not verified) return #err("Completed owned photo not found in ICEStorage");
    // Recheck after await; owner or object state may have changed.
    switch (objectTrack(objectId)) {
      case null { return #err("Wander object no longer exists") };
      case (?current) {
        if (current.createdBy != caller) return #err("Wander object ownership changed");
      };
    };
    // One ICEStorage object may not be assigned to multiple Wander objects.
    for (intent in wanderPhotoPublicationIntents.vals()) {
      if (intent.storageObjectId == storageObjectId) {
        if (intent.objectId == objectId and intent.requestedBy == caller) {
          switch (intent.state) {
            case (#pending) return #ok(intent);
            case (#publishing) return #ok(intent);
            case (#published) return #ok(intent);
            case (_) return #err("Photo publication is cancelled or being deleted");
          };
        };
        return #err("Storage object already has a publication intent");
      };
    };
    // A single account must not exhaust the global durable intent table.
    var callerIntentCount : Nat = 0;
    for (intent in wanderPhotoPublicationIntents.vals()) {
      if (intent.requestedBy == caller and intent.state == #pending) {
        callerIntentCount += 1;
      };
    };
    if (callerIntentCount >= 20) {
      return #err("Too many pending photo publications");
    };
    if (wanderPhotoPublicationIntents.size() >= wanderPhotoIntentLimit) {
      return #err("Publication queue is full");
    };
    let intent : WanderPhotoPublicationIntent = {
      objectId;
      storageObjectId;
      requestedBy = caller;
      requestedAt = Time.now();
      state = #pending;
    };
    wanderPhotoPublicationIntents := Array.append(
      wanderPhotoPublicationIntents, [intent],
    );
    #ok(intent)
  };

  // Project-backend publication, never a browser-side createResource call.
  // Persist the stable intent before await; retries are idempotent at ICEStorage.
  public shared ({ caller }) func publishOwnedWanderPhoto(
    objectId : Text,
    storageObjectId : Text,
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    switch (objectTrack(objectId)) {
      case null return #err("Wander object not found");
      case (?item) {
        if (item.createdBy != caller) return #err("Only the object owner may publish");
      };
    };
    var found = false;
    for (intent in wanderPhotoPublicationIntents.vals()) {
      if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and intent.requestedBy == caller) {
        switch (intent.state) {
          case (#published) return #ok(true);
          // A prior call may have been interrupted by an upgrade or lost reply.
          // Re-enter the idempotent ICEStorage endpoint to reconcile safely.
          case (#publishing) { found := true };
          case (#cancelled) return #err("Photo publication was cancelled");
          case (#revoking) return #err("Photo is being removed");
          case (#deleted) return #err("Photo has been deleted");
          case (#pending) { found := true };
        };
      };
    };
    if (not found) return #err("Prepare publication first");
    wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and intent.requestedBy == caller) {
          { intent with state = #publishing }
        } else intent
      },
    );
    let published = try {
      switch (await wanderStorage.publishProjectPhoto(storageObjectId, objectId)) {
        case (#ok(resource)) {
          resource.status == #active and resource.visibility == #unlisted and
          resource.key.resourceId == storageObjectId and
          resource.key.storage.storageId == "project-wander-photo" and
          resource.key.storage.owner == #principal(caller) and
          Array.find<(Text, Text)>(resource.metadata, func(entry) {
            entry.0 == "wanderObjectId" and entry.1 == objectId
          }) != null
        };
        case (#err(_)) false;
      }
    } catch (_) { false };
    // Revalidate ownership after the cross-canister await.
    let stillOwned = switch (objectTrack(objectId)) {
      case null false;
      case (?item) item.createdBy == caller;
    };
    // A failed/ambiguous response returns to pending. ICEStorage's publication
    // endpoint is idempotent, so the next call safely reconciles lost replies.
    wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and intent.requestedBy == caller and intent.state == #publishing) {
          { intent with state = if (published and stillOwned) #published else #pending }
        } else intent
      },
    );
    // A concurrent delete may have tombstoned this intent while the
    // publication call was in flight. Never report a live photo in that case.
    let stillPublishing = Array.find<WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        intent.objectId == objectId and intent.storageObjectId == storageObjectId and
        intent.requestedBy == caller and intent.state == #published
      },
    ) != null;
    if (published and not stillPublishing) {
      // A Checkpoint can be removed while ICEStorage publication is in flight.
      // Revoke again after publication completes, otherwise the earlier
      // cleanup attempt may have raced ahead of the newly active Resource.
      let revoked = try {
        switch (await wanderStorage.revokeProjectPhoto(storageObjectId, objectId)) {
          case (#ok(resource)) resource.status == #revoked or resource.status == #deleted;
          case (#err(_)) false;
        }
      } catch (_) { false };
      if (revoked) {
        let deleted = try {
          switch (await wanderStorage.deleteProjectPhoto(storageObjectId, objectId)) {
            case (#ok(resource)) resource.status == #deleted;
            case (#err(_)) false;
          }
        } catch (_) { false };
        if (deleted) {
          wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
            wanderPhotoPublicationIntents,
            func(intent) {
              if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and
                  intent.state == #revoking) { { intent with state = #deleted } }
              else intent
            },
          );
        };
      };
      #err("Publication superseded; cleanup required")
    }
    else if (published and not stillOwned) #err("Wander object changed during publication; cleanup required")
    else if (published) #ok(true)
    else #err("Publication not confirmed; retry to reconcile")
  };

  // Remove a published project photo. ICEStorage revoke/delete endpoints are
  // idempotent; durable #revoking survives upgrades and lost acknowledgements.
  // Do not expose this photo while cleanup is pending.
  public shared ({ caller }) func deleteOwnedWanderPhoto(
    objectId : Text,
    storageObjectId : Text,
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    var found = false;
    for (intent in wanderPhotoPublicationIntents.vals()) {
      if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and intent.requestedBy == caller) {
        switch (intent.state) {
          case (#deleted) {
            // ICEStorage tombstones may precede physical byte reclamation.
            // Replaying delete is idempotent and retries its reclaim path.
            let tombstoneConfirmed = try {
              switch (await wanderStorage.deleteProjectPhoto(storageObjectId, objectId)) {
                case (#ok(resource)) resource.status == #deleted;
                case (#err(_)) false;
              }
            } catch (_) { false };
            if (tombstoneConfirmed) return #ok(true);
            return #err("Photo tombstone replay failed; physical reclamation is not confirmed");
          };
          case (#published) { found := true };
          case (#revoking) { found := true };
          case (_) return #err("Photo is not published");
        };
      };
    };
    if (not found) return #err("Published photo not found");
    // Stable tombstone first: public listing must stop before external awaits.
    wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and intent.requestedBy == caller) {
          { intent with state = #revoking }
        } else intent
      },
    );
    let revoked = try {
      switch (await wanderStorage.revokeProjectPhoto(storageObjectId, objectId)) {
        case (#ok(resource)) resource.status == #revoked or resource.status == #deleted;
        case (#err(_)) false;
      }
    } catch (_) { false };
    if (not revoked) return #err("Photo revocation not confirmed; retry cleanup");
    let deleted = try {
      switch (await wanderStorage.deleteProjectPhoto(storageObjectId, objectId)) {
        case (#ok(resource)) resource.status == #deleted;
        case (#err(_)) false;
      }
    } catch (_) { false };
    if (not deleted) return #err("Photo deletion not confirmed; retry cleanup");
    // The storage object is deleted: remove its checkpoint reference as well.
    // This also keeps replayed deletions from leaving dangling attachments.
    wanderCheckpointPhotoBindings := Array.filter<WanderCheckpointPhotoBinding>(
      wanderCheckpointPhotoBindings,
      func(binding) { not (binding.objectId == objectId and binding.storageObjectId == storageObjectId) },
    );
    wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and intent.requestedBy == caller and intent.state == #revoking) {
          { intent with state = #deleted }
        } else intent
      },
    );
    #ok(true)
  };

  // Stable admission control prevents repeated cross-canister cleanup calls
  // from consuming unbounded cycles. Reserve before the first await.
  private var wanderCleanupLastAttempt : Int = 0;
  private let wanderCleanupCooldownNs : Int = 5_000_000_000;

  // Independent background recovery: ICP invokes heartbeat even when no
  // Object owner has the browser open. Only durable #revoking intents qualify.
  // At most one remote cleanup is admitted per minute, with no unbounded scan
  // of remote storage and no anonymous endpoint that can select arbitrary IDs.
  private var wanderCleanupHeartbeatLastAttempt : Int = 0;
  private var wanderCleanupHeartbeatCursor : Nat = 0;
  private transient var wanderCleanupHeartbeatInFlight : Bool = false;
  private let wanderCleanupHeartbeatIntervalNs : Int = 60_000_000_000;

  system func heartbeat() : async () {
    if (wanderCleanupHeartbeatInFlight) return;
    let now = Time.now();
    if (now < wanderCleanupHeartbeatLastAttempt or
        now - wanderCleanupHeartbeatLastAttempt < wanderCleanupHeartbeatIntervalNs) return;
    let pending = Array.filter<WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) { intent.state == #revoking },
    );
    if (pending.size() == 0) return;
    // Round-robin prevents a permanently failing object from starving others.
    let index = wanderCleanupHeartbeatCursor % pending.size();
    let intent = pending[index];
    wanderCleanupHeartbeatCursor := (index + 1) % pending.size();
    wanderCleanupHeartbeatInFlight := true;
    wanderCleanupHeartbeatLastAttempt := now;
    try {
      let revoked = try {
        switch (await wanderStorage.revokeProjectPhoto(intent.storageObjectId, intent.objectId)) {
          case (#ok(resource)) resource.status == #revoked or resource.status == #deleted;
          case (#err(_)) false;
        }
      } catch (_) { false };
      if (revoked) {
        let deleted = try {
          switch (await wanderStorage.deleteProjectPhoto(intent.storageObjectId, intent.objectId)) {
            case (#ok(resource)) resource.status == #deleted;
            case (#err(_)) false;
          }
        } catch (_) { false };
        if (deleted) {
          wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
            wanderPhotoPublicationIntents,
            func(current) {
              if (current.objectId == intent.objectId and
                  current.storageObjectId == intent.storageObjectId and
                  current.state == #revoking) { { current with state = #deleted } }
              else current
            },
          );
        };
      };
    } catch (_) {};
    wanderCleanupHeartbeatInFlight := false;
  };

  // Authenticated, globally throttled cleanup for tombstoned photos.
  // No caller can select a live photo for deletion through this endpoint.
  // A signed-in user can advance recovery after a guest removes a Checkpoint.
  public shared ({ caller }) func retryWanderPhotoCleanup(
    objectId : Text,
    storageObjectId : Text,
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    let owner = switch (objectTrack(objectId)) {
      case null return #err("Wander object not found");
      case (?item) item.createdBy;
    };
    if (caller != owner) return #err("Only the Wander owner can reconcile photo cleanup");
    let eligible = Array.find<WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        intent.objectId == objectId and intent.storageObjectId == storageObjectId and
        intent.state == #revoking
      },
    ) != null;
    if (not eligible) return #err("No pending photo cleanup");
    let now = Time.now();
    if (now < wanderCleanupLastAttempt or
        now - wanderCleanupLastAttempt < wanderCleanupCooldownNs) {
      return #err("Cleanup is rate limited; retry later");
    };
    wanderCleanupLastAttempt := now;
    let revoked = try {
      switch (await wanderStorage.revokeProjectPhoto(storageObjectId, objectId)) {
        case (#ok(resource)) resource.status == #revoked or resource.status == #deleted;
        case (#err(_)) false;
      }
    } catch (_) { false };
    if (not revoked) return #err("Photo revocation not confirmed; retry later");
    let deleted = try {
      switch (await wanderStorage.deleteProjectPhoto(storageObjectId, objectId)) {
        case (#ok(resource)) resource.status == #deleted;
        case (#err(_)) false;
      }
    } catch (_) { false };
    if (not deleted) return #err("Photo deletion not confirmed; retry later");
    wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and
            intent.state == #revoking) { { intent with state = #deleted } }
        else intent
      },
    );
    #ok(true)
  };

  // Bounded public work inventory: exposes only tombstoned storage IDs,
  // never owners, unpublished uploads, or other private intent metadata.
  public query func listPendingWanderPhotoCleanup(
    objectId : Text,
  ) : async [Text] {
    let pending = Array.filter<WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) { intent.objectId == objectId and intent.state == #revoking },
    );
    let limited = if (pending.size() > 20) {
      Array.tabulate<WanderPhotoPublicationIntent>(20, func(i) { pending[i] })
    } else pending;
    Array.map<WanderPhotoPublicationIntent, Text>(limited, func(intent) { intent.storageObjectId })
  };

  public shared ({ caller }) func cancelOwnedWanderPhotoPublication(
    objectId : Text,
    storageObjectId : Text,
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    var found = false;
    var alreadyCancelled = false;
    for (intent in wanderPhotoPublicationIntents.vals()) {
      if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and
          intent.requestedBy == caller) {
        if (intent.state == #pending) { found := true }
        else if (intent.state == #cancelled) { alreadyCancelled := true }
        else { return #err("Cannot cancel an in-progress or published photo") };
      };
    };
    // Replayed cancellation after a lost acknowledgement is successful.
    if (not found and alreadyCancelled) return #ok(true);
    if (not found) return #err("Pending publication not found");
    // Keep a tombstone to prevent a cancelled storage object from being
    // rebound to another Wander object without explicit reconciliation.
    wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        if (intent.objectId == objectId and intent.storageObjectId == storageObjectId and
            intent.requestedBy == caller) {
          { intent with state = #cancelled }
        } else { intent }
      },
    );
    #ok(true)
  };

  public shared query ({ caller }) func listMyWanderPhotoPublicationIntents(
  ) : async [WanderPhotoPublicationIntent] {
    if (Principal.isAnonymous(caller)) return [];
    Array.filter<WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) { intent.requestedBy == caller },
    )
  };

  // Public, canonical photo bindings are derived only from successfully
  // published durable intents. Never expose pending uploads as readable photos.
  public type PublishedWanderPhotoBinding = {
    objectId : Text;
    storageObjectId : Text;
    storageOwner : Principal;
    storageId : Text;
    resourceId : Text;
  };

  public query func listPublishedWanderObjectPhotos(
    objectId : Text,
  ) : async [PublishedWanderPhotoBinding] {
    switch (objectTrack(objectId)) {
      case null return [];
      case (?_) {};
    };
    let bindings = Array.filter<WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        intent.objectId == objectId and intent.state == #published
      },
    );
    Array.map<WanderPhotoPublicationIntent, PublishedWanderPhotoBinding>(
      bindings,
      func(intent) {
        {
          objectId = intent.objectId;
          storageObjectId = intent.storageObjectId;
          storageOwner = intent.requestedBy;
          storageId = "project-wander-photo";
          resourceId = intent.storageObjectId;
        }
      },
    )
  };

  // Only the Object owner may explicitly attach a published photo to an
  // existing, uniquely identified Checkpoint. Guest upload is not enabled.
  public shared ({ caller }) func bindOwnedWanderPhotoToCheckpoint(
    objectId : Text, timestamp : Time.Time, author : Principal,
    storageObjectId : Text,
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    switch (objectTrack(objectId)) {
      case null return #err("Wander object not found");
      case (?item) {
        if (item.createdBy != caller) return #err("Only the object owner may bind photos");
      };
    };
    let matching = List.filter<Types.CheckPoint>(checkpoints, func(cp) {
      cp.trackId == objectId and cp.timestamp == timestamp and
      cp.createdBy == author and cp.isPublic and
      Text.startsWith(cp.note, #text guestCheckpointPrefix)
    });
    if (List.size(matching) != 1) return #err("Checkpoint not found or ambiguous");
    let published = Array.find<WanderPhotoPublicationIntent>(
      wanderPhotoPublicationIntents,
      func(intent) {
        intent.objectId == objectId and intent.storageObjectId == storageObjectId and
        intent.requestedBy == caller and intent.state == #published
      },
    ) != null;
    if (not published) return #err("Published owned photo not found");
    for (binding in wanderCheckpointPhotoBindings.vals()) {
      if (binding.storageObjectId == storageObjectId) {
        if (binding.objectId == objectId and binding.timestamp == timestamp and
            binding.author == author) return #ok(true);
        return #err("Photo already bound to another Checkpoint");
      };
    };
    if (wanderCheckpointPhotoBindings.size() >= wanderPhotoIntentLimit) {
      return #err("Checkpoint photo binding capacity reached");
    };
    wanderCheckpointPhotoBindings := Array.append<WanderCheckpointPhotoBinding>(
      wanderCheckpointPhotoBindings,
      [{ objectId; timestamp; author; storageObjectId }],
    );
    #ok(true)
  };

  public query func listWanderCheckpointPhotos(
    objectId : Text, timestamp : Time.Time, author : Principal,
  ) : async [PublishedWanderPhotoBinding] {
    switch (objectTrack(objectId)) {
      case null return [];
      case (?_) {};
    };
    let photos = Array.filter<WanderCheckpointPhotoBinding>(
      wanderCheckpointPhotoBindings,
      func(binding) {
        binding.objectId == objectId and binding.timestamp == timestamp and
        binding.author == author
      },
    );
    let active = Array.filter<WanderCheckpointPhotoBinding>(photos, func(binding) {
      // Do not return references to checkpoints already deleted.
      List.find<Types.CheckPoint>(checkpoints, func(cp) {
        cp.trackId == binding.objectId and cp.timestamp == binding.timestamp and
        cp.createdBy == binding.author and cp.isPublic
      }) != null and
      Array.find<WanderPhotoPublicationIntent>(wanderPhotoPublicationIntents, func(intent) {
        intent.objectId == objectId and intent.storageObjectId == binding.storageObjectId and
        intent.state == #published
      }) != null
    });
    Array.map<WanderCheckpointPhotoBinding, PublishedWanderPhotoBinding>(active, func(binding) {
      let owner = switch (Array.find<WanderPhotoPublicationIntent>(wanderPhotoPublicationIntents, func(intent) {
        intent.objectId == objectId and intent.storageObjectId == binding.storageObjectId and
        intent.state == #published
      })) {
        case (?intent) intent.requestedBy;
        case null Principal.fromText("2vxsx-fae");
      };
      {
        objectId;
        storageObjectId = binding.storageObjectId;
        storageOwner = owner;
        storageId = "project-wander-photo";
        resourceId = binding.storageObjectId;
      }
    })
  };

  private func guestPolicy(id : Text) : ?(Principal, Bool) {
    for ((storedId, gateway, enabled) in objectGuestPolicies.vals()) {
      if (storedId == id) return ?(gateway, enabled);
    };
    null
  };

  private func objectCommentsEnabled(objectId : Text) : Bool {
    for (id in objectCommentsClosed.vals()) {
      if (id == objectId) return false;
    };
    true
  };

  // Public read supports the owner setting and the visitor's comment form.
  // Unknown IDs return null; valid legacy objects default to comments enabled.
  public query func getObjectCommentsEnabled(objectId : Text) : async ?Bool {
    switch (objectTrack(objectId)) {
      case null { null };
      case (?_) { ?objectCommentsEnabled(objectId) };
    }
  };

  public shared ({ caller }) func setObjectCommentsEnabled(
    objectId : Text, enabled : Bool
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    switch (objectTrack(objectId)) {
      case null { return #err("Object not found") };
      case (?item) {
        if (item.createdBy != caller) return #err("Only owner may manage comments");
      };
    };
    if (not enabled and objectCommentsEnabled(objectId) and
        objectCommentsClosed.size() >= guestMaxPolicies) {
      return #err("Object comment policy capacity reached");
    };
    let other = Array.filter<Text>(objectCommentsClosed, func(id) { id != objectId });
    objectCommentsClosed := if (enabled) { other } else {
      Array.append<Text>(other, [objectId])
    };
    #ok(enabled)
  };

  // Keep the offline submission's UUID requestId when stripping user notes.
  // Otherwise a lost update response could make the outbox resubmit the
  // same location because the duplicate check searches for that requestId.
  // Recognize only a canonical trailing JSON string UUID; do not reuse any
  // user-supplied JSON or untrusted embedded photo link.
  private func retainedObjectRequestId(note : Text) : Text {
    let parts = Iter.toArray(Text.split(note, #text ",\"requestId\":\""));
    if (parts.size() != 2) return "";
    let chars = Iter.toArray(parts[1].chars());
    if (chars.size() != 38 or chars[36] != '\"' or chars[37] != '}') return "";
    var valid = true;
    for (i in Iter.range(0, 35)) {
      let char = chars[i];
      if (i == 8 or i == 13 or i == 18 or i == 23) {
        if (char != '-') valid := false;
      } else {
        let n = Char.toNat32(char);
        if (not (
          (n >= 48 and n <= 57) or
          (n >= 65 and n <= 70) or
          (n >= 97 and n <= 102)
        )) valid := false;
      };
    };
    if (not valid) return "";
    let uuid = Text.fromIter(Array.tabulate<Char>(36, func(i) { chars[i] }).vals());
    ",\"requestId\":\"" # uuid # "\""
  };

  // Keep check-in location and action, redact attached note/photo, while
  // retaining only the validated requestId required for offline deduplication.
  private func redactedObjectNote(note : Text) : ?Text {
    let base = guestCheckpointPrefix # "{\"action\":\"";
    let action = if (Text.startsWith(note, #text (base # "found\""))) {
      "found"
    } else if (Text.startsWith(note, #text (base # "carried\""))) {
      "carried"
    } else if (Text.startsWith(note, #text (base # "left\""))) {
      "left"
    } else { return null };
    ?(guestCheckpointPrefix # "{\"action\":\"" # action # "\",\"note\":\"\"" #
      retainedObjectRequestId(note) # "}")
  };

  // Delete one whole Object Checkpoint, including its location and public note.
  // Other tracks and other Object check-ins are never touched.
  // Gateway-authored guest check-ins can be deleted by the Object owner,
  // but not by an unrelated user sharing the public QR.
  public shared ({ caller }) func deleteObjectCheckpoint(
    objectId : Text, timestamp : Time.Time, author : Principal
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    let owner = switch (objectTrack(objectId)) {
      case null { return #err("Object not found") };
      case (?item) { item.createdBy };
    };
    if (caller != owner and caller != author) return #err("Not authorized");
    let matching = List.filter<Types.CheckPoint>(
      checkpoints, func(cp) {
        cp.trackId == objectId and cp.timestamp == timestamp and
        cp.createdBy == author and cp.isPublic and
        Text.startsWith(cp.note, #text guestCheckpointPrefix)
      }
    );
    // A legacy Track checkpoint isn't eligible, and ambiguous IDs must fail
    // closed rather than deleting multiple checkpoints.
    if (List.size(matching) != 1) return #err("Object check-in not found or ambiguous");
    // Hide linked photos before removing the Checkpoint. ICEStorage cleanup
    // remains retryable through deleteOwnedWanderPhoto; no external await here.
    let linked = Array.filter<WanderCheckpointPhotoBinding>(
      wanderCheckpointPhotoBindings,
      func(binding) {
        binding.objectId == objectId and binding.timestamp == timestamp and
        binding.author == author
      },
    );
    for (binding in linked.vals()) {
      wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
        wanderPhotoPublicationIntents,
        func(intent) {
          if (intent.objectId == objectId and intent.storageObjectId == binding.storageObjectId and
              intent.state == #published) { { intent with state = #revoking } }
          else intent
        },
      );
    };
    wanderCheckpointPhotoBindings := Array.filter<WanderCheckpointPhotoBinding>(
      wanderCheckpointPhotoBindings,
      func(binding) {
        not (binding.objectId == objectId and binding.timestamp == timestamp and
             binding.author == author)
      },
    );
    checkpoints := List.filter<Types.CheckPoint>(
      checkpoints, func(cp) {
        not (
          cp.trackId == objectId and cp.timestamp == timestamp and
          cp.createdBy == author and cp.isPublic and
          Text.startsWith(cp.note, #text guestCheckpointPrefix)
        )
      }
    );
    // Attempt ICEStorage revocation immediately after the durable tombstone.
    // A failed remote call never restores the deleted Checkpoint. Its
    // #revoking intent remains available for authenticated reconciliation.
    for (binding in linked.vals()) {
      let revoked = try {
        switch (await wanderStorage.revokeProjectPhoto(binding.storageObjectId, objectId)) {
          case (#ok(resource)) resource.status == #revoked or resource.status == #deleted;
          case (#err(_)) false;
        }
      } catch (_) { false };
      if (revoked) {
        let deleted = try {
          switch (await wanderStorage.deleteProjectPhoto(binding.storageObjectId, objectId)) {
            case (#ok(resource)) resource.status == #deleted;
            case (#err(_)) false;
          }
        } catch (_) { false };
        if (deleted) {
          wanderPhotoPublicationIntents := Array.map<WanderPhotoPublicationIntent, WanderPhotoPublicationIntent>(
            wanderPhotoPublicationIntents,
            func(intent) {
              if (intent.objectId == objectId and intent.storageObjectId == binding.storageObjectId and
                  intent.state == #revoking) { { intent with state = #deleted } }
              else intent
            },
          );
        };
      };
    };
    // Keep replay receipts and daily guest quota: deletion must not allow
    // bypassing rate limits or replaying removed submissions.
    #ok(true)
  };

  public query func getObjectGuestPolicy(objectId : Text) : async ?{
    enabled : Bool;
    gateway : Principal;
  } {
    switch (objectTrack(objectId), guestPolicy(objectId)) {
      case (?_, ?(gateway, enabled)) { ?{ enabled; gateway } };
      case _ { null };
    }
  };

  public shared ({ caller }) func setObjectGuestPolicy(
    objectId : Text, enabled : Bool, gateway : Principal
  ) : async Result.Result<Bool, Text> {
    if (Principal.isAnonymous(caller)) return #err("Login required");
    switch (objectTrack(objectId)) {
      case null { return #err("Object not found") };
      case (?item) {
        if (item.createdBy != caller) return #err("Only owner may change guest policy");
      };
    };
    if (enabled and Principal.isAnonymous(gateway)) return #err("Gateway may not be anonymous");
    if (guestPolicy(objectId) == null and objectGuestPolicies.size() >= guestMaxPolicies) {
      return #err("Guest policy capacity reached");
    };
    objectGuestPolicies := Array.append<(Text, Principal, Bool)>(
      Array.filter<(Text, Principal, Bool)>(
        objectGuestPolicies, func(e) { e.0 != objectId }
      ),
      [(objectId, gateway, enabled)]
    );
    #ok(enabled)
  };

  private func roundPublicCoordinate(value : Float) : Float {
    Float.floor(value * 1000.0 + 0.5) / 1000.0
  };

  // JSON-safe text for existing versioned CheckPoint note metadata.
  private func escapeGuestNote(note : Text) : ?Text {
    var out = "";
    for (ch in note.chars()) {
      if (ch == '\"') { out := out # "\\\"" }
      else if (ch == '\\') { out := out # "\\\\" }
      else if (ch == '\n') { out := out # "\\n" }
      else if (ch == '\r') { out := out # "\\r" }
      else if (ch == '\t') { out := out # "\\t" }
      else if (Char.toNat32(ch) < 32) { return null }
      else { out := out # Text.fromChar(ch) };
    };
    ?out
  };

  public shared ({ caller }) func submitGuestCheckin(
    input : GuestCheckinInput
  ) : async Result.Result<Nat, GuestCheckinError> {
    // The calling Principal is the server relay, not an anonymous visitor.
    let policy = switch (guestPolicy(input.objectId)) {
      case null { return #err(#disabled) };
      case (?value) { value };
    };
    if (caller != policy.0) return #err(#unauthorized);
    if (not policy.1) return #err(#disabled);
    switch (objectTrack(input.objectId)) {
      case null { return #err(#notFound) };
      case (?_) {};
    };
    if (not (input.latitude >= -90.0 and input.latitude <= 90.0) or
        not (input.longitude >= -180.0 and input.longitude <= 180.0) or
        input.accuracyMeters > 2000 or Text.size(input.note) > 280 or
        Array.size(Blob.toArray(Text.encodeUtf8(input.note))) > 1200 or
        Text.size(input.requestId) != 36) {
      return #err(#invalid);
    };
    let safeNote = switch (escapeGuestNote(input.note)) {
      case null { return #err(#invalid) };
      case (?text) { text };
    };
    for ((storedObject, storedRequest, _) in guestRequestReceipts.vals()) {
      if (storedObject == input.objectId and storedRequest == input.requestId) {
        return #err(#duplicate);
      };
    };
    let now = Time.now();
    let day = now / guestDayNs;
    var count : Nat = 0;
    var lastAt : Int = 0;
    for ((objectId, usageDay, dailyCount, lastTime) in guestDailyUsage.vals()) {
      if (objectId == input.objectId and usageDay == day) {
        count := dailyCount;
        lastAt := lastTime;
      };
    };
    if (count >= guestDailyLimit or
        (lastAt > 0 and now - lastAt < guestMinimumGapNs)) {
      return #err(#rateLimited);
    };
    let actionText = switch (input.action) {
      case (#found) { "found" };
      case (#carried) { "carried" };
      case (#left) { "left" };
    };
    let storedNote = if (objectCommentsEnabled(input.objectId)) { safeNote } else { "" };
    let noteJson = "{\"action\":\"" # actionText #
      "\",\"accuracyMeters\":" # Nat.toText(input.accuracyMeters) #
      ",\"note\":\"" # storedNote # "\"}";
    let cp : Types.CheckPoint = {
      trackId = input.objectId;
      groupId = null;
      latitude = roundPublicCoordinate(input.latitude);
      longitude = roundPublicCoordinate(input.longitude);
      elevation = 0.0;
      note = guestCheckpointPrefix # noteJson;
      photo = null;
      timestamp = now;
      isPublic = true;
      createdBy = caller;
    };
    // Atomic in one update: there is no await between checks and all writes.
    guestDailyUsage := Array.append<(Text, Int, Nat, Int)>(
      Array.filter<(Text, Int, Nat, Int)>(
        guestDailyUsage,
        func(u) { u.1 == day and u.0 != input.objectId }
      ),
      [(input.objectId, day, count + 1, now)]
    );
    let recent = Array.filter<(Text, Text, Int)>(
      guestRequestReceipts,
      func(r) { now - r.2 < 7 * guestDayNs }
    );
    let keep = if (recent.size() >= guestMaxReceipts) {
      let offset = recent.size() - guestMaxReceipts + 1;
      Array.tabulate<(Text, Text, Int)>(
        recent.size() - offset,
        func(i) { recent[i + offset] }
      )
    } else { recent };
    guestRequestReceipts := Array.append<(Text, Text, Int)>(
      keep, [(input.objectId, input.requestId, now)]
    );
    checkpoints := List.push<Types.CheckPoint>(cp, checkpoints);
    #ok(1)
  };

  //==========================================================
  // Checkpoints
  //==========================================================

  public shared (msg) func createCheckpoint(checkpoint : Types.NewCheckPoint) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users are not allowed to create checkpoints");
    };

    // Object owners can stop new text/photo comments without stopping location
    // check-ins. Enforce this in the canister (not only in the browser).
    var storedNote = checkpoint.note;
    var storedPhoto = checkpoint.photo;
    if (Text.startsWith(checkpoint.trackId, #text "obj-")) {
      switch (objectTrack(checkpoint.trackId)) {
        case null { return #err("Object not found") };
        case (?_) {};
      };
      if (not objectCommentsEnabled(checkpoint.trackId)) {
        switch (redactedObjectNote(checkpoint.note)) {
          case null { return #err("Object comments are closed") };
          case (?safe) {
            storedNote := safe;
            storedPhoto := null;
          };
        };
      };
    };

    let cp : Types.CheckPoint = {
      trackId = checkpoint.trackId;
      groupId = checkpoint.groupId;
      latitude = checkpoint.latitude;
      longitude = checkpoint.longitude;
      elevation = checkpoint.elevation;
      note = storedNote;
      photo = storedPhoto;
      timestamp = checkpoint.timestamp;
      isPublic = checkpoint.isPublic;
      createdBy = msg.caller;
    };
    checkpoints := List.push(cp, checkpoints);
    #ok(1);
  };

  type CheckpointFilter = {
    #user : Principal;
    #groupId : Text;
  };

  public query func getCheckPointsByTrackId(trackId : Text) : async [Types.CheckPoint] {
    let filtered = List.filter<Types.CheckPoint>(
      checkpoints,
      func(cp : Types.CheckPoint) : Bool {
        cp.trackId == trackId and cp.isPublic;
      },
    );
    List.toArray(filtered);
  };

  public query func getCheckpoints(filter : CheckpointFilter, startime : Time.Time, endtime : Time.Time) : async [Types.CheckPoint] {
    let filtered = List.filter<Types.CheckPoint>(
      checkpoints,
      func(cp : Types.CheckPoint) : Bool {
        let timeInRange = cp.timestamp >= startime and cp.timestamp <= endtime;
        let matchesFilter = switch (filter) {
          case (#user(principal)) { cp.createdBy == principal };
          case (#groupId(gid)) {
            switch (cp.groupId) {
              case (?groupId) { groupId == gid };
              case (null) { false };
            };
          };
        };
        timeInRange and matchesFilter and cp.isPublic;
      },
    );
    List.toArray(filtered);
  };

  public query func getLatestCheckpoints() : async [Types.CheckPoint] {
    let allCheckpoints = List.toArray(checkpoints);
    let filtered = Array.filter<Types.CheckPoint>(allCheckpoints, func(cp) {
      Text.notEqual(cp.note, "")
    });
    let sorted = Buffer.fromArray<Types.CheckPoint>(filtered);
    sorted.sort(func(a, b) {
      if (a.timestamp > b.timestamp) { #less } else if (a.timestamp < b.timestamp) { #greater } else { #equal }
    }); 
    let count = if (sorted.size() < 50) { sorted.size() } else { 50 };
    Buffer.toArray(Buffer.subBuffer(sorted, 0, count));
  };

  //=========================================================
  // Incident Points
  //========================================================
  public shared (msg) func createIncidentPoint(incident : Types.NewIncidentPoint) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users are not allowed to create incident points");
    };

    let ip : Types.IncidentPoint = {
      trackId = incident.trackId;
      groupId = incident.groupId;
      latitude = incident.latitude;
      longitude = incident.longitude;
      elevation = incident.elevation;
      note = incident.note;
      photo = incident.photo;
      timestamp = incident.timestamp;
      severity = incident.severity;
      category = incident.category;
      createdBy = msg.caller;
    };
    incidentPoints := List.push(ip, incidentPoints);
    #ok(1);
  };

  public query func getIncidentPointsByTrack(trackId : Text) : async [Types.IncidentPoint] {
    let filtered = List.filter<Types.IncidentPoint>(
      incidentPoints,
      func(ip : Types.IncidentPoint) : Bool {
        ip.trackId == trackId;
      },
    );
    List.toArray(filtered);
  };

  public query func getIncidentPointsByCategory(category : Types.IncidentCategory) : async [Types.IncidentPoint] {
    let filtered = List.filter<Types.IncidentPoint>(
      incidentPoints,
      func(ip : Types.IncidentPoint) : Bool {
        ip.category == category;
      },
    );
    List.toArray(filtered);
  };

  public query func getIncidentPointsBySeverity(severity : Types.Severity) : async [Types.IncidentPoint] {
    let filtered = List.filter<Types.IncidentPoint>(
      incidentPoints,
      func(ip : Types.IncidentPoint) : Bool {
        ip.severity == severity;
      },
    );
    List.toArray(filtered);
  };

  public query func getIncidentPointsByTimeRange(startTime : Time.Time, endTime : Time.Time) : async [Types.IncidentPoint] {
    let filtered = List.filter<Types.IncidentPoint>(
      incidentPoints,
      func(ip : Types.IncidentPoint) : Bool {
        ip.timestamp >= startTime and ip.timestamp <= endTime
      },
    );
    List.toArray(filtered);
  };
  public query func getIncidentCheckpoints(startTime : Time.Time, endTime : Time.Time) : async [Types.IncidentPoint] {
    let filtered = List.filter<Types.IncidentPoint>(
      incidentPoints,
      func(cp : Types.IncidentPoint) : Bool {
        cp.timestamp >= startTime and cp.timestamp <= endTime;
      },
    );
    List.toArray(filtered);
  };
  //========================================================
  // checkpoint comments
  //========================================================
  public query func getCheckpointComments(timestamp : Time.Time, createdBy : Principal) : async [Types.CheckpointComment] {
    let filtered = List.filter<Types.CheckpointComment>(
      checkpointComments,
      func(c : Types.CheckpointComment) : Bool {
        c.checkpointTimestamp == timestamp and c.checkpointCreatedBy == createdBy
      },
    );
    List.toArray(filtered);
  };

  public shared (msg) func addCheckpointComment(
    checkpointTimestamp : Time.Time,
    checkpointCreatedBy : Principal,
    comment : {
      comment : Text;
      photo : ?Text;
      timestamp : Time.Time;
    },
  ) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot add comments");
    };

    let newComment : Types.CheckpointComment = {
      checkpointTimestamp = checkpointTimestamp;
      checkpointCreatedBy = checkpointCreatedBy;
      comment = comment.comment;
      photo = comment.photo;
      timestamp = comment.timestamp;
      createdBy = msg.caller;
    };

    checkpointComments := List.push(newComment, checkpointComments);
    #ok(1);
  };
  //=========================================================
  // saved points
  //=========================================================
  public shared (msg) func createSavedPoint(point : Types.NewSavedPoint) : async Result.Result<Types.SavedPoint, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot create saved points");
    };

    // Check if point already exists by comparing coordinates
    let existingPoint = List.find<Types.SavedPoint>(
      savedPoints,
      func(p : Types.SavedPoint) : Bool {
        p.latitude == point.latitude and p.longitude == point.longitude and p.createdBy == msg.caller
      },
    );

    switch (existingPoint) {
      case (?_existing) {
        return #err("A saved point already exists at these coordinates");
      };
      case null {
        let newPoint : Types.SavedPoint = {
          description = point.description;
          latitude = point.latitude;
          longitude = point.longitude;
          category = point.category;
          createdBy = msg.caller;
          createdAt = Time.now();
        };

        savedPoints := List.push(newPoint, savedPoints);
        #ok(newPoint);
      };
    };
  };

  public shared (msg) func savePoints(points : [Types.NewSavedPoint]) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot create saved points");
    };

    for (point in points.vals()) {
      let newPoint : Types.SavedPoint = {

        description = point.description;
        latitude = point.latitude;
        longitude = point.longitude;

        category = point.category;

        createdBy = msg.caller;
        createdAt = Time.now();
      };
      savedPoints := List.push(newPoint, savedPoints);
    };

    #ok(points.size());
  };

  public query (msg) func getMySavedPoints() : async [Types.SavedPoint] {
    let filtered = List.filter<Types.SavedPoint>(
      savedPoints,
      func(p : Types.SavedPoint) : Bool {
        p.createdBy == msg.caller;
      },
    );
    List.toArray(filtered);
  };
  public query func getSavedPointsByCategory(category : Text) : async [Types.SavedPoint] {
    let filtered = List.filter<Types.SavedPoint>(
      savedPoints,
      func(p : Types.SavedPoint) : Bool {
        p.category == category;
      },
    );
    List.toArray(filtered);
  };
  //=========================================================
  // Spots
  //=========================================================

  public shared (msg) func createSpot(spot : Types.NewSpot) : async Result.Result<Types.SpotV2, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot create spots");
    };

    let newSpotV2 : Types.SpotV2 = {
      id = nextSpotId;
      name = spot.name;
      description = spot.description;
      tags = spot.tags;
      createdBy = msg.caller;
      createdAt = Time.now();
    };

    // keep legacy representation for compatibility
    let legacySpot : Types.Spot = {
      name = spot.name;
      description = spot.description;
      tags = spot.tags;
      createdBy = msg.caller;
      createdAt = newSpotV2.createdAt;
    };

    spotsV2 := List.push(newSpotV2, spotsV2);
    spots := List.push(legacySpot, spots);
    nextSpotId += 1;
    #ok(newSpotV2);
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query func getSpots(page : Nat, pageSize : Nat) : async [Types.SpotV2] {
    if (pageSize == 0) { [] } else {
      let arr = List.toArray(spotsV2);
      let total = Array.size(arr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
  let res = Buffer.Buffer<Types.SpotV2>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(arr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query (msg) func getMySpots(page : Nat, pageSize : Nat) : async [Types.SpotV2] {
    if (pageSize == 0) { [] } else {
      let filteredArr = List.toArray(List.filter<Types.SpotV2>(
        spotsV2,
        func(s : Types.SpotV2) : Bool { s.createdBy == msg.caller },
      ));
      let total = Array.size(filteredArr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.SpotV2>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(filteredArr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };

  public query func getSpotById(id : Nat) : async ?Types.SpotV2 {
    List.find<Types.SpotV2>(spotsV2, func(s) { s.id == id });
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query func searchSpotsByTag(tag : Text, page : Nat, pageSize : Nat) : async [Types.SpotV2] {
    if (pageSize == 0) { [] } else {
      let filteredArr = List.toArray(List.filter<Types.SpotV2>(
        spotsV2,
        func(s : Types.SpotV2) : Bool {
          Array.find<Text>(s.tags, func(t) { t == tag }) != null;
        },
      ));
      let total = Array.size(filteredArr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.SpotV2>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(filteredArr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };

  public shared (msg) func updateSpot(name : Text, updates : Types.NewSpot) : async Result.Result<Types.Spot, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot update spots");
    };

    let existing = List.find<Types.SpotV2>(spotsV2, func(s) { s.name == name });
    switch (existing) {
      case null { #err("Spot not found") };
      case (?s) {
        if (s.createdBy != msg.caller) { return #err("Only creator can update this spot") };

        let updated : Types.SpotV2 = {
          id = s.id;
          name = updates.name;
          description = updates.description;
          tags = updates.tags;
          createdBy = s.createdBy;
          createdAt = s.createdAt;
        };

        // remove old and push updated in spotsV2
        spotsV2 := List.filter<Types.SpotV2>(spotsV2, func(x : Types.SpotV2) : Bool { x.id != s.id });
        spotsV2 := List.push(updated, spotsV2);
        #ok(updated);
      };
    };
  };

  public shared (msg) func deleteSpot(name : Text) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot delete spots");
    };

    let existing = List.find<Types.SpotV2>(spotsV2, func(s) { s.name == name and s.createdBy == msg.caller });
    switch (existing) {
      case null { #err("Spot not found or not owned by caller") };
      case (?s) {
        spotsV2 := List.filter<Types.SpotV2>(spotsV2, func(x : Types.SpotV2) : Bool { not (x.name == name and x.createdBy == msg.caller) });
        #ok(1);
      };
    };
  };
  //==========================================================
  // Tracks
  //=========================================================

  public shared (msg) func createTrack(track : Types.NewTrack) : async Result.Result<Types.Track, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users are not allowed to create tracks");
    };

    // Objects have unique IDs; reject shadowing another owner's public QR.
    if (Text.startsWith(track.id, #text "obj-")) {
      if (not track.isPublic or track.trackType != #other or
          not Text.startsWith(track.description, #text objectMetadataPrefix)) {
        return #err("Invalid object tracking record");
      };
      switch (List.find<Types.Track>(tracks, func(t) { t.id == track.id })) {
        case (?_) { return #err("Object ID already exists") };
        case null {};
      };
    };

    let newTrack : Types.Track = {
      id = track.id;
      name = track.name;
      description = track.description;
      length = track.length;
      elevation = track.elevation;
      duration = track.duration;
      startime = track.startime;
      createdBy = msg.caller;
      isPublic = track.isPublic;
      groupId = track.groupId;
      trackfile = track.trackfile;
      startPoint = track.startPoint;
      trackType = track.trackType;
    };
    tracks := List.push(newTrack, tracks);

    
    //update user stats
    if (track.trackType == #hike) {
      ignore updateUserStats(
        Principal.toText(msg.caller),
        track.length, // distance
        track.duration, // hours
        track.elevation // elevation gain
      );
      //update group stats
      switch (track.groupId) {
        case (?groupId) {
          ignore updateUserStats(
            groupId,
            track.length, // distance
            track.duration, // hours
            track.elevation // elevation gain
          );
        };
        case null {

        };
      };
    };

    #ok(newTrack);
  };

  public query func getTrack(id : Text) : async ?Types.Track {
    List.find<Types.Track>(tracks, func(t) { t.id == id });
  };

  type TrackFilter = {
    #user : Principal;
    #group : Text;
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query func getTracks(filter : TrackFilter, page : Nat, pageSize : Nat) : async [Types.Track] {
    if (pageSize == 0) { [] } else {
      let filteredArr = List.toArray(List.filter<Types.Track>(
        tracks,
        func(track : Types.Track) : Bool {
          switch (filter) {
            case (#user(principal)) { track.createdBy == principal };
            case (#group(groupId)) {
              switch (track.groupId) {
                case (?gid) { gid == groupId };
                case null { false };
              };
            };
          };
        },
      ));
      let total = Array.size(filteredArr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.Track>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(filteredArr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };

  //==========================================================
  // trails
  //=========================================================

  public shared (msg) func createTrail(trail : Types.NewTrail) : async Result.Result<Types.Trail, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users are not allowed to create trails");
    };
    let newTrail : Types.Trail = {
      id = nextTrailId;
      name = trail.name;
      description = trail.description;
      distance = trail.distance;
      elevationGain = trail.elevationGain;
      duration = trail.duration;
      trailfile = trail.trailfile;
      ttype = trail.ttype;
      difficulty = trail.difficulty;
      tags = trail.tags;
      rate = trail.rate;
      photos = trail.photos;
      createdAt = Time.now();
      createdBy = msg.caller;
      startPoint = trail.startPoint;
    };
    trails := List.push(newTrail, trails);
    nextTrailId += 1;
    #ok(newTrail);
  };

  public shared (msg) func updateTrail(id : Nat, updates : Types.UpdateTrail) : async Result.Result<Types.Trail, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users are not allowed to update trails");
    };

    let existing = List.find<Types.Trail>(trails, func(t) { t.id == id });
    switch (existing) {
      case null { #err("Trail not found") };
      case (?t) {
        if (t.createdBy != msg.caller) {
          return #err("Only the creator can update this trail");
        };

        let updated : Types.Trail = {
          id = t.id;
          name = updates.name;
          description = updates.description;
          distance = updates.distance;
          elevationGain = updates.elevationGain;
          duration = updates.duration;
          trailfile = updates.trailfile;
          ttype = updates.ttype;
          difficulty = updates.difficulty;
          tags = updates.tags;
          rate = updates.rate;
          photos = updates.photos;
          createdAt = t.createdAt;
          createdBy = t.createdBy;
          startPoint = updates.startPoint;
        };

        trails := List.filter<Types.Trail>(
          trails,
          func(x : Types.Trail) : Bool { x.id != id },
        );
        trails := List.push(updated, trails);
        #ok(updated);
      };
    };
  };

  public query func getTrail(id : Nat) : async ?Types.Trail {
    List.find<Types.Trail>(trails, func(t) { t.id == id });
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query func searchTrails(term : Text, page : Nat, pageSize : Nat) : async [Types.Trail] {
    if (pageSize == 0) { [] } else {
      let filteredArr = List.toArray(List.filter<Types.Trail>(
        trails,
        func(trail : Types.Trail) : Bool {
          let nameMatch = Text.contains(trail.name, #text term);
          let descMatch = Text.contains(trail.description, #text term);
          let tagMatch = Array.find<Text>(
            trail.tags,
            func(tag) { Text.contains(tag, #text term) },
          ) != null;
          nameMatch or descMatch or tagMatch;
        },
      ));
      let total = Array.size(filteredArr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.Trail>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(filteredArr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };

  type TrailFilter = {
    #difficulty : Types.Difficulty;
    #ttype : Types.TrailType;
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query func getTrails(filter : TrailFilter, page : Nat, pageSize : Nat) : async [Types.Trail] {
    if (pageSize == 0) { [] } else {
      let filteredArr = List.toArray(List.filter<Types.Trail>(
        trails,
        func(trail : Types.Trail) : Bool {
          switch (filter) {
            case (#difficulty(level)) { trail.difficulty == level };
            case (#ttype(trailType)) { trail.ttype == trailType };
          };
        },
      ));
      let total = Array.size(filteredArr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.Trail>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(filteredArr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };
  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query (msg) func getMyTrails(page : Nat, pageSize : Nat) : async [Types.Trail] {
    if (pageSize == 0) { [] } else {
      let filteredArr = List.toArray(List.filter<Types.Trail>(
        trails,
        func(trail : Types.Trail) : Bool {
          trail.createdBy == msg.caller;
        },
      ));
      let total = Array.size(filteredArr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.Trail>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(filteredArr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };
  public query func getTrailsInBounds(
    bounds : {
      north : Float;
      south : Float;
      east : Float;
      west : Float;
    }
  ) : async [Types.Trail] {
    let filtered = List.filter<Types.Trail>(
      trails,
      func(trail : Types.Trail) : Bool {
        let lat = trail.startPoint.latitude;
        let lng = trail.startPoint.longitude;

        lat <= bounds.north and lat >= bounds.south and lng <= bounds.east and lng >= bounds.west;
      },
    );
    List.toArray(filtered);
  };

  public shared (msg) func deleteTrail(id : Nat) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot delete trails");
    };

    // Find the trail and verify ownership
    let trail = List.find<Types.Trail>(trails, func(t) { t.id == id });

    switch (trail) {
      case null { #err("Trail not found") };
      case (?t) {
        if (t.createdBy != msg.caller) {
          return #err("Only the creator can delete this trail");
        };

        // Filter out the trail with matching id
        trails := List.filter<Types.Trail>(
          trails,
          func(t : Types.Trail) : Bool { t.id != id },
        );

        #ok(1);
      };
    };
  };

  //==========================================================
  // Groups
  //==========================================================

  public shared (msg) func createGroup(group : Types.NewGroup) : async Result.Result<Types.Group, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users are not allowed to create groups");
    };
    switch (groups.get(group.id)) {
      case (?_) {
        #err("Group with ID " # group.id # " already exists");
      };
      case null {
        let newGroup : Types.Group = {
          id = group.id;
          name = group.name;
          description = group.description;
          members = group.members;
          admin = group.admin;
          badge = group.badge;
          createdAt = Time.now();
          createdBy = msg.caller;
        };
        groups.put(group.id, newGroup);
        #ok(newGroup);
      };
    };
  };

  public shared (msg) func updateGroup(groupId : Text, updates : Types.NewGroup) : async Result.Result<Nat, Text> {
    switch (groups.get(groupId)) {
      case null { #err("Group not found") };
      case (?existingGroup) {
        if (existingGroup.admin == msg.caller or msg.caller == existingGroup.createdBy) {
          let updatedGroup : Types.Group = {
            id = groupId;
            name = updates.name;
            description = updates.description;
            members = updates.members;
            badge = updates.badge;
            admin = updates.admin;
            createdAt = existingGroup.createdAt;
            createdBy = existingGroup.createdBy;
          };
          groups.put(groupId, updatedGroup);
          #ok(1);
        } else {
          #err("Only the admin can update the group");
        };
      };
    };
  };

  public query func getGroup(id : Text) : async ?Types.Group {
    groups.get(id);
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query (msg) func getMyGroups(page : Nat, pageSize : Nat) : async [Types.Group] {
    if (pageSize == 0) { [] } else {
      let filteredArr = Array.filter<Types.Group>(
        Iter.toArray(groups.vals()),
        func(group : Types.Group) : Bool {
          Array.find<Principal>(group.members, func(p) { p == msg.caller }) != null
        },
      );
      let total = Array.size(filteredArr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.Group>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(filteredArr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };

  //==========================================================
  // userstats
  //==========================================================
  private func updateUserStats(pid : Text, distance : Float, hours : Float, elevation : Float) : async Result.Result<Nat, Text> {

    let currentStats = switch (userStats.get(pid)) {
      case null {
        {
          id = pid;
          firstHikeDate = Time.now();
          totalDistance = 0.0;
          totalHours = 0.0;
          totalElevation = 0.0;
          completedTrails = 0;
        };
      };
      case (?stats) { stats };
    };

    let updatedStats : Types.UserStats = {
      id = currentStats.id;
      firstHikeDate = currentStats.firstHikeDate;
      totalDistance = currentStats.totalDistance + distance;
      totalHours = currentStats.totalHours + hours;
      totalElevation = currentStats.totalElevation + elevation;
      completedTrails = currentStats.completedTrails + 1;
    };

    userStats.put(pid, updatedStats);
    #ok(1);
  };
  public query func getUserstats(pid : Text) : async ?Types.UserStats {
    userStats.get(pid);
  };

  //==========================================================
  // photos
  //==========================================================
  public shared (msg) func addPhoto(
    photo : {
      trackId : Text;
      groupId : ?Text;
      tags : [Text];
      timestamp : Time.Time;
      photoUrl : Text;
    }
  ) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot add photos");
    };

    let newPhoto : Types.Photo = {
      trackId = photo.trackId;
      groupId = photo.groupId;
      tags = photo.tags;
      photoUrl = photo.photoUrl;
      timestamp = photo.timestamp;
      createdBy = msg.caller;
    };

    photos := List.push(newPhoto, photos);
    #ok(1);
  };

  public query func getTrackPhotos(trackId : Text, startTime : Time.Time, endTime : Time.Time) : async [Types.Photo] {
    let filtered = List.filter<Types.Photo>(
      photos,
      func(p : Types.Photo) : Bool {
        p.trackId == trackId and p.timestamp >= startTime and p.timestamp <= endTime
      },
    );
    List.toArray(filtered);
  };

  public query func getGroupPhotos(groupId : Text, startTime : Time.Time, endTime : Time.Time) : async [Types.Photo] {
    let filtered = List.filter<Types.Photo>(
      photos,
      func(p : Types.Photo) : Bool {
        let inTimeRange = p.timestamp >= startTime and p.timestamp <= endTime;
        let inGroup = switch (p.groupId) {
          case (?gid) { gid == groupId };
          case null { false };
        };
        inTimeRange and inGroup;
      },
    );
    List.toArray(filtered);
  };

  public query (msg) func getMyPhotos(startTime : Time.Time, endTime : Time.Time) : async [Types.Photo] {
    let filtered = List.filter<Types.Photo>(
      photos,
      func(p : Types.Photo) : Bool {
        p.createdBy == msg.caller and p.timestamp >= startTime and p.timestamp <= endTime
      },
    );
    List.toArray(filtered);
  };

  public query func searchPhotosByTags(searchTags : [Text]) : async [Types.Photo] {
    let filtered = List.filter<Types.Photo>(
      photos,
      func(p : Types.Photo) : Bool {
        for (searchTag in searchTags.vals()) {
          if (Array.find<Text>(p.tags, func(t) { t == searchTag }) != null) {
            return true;
          };
        };
        false;
      },
    );
    List.toArray(filtered);
  };

  public shared (msg) func deletePhoto(photoUrl : Text) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot delete photos");
    };

    // Find the photo and verify ownership
    let photo = List.find<Types.Photo>(photos, func(p) { p.photoUrl == photoUrl });

    switch (photo) {
      case null { #err("Photo not found") };
      case (?p) {
        if (p.createdBy != msg.caller) {
          return #err("Only the creator can delete this photo");
        };

        // Filter out the photo with matching URL
        photos := List.filter<Types.Photo>(
          photos,
          func(p : Types.Photo) : Bool { p.photoUrl != photoUrl },
        );

        #ok(1);
      };
    };
  };

  //=========================================================
  // user credntials
  // =========================================================
  public shared (msg) func createUserCredential(credential : Types.UserCredential) : async Result.Result<Nat, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot create credentials");
    };

    userCredentials.put(msg.caller, credential);
    #ok(1);

  };
  public query ({ caller }) func getMyCredential() : async ?Types.UserCredential {
    userCredentials.get(caller);
  };

  //==========================================================
  // Trackathons
  //==========================================================

  private func generateUUID(entropy : Blob) : Text {
    let bytes = Blob.toArray(entropy);
    let hexArray = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
    var uuid = "";
    var i = 0;
    for (byte in bytes.vals()) {
      if (i == 16) { return uuid }; // Use first 16 bytes for UUID
      let high = Nat8.toNat(byte / 16);
      let low = Nat8.toNat(byte % 16);
      uuid #= Text.fromChar(hexArray[high]);
      uuid #= Text.fromChar(hexArray[low]);
      if (i == 3 or i == 5 or i == 7 or i == 9) { uuid #= "-" };
      i += 1;
    };
    uuid
  };

  public shared (msg) func createTrackathon(trackathon : Types.NewTrackathon) : async Result.Result<Types.Trackathon, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot create trackathons");
    };

    // Generate UUID-like ID
    let entropy = await Random.blob();
    let id = generateUUID(entropy);
    let newTrackathon : Types.Trackathon = {
      id = id;
      name = trackathon.name;
      description = trackathon.description;
      startTime = trackathon.startTime;
      endTime = trackathon.endTime;
      duration = trackathon.duration;
      activityType = trackathon.activityType;
      groupId = trackathon.groupId;
      registrations = [];
      createdBy = msg.caller;
      createdAt = Time.now();
    };

    trackathons.put(id, newTrackathon);
    trackathonParticipants.put(id, HashMap.HashMap<Principal, Types.TrackathonParticipant>(1, Principal.equal, Principal.hash));
    #ok(newTrackathon);
  };

  public shared (msg) func registerForTrackathon(username: Text, trackathonId : Text) : async Result.Result<Text, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot register for trackathons");
    };

    switch (trackathons.get(trackathonId)) {
      case null { #err("Trackathon not found") };
      case (?trackathon) {
        let now = Time.now();
        if (now >= trackathon.startTime) {
          return #err("Registration closed - trackathon has already started");
        };

        if (Array.find<Principal>(trackathon.registrations, func(p) { p == msg.caller }) != null) {
          return #err("Already registered");
        };

        let updatedRegistrations = Array.append(trackathon.registrations, [msg.caller]);
        let updatedTrackathon = {
          id = trackathon.id;
          name = trackathon.name;
          description = trackathon.description;
          startTime = trackathon.startTime;
          endTime = trackathon.endTime;
          duration = trackathon.duration;
          activityType = trackathon.activityType;
          groupId = trackathon.groupId;
          registrations = updatedRegistrations;
          createdBy = trackathon.createdBy;
          createdAt = trackathon.createdAt;
        };
        trackathons.put(trackathonId, updatedTrackathon);

        // Initialize participant data
        switch (trackathonParticipants.get(trackathonId)) {
          case null { };
          case (?participants) {
            let participant : Types.TrackathonParticipant = {
              principal = msg.caller;
              username = username;
              startedAt = null;
              totalDistance = 0.0;
              totalElevationGain = 0.0;
              trackPoints = [];
              hasMintedBadge = false;
            };
            participants.put(msg.caller, participant);
          };
        };
        #ok("Successfully registered");
      };
    };
  };

  public shared (msg) func recordTrackathonPoint(trackathonId : Text, point : Types.TrackathonPoint) : async Result.Result<Text, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot record points");
    };

    switch (trackathons.get(trackathonId)) {
      case null { #err("Trackathon not found") };
      case (?trackathon) {
        let now = Time.now();
        if (now < trackathon.startTime) {
          return #err("Trackathon has not started yet");
        };
        if (now > trackathon.endTime) {
          return #err("Trackathon has ended");
        };

        switch (trackathonParticipants.get(trackathonId)) {
          case null { #err("Participant data not found") };
          case (?participants) {
            switch (participants.get(msg.caller)) {
              case null { #err("Not registered for this trackathon") };
              case (?participant) {
                let startedAt = switch (participant.startedAt) {
                  case null { ?now };
                  case (?time) { ?time };
                };

                // Calculate distance from last point if exists
                let newDistance = if (Array.size(participant.trackPoints) > 0) {
                  let lastPoint = participant.trackPoints[Array.size(participant.trackPoints) - 1];
                  let latDiff = point.lat - lastPoint.lat;
                  let lngDiff = point.lng - lastPoint.lng;
                  let distance = Float.sqrt(latDiff * latDiff + lngDiff * lngDiff) * 111.0; // rough km conversion
                  participant.totalDistance + distance;
                } else {
                  participant.totalDistance;
                };

                // Calculate elevation gain
                let newElevation = switch (point.elevation) {
                  case null { participant.totalElevationGain };
                  case (?elev) {
                    if (Array.size(participant.trackPoints) > 0) {
                      let lastPoint = participant.trackPoints[Array.size(participant.trackPoints) - 1];
                      switch (lastPoint.elevation) {
                        case null { participant.totalElevationGain };
                        case (?lastElev) {
                          let gain = elev - lastElev;
                          if (gain > 0.0) {
                            participant.totalElevationGain + gain;
                          } else {
                            participant.totalElevationGain;
                          };
                        };
                      };
                    } else {
                      participant.totalElevationGain;
                    };
                  };
                };

                let updatedParticipant : Types.TrackathonParticipant = {
                  principal = participant.principal;
                  username = participant.username;
                  startedAt = startedAt;
                  totalDistance = newDistance;
                  totalElevationGain = newElevation;
                  trackPoints = Array.append(participant.trackPoints, [point]);
                  hasMintedBadge = participant.hasMintedBadge;
                };
                participants.put(msg.caller, updatedParticipant);
                #ok("Point recorded");
              };
            };
          };
        };
      };
    };
  };

  public query func getTrackathon(trackathonId : Text) : async ?Types.Trackathon {
    trackathons.get(trackathonId);
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query func getAllTrackathons(page : Nat, pageSize : Nat) : async [Types.Trackathon] {
    if (pageSize == 0) { [] } else {
      let arr = Iter.toArray(trackathons.vals());
      let total = Array.size(arr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.Trackathon>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(arr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query (msg) func getMyTrackathons(page : Nat, pageSize : Nat) : async [Types.Trackathon] {
    if (pageSize == 0) { [] } else {
      let filteredArr = Array.filter<Types.Trackathon>(
        Iter.toArray(trackathons.vals()),
        func(t : Types.Trackathon) : Bool { t.createdBy == msg.caller },
      );
      let total = Array.size(filteredArr);
      let start : Nat = page * pageSize;
      if (start >= total) { [] } else {
        let res = Buffer.Buffer<Types.Trackathon>(0);
        var i : Nat = start;
        var taken : Nat = 0;
        while (i < total and taken < pageSize) {
          res.add(filteredArr[i]);
          i += 1;
          taken += 1;
        };
        Buffer.toArray(res);
      };
    };
  };

  // Pagination: page is zero-based. pageSize == 0 returns an empty list.
  public query func getTrackathonParticipants(trackathonId : Text, page : Nat, pageSize : Nat) : async [Types.TrackathonParticipant] {
    switch (trackathonParticipants.get(trackathonId)) {
      case null { [] };
      case (?participants) {
        if (pageSize == 0) { [] } else {
          let arr = Iter.toArray(participants.vals());
          let total = Array.size(arr);
          let start : Nat = page * pageSize;
          if (start >= total) { [] } else {
            let res = Buffer.Buffer<Types.TrackathonParticipant>(0);
            var i : Nat = start;
            var taken : Nat = 0;
            while (i < total and taken < pageSize) {
              res.add(arr[i]);
              i += 1;
              taken += 1;
            };
            Buffer.toArray(res);
          };
        };
      };
    };
  };

  public query (msg) func getMyTrackathonProgress(trackathonId : Text) : async ?Types.TrackathonParticipant {
    switch (trackathonParticipants.get(trackathonId)) {
      case null { null };
      case (?participants) {
        participants.get(msg.caller);
      };
    };
  };

  public shared (msg) func mintTrackathonBadge(trackathonId : Text) : async Result.Result<Types.TrackathonBadge, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot mint badges");
    };

    switch (trackathons.get(trackathonId)) {
      case null { #err("Trackathon not found") };
      case (?trackathon) {
        let now = Time.now();
        if (now < trackathon.endTime) {
          return #err("Trackathon has not ended yet");
        };

        switch (trackathonParticipants.get(trackathonId)) {
          case null { #err("Participant data not found") };
          case (?participants) {
            switch (participants.get(msg.caller)) {
              case null { #err("Not a participant") };
              case (?participant) {
                if (participant.hasMintedBadge) {
                  return #err("Badge already minted");
                };

                switch (participant.startedAt) {
                  case null { #err("Did not participate") };
                  case (?startTime) {
                    let duration = Float.fromInt((now - startTime) / 1000000000); // convert to seconds
                    
                    // Calculate rank
                    let allParticipants = Buffer.Buffer<Types.TrackathonParticipant>(0);
                    for ((p, pt) in participants.entries()) {
                      allParticipants.add(pt);
                    };
                    let sorted = Buffer.toArray(allParticipants);
                    // Sort by distance descending (simple rank by distance)
                    var rank : Nat = 1;
                    for (p in sorted.vals()) {
                      if (p.totalDistance > participant.totalDistance) {
                        rank += 1;
                      };
                    };

                    let badge : Types.TrackathonBadge = {
                      trackathonId = trackathonId;
                      trackathonName = trackathon.name;
                      participantPrincipal = msg.caller;
                      participantName = participant.username;
                      completionDate = now;
                      distance = participant.totalDistance;
                      elevationGain = participant.totalElevationGain;
                      duration = duration;
                      activityType = trackathon.activityType;
                      routeImage = ""; // To be filled by client
                      rank = ?rank;
                    };

                    let updatedParticipant : Types.TrackathonParticipant = {
                      principal = participant.principal;
                      username = participant.username;
                      startedAt = participant.startedAt;
                      totalDistance = participant.totalDistance;
                      totalElevationGain = participant.totalElevationGain;
                      trackPoints = participant.trackPoints;
                      hasMintedBadge = true;
                    };
                    participants.put(msg.caller, updatedParticipant);
                    #ok(badge);
                  };
                };
              };
            };
          };
        };
      };
    };
  };

  public shared (msg) func updateTrackathon(trackathonId : Text, updates : Types.NewTrackathon) : async Result.Result<Types.Trackathon, Text> {
    if (Principal.isAnonymous(msg.caller)) {
      return #err("Anonymous users cannot update trackathons");
    };

    switch (trackathons.get(trackathonId)) {
      case null { #err("Trackathon not found") };
      case (?trackathon) {
        if (trackathon.createdBy != msg.caller) {
          return #err("Only the creator can update a trackathon");
        };

        let updatedTrackathon : Types.Trackathon = {
          id = trackathon.id;
          name = updates.name;
          description = updates.description;
          startTime = updates.startTime;
          endTime = updates.endTime;
          duration = updates.duration;
          activityType = updates.activityType;
          groupId = updates.groupId;
          registrations = trackathon.registrations;
          createdBy = trackathon.createdBy;
          createdAt = trackathon.createdAt;
        };

        trackathons.put(trackathonId, updatedTrackathon);
        #ok(updatedTrackathon);
      };
    };
  };

  //==========================================================
  // migration
  //==========================================================

  public query func getListCounts() : async {
    checkpoints : Nat;
    tracks : Nat;
    trails : Nat;
    photos : Nat;
    incidentPoints : Nat;
  } {
    {
      checkpoints = List.size(checkpoints);
      tracks = List.size(tracks);
      trails = List.size(trails);
      photos = List.size(photos);
      incidentPoints = List.size(incidentPoints);
    };
  };

};
