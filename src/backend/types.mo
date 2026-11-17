import Time "mo:base/Time";
import Principal "mo:base/Principal";

module {

    public type TrackType = {
        #hike;        
        #run;
        #bike;
        #drive;
        #fly;
        #ski;
        #paddle;
        #climb;
        #travel;
        #other;
    };

    public type ActivityType = {
        #hiking;
        #running;
        #cycling;
        #rowing;
        #track;
    };
    public type TrailType = {
        #tloop;
        #outandback;
        #pointto;
    };

    public type Difficulty = {
        #easy;
        #moderate;
        #hard;
        #expert;
    };

    public type Severity = {
        #low;
        #medium;
        #high;
        #critical;
    };

    public type IncidentCategory = {
        #hazard;
        #obstacle;
        #wildlife;
        #weather;
        #other;
    };

    public type Point = {
        latitude : Float;
        longitude : Float;
    };

    public type TrackFile = {
        fileType : Text;
        url : Text;
    };
    public type TrailFile = {
        fileType : Text;
        url : Text;
    };

    public type NewTrail = {
        name : Text;
        description : Text;
        distance : Float;
        elevationGain : Float;
        duration : Float;
        trailfile : TrailFile;
        ttype : TrailType;
        difficulty : Difficulty;
        tags : [Text];
        rate : Float;
        photos : [Text];
        startPoint : Point;
    };

    public type UpdateTrail = {
        name : Text;
        description : Text;
        distance : Float;
        elevationGain : Float;
        duration : Float;
        trailfile : TrailFile;
        ttype : TrailType;
        difficulty : Difficulty;
        tags : [Text];
        rate : Float;
        photos : [Text];
        startPoint : Point;
    };

    public type Trail = {
        id : Nat;
        name : Text;
        description : Text;
        distance : Float;
        elevationGain : Float;
        duration : Float;
        trailfile : TrailFile;
        ttype : TrailType;
        difficulty : Difficulty;
        tags : [Text];
        rate : Float;
        photos : [Text];
        createdAt : Time.Time;
        createdBy : Principal;
        startPoint : Point;
    };

    public type NewTrack = {
        id : Text;
        name : Text;
        description : Text;
        length : Float;
        elevation : Float;
        duration : Float;
        startime : Time.Time;
        isPublic : Bool;
        groupId : ?Text;
        trackfile : TrackFile;
        startPoint : Point;
        trackType : TrackType;
        
    };

    public type Track = {
        id : Text;
        name : Text;
        description : Text;
        length : Float;
        elevation : Float;
        duration : Float;
        startime : Time.Time;
        createdBy : Principal;
        isPublic : Bool;
        groupId : ?Text;
        trackfile : TrackFile;
        startPoint : Point;
        trackType : TrackType;
    };

    public type NewCheckPoint = {
        trackId : Text;
        groupId : ?Text;
        latitude : Float;
        longitude : Float;
        elevation : Float;
        note : Text;
        photo : ?Text;
        timestamp : Time.Time;
        isPublic : Bool;
    };

    public type CheckPoint = {
        trackId : Text;
        groupId : ?Text;
        latitude : Float;
        longitude : Float;
        elevation : Float;
        note : Text;
        photo : ?Text;
        timestamp : Time.Time;
        isPublic : Bool;
        createdBy : Principal;
    };

    public type NewGroup = {
        id : Text;
        name : Text;
        description : Text;
        members : [Principal];
        admin : Principal;
        badge : Text;
    };

    public type Group = {
        id : Text;
        name : Text;
        description : Text;
        members : [Principal];
        admin : Principal;
        badge : Text;
        createdAt : Time.Time;
        createdBy : Principal;
    };

    public type UserStats = {
        id : Text;
        firstHikeDate : Time.Time;
        totalDistance : Float;
        totalHours : Float;
        totalElevation : Float;
        completedTrails : Nat;
    };

    public type Photo = {
        trackId : Text;
        groupId : ?Text;
        tags : [Text];
        photoUrl : Text;
        timestamp : Time.Time;
        createdBy : Principal;
    };

    // Add to types.mo
    public type NewIncidentPoint = {
        trackId : Text;
        groupId : ?Text;
        latitude : Float;
        longitude : Float;
        elevation : Float;
        note : Text;
        photo : ?Text;
        timestamp : Time.Time;
        severity : Severity;
        category : IncidentCategory;
    };

    public type IncidentPoint = {
        trackId : Text;
        groupId : ?Text;
        latitude : Float;
        longitude : Float;
        elevation : Float;
        note : Text;
        photo : ?Text;
        timestamp : Time.Time;
        severity : Severity;
        category : IncidentCategory;
        createdBy : Principal;
    };

    public type SavedPoint = {
        description : Text;
        latitude : Float;
        longitude : Float;
        category : Text;

        createdBy : Principal;
        createdAt : Time.Time;
    };

    // Spot: a named location with optional description and tags (original shape)
    public type NewSpot = {
        name : Text;
        description : Text;
        tags : [Text];
    };

    // Original Spot shape (kept for compatibility during migration)
    public type Spot = {
        name : Text;
        description : Text;
        tags : [Text];
        createdBy : Principal;
        createdAt : Time.Time;
    };

    // New SpotV2 with numeric id
    public type SpotV2 = {
        id : Nat;
        name : Text;
        description : Text;
        tags : [Text];
        createdBy : Principal;
        createdAt : Time.Time;
    };

    public type NewSavedPoint = {
        description : Text;
        latitude : Float;
        longitude : Float;
        category : Text;
    };

    public type UserCredential = {
        credentialId : Text; // Base64 encoded rawId
        publicKey : Text; // Base64 encoded verification key
        createdAt : Int; // Timestamp in nanoseconds
        encryptedWallet : {
            iv : [Nat8]; // Initialization vector
            data : [Nat8]; // Encrypted wallet data
        };
    };
    public type CheckpointComment = {
        checkpointTimestamp : Time.Time;
        checkpointCreatedBy : Principal;
        comment : Text;
        photo : ?Text;
        timestamp : Time.Time;
        createdBy : Principal;
    };

    // Common comment types that can target either a checkpoint (trackpoint) or a spot
    public type CommentTarget = {
        #checkpoint : {
            checkpointTimestamp : Time.Time;
            checkpointCreatedBy : Principal;
        };
        #spot : Nat; // spot id
    };

    public type NewComment = {
        target : CommentTarget;
        comment : Text;
        photo : ?Text;
        timestamp : Time.Time;
    };

    public type Comment = {
        id : Nat; // numeric id assigned by canister
        target : CommentTarget;
        comment : Text;
        photo : ?Text;
        timestamp : Time.Time;
        createdBy : Principal;
    };

    // Trackathon types
    public type TrackathonPoint = {
        lat : Float;
        lng : Float;
        elevation : ?Float;
        timestamp : Time.Time;
        note : ?Text;
    };

    public type TrackathonParticipant = {
        principal : Principal;
        username : Text;
        startedAt : ?Time.Time;
        totalDistance : Float;
        totalElevationGain : Float;
        trackPoints : [TrackathonPoint];
        hasMintedBadge : Bool;
    };

    public type NewTrackathon = {
        name : Text;
        description : Text;
        startTime : Time.Time;
        endTime : Time.Time;
        duration : Float;
        activityType : ActivityType;
        groupId : ?Text;
    };

    public type Trackathon = {
        id : Text;
        name : Text;
        description : Text;
        startTime : Time.Time;
        endTime : Time.Time;
        duration : Float;
        activityType : ActivityType;
        groupId : ?Text;
        registrations : [Principal];
        createdBy : Principal;
        createdAt : Time.Time;
    };

    public type TrackathonBadge = {
        trackathonId : Text;
        trackathonName : Text;
        participantPrincipal : Principal;
        participantName : Text;
        completionDate : Time.Time;
        distance : Float;
        elevationGain : Float;
        duration : Float;
        activityType : ActivityType;
        routeImage : Text;
        rank : ?Nat;
    };

};
