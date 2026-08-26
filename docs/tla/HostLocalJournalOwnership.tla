-------------------- MODULE HostLocalJournalOwnership --------------------
EXTENDS FiniteSets, Naturals

\* This model isolates the distributed boundary that JournalLifecycle does
\* not expand: journal/checkpoint artifacts are shared, while active and
\* retained preference values and advisory locks are indexed by host.

CONSTANTS
    Hosts, Host1, Host2,
    JournalIDs, Journal1, Journal2,
    RootIDs, Root1,
    CheckpointIDs, InitialCheckpoint,
    None

ASSUME
    /\ IsFiniteSet(Hosts)
    /\ IsFiniteSet(JournalIDs)
    /\ IsFiniteSet(RootIDs)
    /\ IsFiniteSet(CheckpointIDs)
    /\ {Host1, Host2} \subseteq Hosts
    /\ Host1 # Host2
    /\ {Journal1, Journal2} \subseteq JournalIDs
    /\ Journal1 # Journal2
    /\ Root1 \in RootIDs
    /\ InitialCheckpoint \in CheckpointIDs
    /\ None \notin Hosts
    /\ None \notin JournalIDs
    /\ None \notin RootIDs
    /\ None \notin CheckpointIDs

VARIABLE state

vars == <<state>>

Instances == JournalIDs \X RootIDs
HostInstances == Hosts \X JournalIDs \X RootIDs
HostReceipts == Hosts \X CheckpointIDs
ReceiptMembers == Hosts \X CheckpointIDs \X JournalIDs
RetainedRecords == Hosts \X JournalIDs \X RootIDs \X CheckpointIDs
DeletionRecords == Hosts \X JournalIDs \X RootIDs \X CheckpointIDs

ActiveFor(host, journal, root) == <<host, journal, root>>

HostOwnsJournal(host, journal, root) ==
    \/ ActiveFor(host, journal, root) \in state.syncedActiveClaims
    \/ \E checkpoint \in CheckpointIDs:
        <<host, journal, root, checkpoint>> \in state.syncedRetainedClaims

OtherHostHasActiveClaim(host, journal, root) ==
    \E other \in Hosts \ {host}:
        ActiveFor(other, journal, root) \in state.syncedActiveClaims

Init ==
    state = [
        files |-> {},
        usedJournalIDs |-> {},
        createdBy |-> [instance \in Instances |-> None],
        syncedHeaders |-> {},
        locks |-> {},
        activeClaims |-> {},
        syncedActiveClaims |-> {},
        retainedClaims |-> {},
        syncedRetainedClaims |-> {},
        usedCheckpointIDs |-> {InitialCheckpoint},
        receipts |-> {},
        receiptMembers |-> {},
        qualifiedReceipts |-> {},
        deletionPending |-> {},
        deleted |-> {},
        deletionWitnesses |-> {},
        activeRemovalWitnesses |-> {},
        claimRemovalWitnesses |-> {}
        ]

AcquireHostLocalLock(host, root) ==
    /\ host \in Hosts
    /\ root \in RootIDs
    /\ <<host, root>> \notin state.locks
    /\ state' = [state EXCEPT !.locks = @ \cup {<<host, root>>}]

CreateExclusiveJournal(host, journal, root) ==
    /\ <<host, root>> \in state.locks
    /\ journal \in JournalIDs \ state.usedJournalIDs
    /\ <<journal, root>> \notin state.files
    /\ state' = [state EXCEPT
        !.files = @ \cup {<<journal, root>>},
        !.usedJournalIDs = @ \cup {journal},
        !.createdBy[<<journal, root>>] = host
        ]

SynchronizeHeader(host, journal, root) ==
    /\ <<host, root>> \in state.locks
    /\ <<journal, root>> \in state.files
    /\ state.createdBy[<<journal, root>>] = host
    /\ state' = [state EXCEPT
        !.syncedHeaders = @ \cup {<<journal, root>>}
        ]

PublishActiveClaim(host, journal, root) ==
    /\ <<host, root>> \in state.locks
    /\ <<journal, root>> \in state.syncedHeaders
    /\ state.createdBy[<<journal, root>>] = host
    /\ ~\E otherJournal \in JournalIDs:
        ActiveFor(host, otherJournal, root) \in state.activeClaims
    /\ state' = [state EXCEPT
        !.activeClaims = @ \cup {ActiveFor(host, journal, root)},
        !.syncedActiveClaims = @ \ {ActiveFor(host, journal, root)}
        ]

SynchronizeActiveClaim(host, journal, root) ==
    /\ ActiveFor(host, journal, root) \in state.activeClaims
    /\ state' = [state EXCEPT
        !.syncedActiveClaims = @ \cup {ActiveFor(host, journal, root)}
        ]

InstallCheckpointReceipt(host, checkpoint, members) ==
    /\ host \in Hosts
    /\ checkpoint \in CheckpointIDs \ state.usedCheckpointIDs
    /\ members \subseteq JournalIDs
    /\ \A journal \in members:
        \E root \in RootIDs: HostOwnsJournal(host, journal, root)
    /\ state' = [state EXCEPT
        !.usedCheckpointIDs = @ \cup {checkpoint},
        !.receipts = @ \cup {<<host, checkpoint>>},
        !.receiptMembers = @ \cup
            {<<host, checkpoint, journal>>: journal \in members}
        ]

PublishRetainedClaim(host, journal, root, checkpoint) ==
    /\ <<host, root>> \in state.locks
    /\ ActiveFor(host, journal, root) \in state.syncedActiveClaims
    /\ <<host, checkpoint>> \in state.receipts
    /\ <<host, checkpoint, journal>> \in state.receiptMembers
    /\ state' = [state EXCEPT
        !.retainedClaims =
            {claim \in @:
                ~(/\ claim[1] = host
                  /\ claim[2] = journal
                  /\ claim[3] = root)}
                \cup {<<host, journal, root, checkpoint>>},
        !.syncedRetainedClaims =
            {claim \in @:
                ~(/\ claim[1] = host
                  /\ claim[2] = journal
                  /\ claim[3] = root)}
        ]

SynchronizeRetainedClaim(host, journal, root, checkpoint) ==
    /\ <<host, journal, root, checkpoint>> \in state.retainedClaims
    /\ state' = [state EXCEPT
        !.syncedRetainedClaims = @ \cup
            {<<host, journal, root, checkpoint>>}
        ]

RemoveDemotedActiveClaim(host, journal, root, checkpoint) ==
    /\ ActiveFor(host, journal, root) \in state.syncedActiveClaims
    /\ <<host, journal, root, checkpoint>>
        \in state.syncedRetainedClaims
    /\ state' = [state EXCEPT
        !.activeClaims = @ \ {ActiveFor(host, journal, root)},
        !.syncedActiveClaims = @ \ {ActiveFor(host, journal, root)},
        !.activeRemovalWitnesses = @ \cup
            {<<host, journal, root,
               <<host, journal, root, checkpoint>>
                   \in state.syncedRetainedClaims>>}
        ]

QualifyReceipt(host, checkpoint) ==
    /\ <<host, checkpoint>> \in state.receipts
    /\ state' = [state EXCEPT
        !.qualifiedReceipts = @ \cup {<<host, checkpoint>>}
        ]

DeleteOwnedCoveredJournal(host, journal, root, checkpoint) ==
    /\ <<host, root>> \in state.locks
    /\ <<journal, root>> \in state.files
    /\ HostOwnsJournal(host, journal, root)
    /\ <<host, checkpoint>> \in state.qualifiedReceipts
    /\ <<host, checkpoint, journal>> \in state.receiptMembers
    /\ state' = [state EXCEPT
        !.files = @ \ {<<journal, root>>},
        !.syncedHeaders = @ \ {<<journal, root>>},
        !.deletionPending = @ \cup
            {<<host, journal, root, checkpoint>>},
        !.deleted = @ \cup {<<journal, root>>},
        !.deletionWitnesses = @ \cup
            {<<host, journal, root, checkpoint,
               HostOwnsJournal(host, journal, root),
               <<host, checkpoint>> \in state.qualifiedReceipts,
               <<host, checkpoint, journal>> \in state.receiptMembers,
               ~OtherHostHasActiveClaim(host, journal, root)>>}
        ]

ClearDeletedHostClaim(host, journal, root, checkpoint) ==
    /\ <<host, journal, root, checkpoint>> \in state.deletionPending
    /\ <<journal, root>> \notin state.files
    /\ state' = [state EXCEPT
            !.activeClaims = @ \ {ActiveFor(host, journal, root)},
            !.syncedActiveClaims = @ \ {ActiveFor(host, journal, root)},
            !.retainedClaims =
                {claim \in @:
                    ~(/\ claim[1] = host
                      /\ claim[2] = journal
                      /\ claim[3] = root)},
            !.syncedRetainedClaims =
                {claim \in @:
                    ~(/\ claim[1] = host
                      /\ claim[2] = journal
                      /\ claim[3] = root)},
            !.deletionPending = @ \
                {<<host, journal, root, checkpoint>>},
            !.claimRemovalWitnesses = @ \cup
                {<<host, journal, root,
                   <<journal, root>> \notin state.files>>}
           ]

CrashHost(host) ==
    /\ host \in Hosts
    /\ state' = [state EXCEPT
        !.locks = {lock \in @: lock[1] # host},
        !.activeClaims = {claim \in @:
            claim[1] # host \/ claim \in state.syncedActiveClaims},
        !.retainedClaims = {claim \in @:
            claim[1] # host \/ claim \in state.syncedRetainedClaims},
        !.receipts = {receipt \in @: receipt[1] # host},
        !.receiptMembers = {member \in @: member[1] # host},
        !.qualifiedReceipts = {receipt \in @: receipt[1] # host},
        !.deletionPending = {pending \in @: pending[1] # host}
        ]

OtherHostClaimsUnchanged(host) ==
    \A other \in Hosts \ {host}:
        /\ {claim \in state'.activeClaims: claim[1] = other}
            = {claim \in state.activeClaims: claim[1] = other}
        /\ {claim \in state'.syncedActiveClaims: claim[1] = other}
            = {claim \in state.syncedActiveClaims: claim[1] = other}
        /\ {claim \in state'.retainedClaims: claim[1] = other}
            = {claim \in state.retainedClaims: claim[1] = other}
        /\ {claim \in state'.syncedRetainedClaims: claim[1] = other}
            = {claim \in state.syncedRetainedClaims: claim[1] = other}

HostAction(host) ==
    \/ \E root \in RootIDs:
        AcquireHostLocalLock(host, root)
    \/ \E journal \in JournalIDs, root \in RootIDs:
        CreateExclusiveJournal(host, journal, root)
        \/ SynchronizeHeader(host, journal, root)
        \/ PublishActiveClaim(host, journal, root)
        \/ SynchronizeActiveClaim(host, journal, root)
    \/ \E checkpoint \in CheckpointIDs, members \in SUBSET JournalIDs:
        InstallCheckpointReceipt(host, checkpoint, members)
    \/ \E journal \in JournalIDs, root \in RootIDs,
          checkpoint \in CheckpointIDs:
        PublishRetainedClaim(host, journal, root, checkpoint)
        \/ SynchronizeRetainedClaim(host, journal, root, checkpoint)
        \/ RemoveDemotedActiveClaim(host, journal, root, checkpoint)
        \/ DeleteOwnedCoveredJournal(host, journal, root, checkpoint)
        \/ ClearDeletedHostClaim(host, journal, root, checkpoint)
    \/ \E checkpoint \in CheckpointIDs:
        QualifyReceipt(host, checkpoint)
    \/ CrashHost(host)

Next == \E host \in Hosts: HostAction(host)

Spec ==
    /\ Init
    /\ [][Next]_vars

TypeOK ==
    /\ state.files \subseteq Instances
    /\ state.usedJournalIDs \subseteq JournalIDs
    /\ state.createdBy \in [Instances -> Hosts \cup {None}]
    /\ state.syncedHeaders \subseteq Instances
    /\ state.locks \subseteq Hosts \X RootIDs
    /\ state.activeClaims \subseteq HostInstances
    /\ state.syncedActiveClaims \subseteq HostInstances
    /\ state.retainedClaims \subseteq RetainedRecords
    /\ state.syncedRetainedClaims \subseteq RetainedRecords
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.receipts \subseteq HostReceipts
    /\ state.receiptMembers \subseteq ReceiptMembers
    /\ state.qualifiedReceipts \subseteq HostReceipts
    /\ state.deletionPending \subseteq DeletionRecords
    /\ state.deleted \subseteq Instances
    /\ state.deletionWitnesses \subseteq
        (Hosts \X JournalIDs \X RootIDs \X CheckpointIDs
            \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.activeRemovalWitnesses \subseteq
        (Hosts \X JournalIDs \X RootIDs \X BOOLEAN)
    /\ state.claimRemovalWitnesses \subseteq
        (Hosts \X JournalIDs \X RootIDs \X BOOLEAN)

ClaimsRemainHostLocalToTheirCreator ==
    /\ \A claim \in state.activeClaims:
        state.createdBy[<<claim[2], claim[3]>>] = claim[1]
    /\ \A claim \in state.retainedClaims:
        state.createdBy[<<claim[2], claim[3]>>] = claim[1]

OneActiveJournalPerHostRoot ==
    \A host \in Hosts, root \in RootIDs:
        Cardinality({claim \in state.syncedActiveClaims:
            /\ claim[1] = host
            /\ claim[3] = root}) <= 1

DemotionRemovesActiveOnlyAfterRetainedSync ==
    \A witness \in state.activeRemovalWitnesses: witness[4]

DeletionRequiresSameHostQualifiedCoverage ==
    \A witness \in state.deletionWitnesses:
        /\ witness[5]
        /\ witness[6]
        /\ witness[7]

NoOtherHostsActiveJournalIsDeleted ==
    \A witness \in state.deletionWitnesses: witness[8]

ClaimRemovalFollowsDeletion ==
    \A witness \in state.claimRemovalWitnesses:
        witness[4]

HostActionsPreserveOtherHostClaims ==
    [][\A host \in Hosts:
        HostAction(host) => OtherHostClaimsUnchanged(host)]_vars

JournalIDsAreNeverReused ==
    Cardinality(state.usedJournalIDs) =
        Cardinality({instance \in Instances:
            state.createdBy[instance] # None})

=============================================================================
