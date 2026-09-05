----------------------- MODULE ExternalRecoveryBridge -----------------------
EXTENDS Integers, FiniteSets
\* IMPORT-01/DUR-01/DELETE-01, Protocol: pending-file commit/recovery.
\* Same retained observation -> reserved operation -> complete local object ->
\* private pin -> peer reduction -> settlement, with two arbitrary local crashes.
\* A=1 is initially retained. B=2 can replace the file/preview independently.
\* Association edits a known birth; Import creates it. A concurrent Delete of a
\* not-yet-created unknown birth is NOT modeled as a legitimate command.
\* Neutral association has no new history. Current bytes/physical tokens and
\* complete envelope validation are finite inputs, not an Apple/codec proof.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","clobberLatest","earlyCleanup","earlyPin",
 "liveOnlyLookup","replayConsent","staleReceipt","dropAdmitted","dropNewPreview","reviveLink"}
 /\ Scenario \in {"import","covered","concurrent","neutral"}
Hosts == {1,2}
Ops == {"g","I","D","J"}
Neutral == Scenario="neutral"
Deps(o) == CASE o="g" -> {} [] o="I" -> {"g"}
 [] o="D" -> IF Scenario \in {"import","covered"} THEN {"g","I"} ELSE {"g"}
 [] OTHER -> {"g"}
RECURSIVE Close(_, _)
Close(h,n) == IF n=0 THEN h ELSE Close({o \in h: Deps(o) \subseteq h},n-1)
Closed(h) == Close(h,4)
View(h) == [body |-> IF "D" \in h THEN 0 ELSE IF "I" \in h \/ Scenario#"import" THEN 1 ELSE 0,
 conflict |-> IF Scenario="concurrent" /\ {"I","D"} \subseteq h THEN 1 ELSE 0,
 duplicate |-> "J" \in h]
InitialMeta == [pin |-> {"g"}, latest |-> 1, reserved |-> FALSE,
 link |-> FALSE, settled |-> FALSE]
Refs(m) == ({m.latest} \ {0}) \cup IF m.reserved /\ ~m.settled THEN {1} ELSE {}
VARIABLE s
vars == <<s>>
Init == s=[objects |-> [h \in Hosts |-> {"g"}], peerPin |-> {"g"},
 applied |-> [h \in Hosts |-> {"g"}], views |-> [h \in Hosts |-> View({"g"})],
 provider |-> {"g"}, peerInbox |-> {}, deleteMade |-> FALSE,
 meta |-> InitialMeta, disk |-> InitialMeta, expected |-> InitialMeta,
 draft |-> InitialMeta, metadataPhase |-> "idle", purpose |-> "none",
 payloads |-> {1}, newWritten |-> FALSE, file |-> 1, observedB |-> FALSE,
 missing |-> FALSE, root |-> 0, frame |-> -1, consent |-> FALSE,
 claim |-> FALSE, receiptActive |-> FALSE, pending |-> FALSE,
 stage |-> 0, ack |-> FALSE, everAdmitted |-> FALSE, neutralAdmitted |-> FALSE,
 down |-> FALSE, crashes |-> 0, recovered |-> 0, staleRejected |-> FALSE,
 installedCut |-> FALSE, settledCut |-> FALSE]
FileChanges == /\ ~s.observedB /\ s.file=1
 /\ s'=[s EXCEPT !.file=2]
WritePreview == /\ ~s.down /\ s.file=2 /\ ~s.newWritten
 /\ s'=[s EXCEPT !.newWritten=TRUE]
RetainPreviewBytes == /\ s.newWritten /\ 2 \notin s.payloads
 /\ s'=[s EXCEPT !.payloads=@ \cup {2}]
\* Another caller can finish a reference update after a main caller PREPARES,
\* but not while that same serialized writer has an uncertain named replacement.
CommitPreview == /\ ~s.down /\ 2 \in s.payloads /\ ~s.observedB
 /\ s.metadataPhase#"named"
 /\ s'=[s EXCEPT !.meta.latest=2, !.disk.latest=2, !.observedB=TRUE]
Disappear == /\ s.file#0 /\ ~s.missing
 /\ s'=[s EXCEPT !.file=0, !.missing=TRUE]
ChangeRoot == /\ s.root=0 /\ s'=[s EXCEPT !.root=1, !.receiptActive=FALSE]
Observe == /\ ~s.down /\ s.file=1 /\ s.root=0 /\ s.frame#s.root
 /\ s'=[s EXCEPT !.frame=s.root]
Approve == /\ ~s.down /\ s.frame=s.root /\ s.file=1 /\ ~s.consent
 /\ "D" \notin s.applied[1] /\ ~s.meta.settled /\ ~s.pending
 /\ s'=[s EXCEPT !.consent=TRUE]
PrepareMetadata(kind) ==
 /\ s.metadataPhase="idle"
 /\ CASE kind="reserve" -> ~s.down /\ s.consent /\ ~s.meta.reserved
      [] kind="pin" -> ~(Closed(s.objects[1]) \subseteq s.meta.pin)
      [] kind="settle" -> ~s.down /\ ~s.meta.settled
           /\ IF Neutral THEN s.neutralAdmitted /\ s.file=1 /\ s.frame=s.root
                    /\ s.claim /\ "D" \notin s.applied[1]
              ELSE "I" \in s.meta.pin
      [] OTHER -> FALSE
 /\ LET next == CASE kind="reserve" -> [s.meta EXCEPT !.reserved=TRUE]
       [] kind="pin" -> [s.meta EXCEPT !.pin=Closed(s.objects[1]),
                          !.link=(~s.meta.settled \/ Policy="reviveLink")
                                  /\ (@ \/ "I" \in s.objects[1])]
       [] OTHER -> [s.meta EXCEPT !.settled=TRUE, !.link=FALSE,
                  !.latest=IF @=1 \/ Policy="dropNewPreview" THEN 0 ELSE @]
    IN s'=[s EXCEPT !.expected=s.meta, !.draft=next,
                         !.metadataPhase="prepared", !.purpose=kind]
InstallMetadata == /\ s.metadataPhase="prepared"
 /\ (s.expected=s.meta \/ Policy="clobberLatest")
 /\ s'=[s EXCEPT !.disk=s.draft, !.metadataPhase="named"]
RejectMetadata == /\ s.metadataPhase="prepared" /\ s.expected#s.meta
 /\ s'=[s EXCEPT !.metadataPhase="idle", !.staleRejected=TRUE]
SyncMetadata == /\ s.metadataPhase="named"
 /\ s'=[s EXCEPT !.meta=s.disk, !.metadataPhase="idle",
     !.receiptActive=IF s.purpose="settle" /\
        (Policy="staleReceipt" \/ (s.file=1 /\ s.frame=s.root /\ s.claim
          /\ "D" \notin s.applied[1])) THEN TRUE ELSE @]
Admit == /\ ~s.down /\ s.meta.reserved /\ ~s.meta.settled /\ ~s.pending
 /\ "I" \notin s.objects[1] /\ ~s.neutralAdmitted
 /\ ((s.consent /\ s.file=1 /\ s.frame=s.root /\ "D" \notin s.applied[1])
      \/ (Policy="replayConsent" /\ s.recovered>0))
 /\ s'=[s EXCEPT !.pending=~Neutral, !.neutralAdmitted=Neutral,
     !.everAdmitted=TRUE, !.claim=TRUE, !.consent=FALSE,
     !.views[1]=View(IF Neutral THEN s.applied[1] ELSE s.applied[1] \cup {"I"})]
WriteGroup == /\ ~s.down /\ s.pending /\ s.stage=0
 /\ s'=[s EXCEPT !.stage=1]
SyncGroup == /\ ~s.down /\ s.stage=1 /\ s'=[s EXCEPT !.stage=2]
InstallGroupName == /\ ~s.down /\ s.stage=2 /\ s'=[s EXCEPT !.stage=3]
SyncGroupDirectory == /\ ~s.down /\ s.stage=3
 /\ s'=[s EXCEPT !.stage=4, !.objects[1]=@ \cup {"I"}]
PrematurePin == /\ Policy="earlyPin" /\ s.stage=2
 /\ s'=[s EXCEPT !.meta.pin=@ \cup {"I"}, !.disk.pin=@ \cup {"I"}, !.ack=TRUE]
AcceptLocal == /\ ~s.down /\ "I" \in s.meta.pin /\ ~s.ack
 /\ s'=[s EXCEPT !.ack=TRUE, !.pending=FALSE,
     !.applied[1]=@ \cup {"I"}, !.views[1]=View(s.applied[1] \cup {"I"})]
Publish == /\ ~(s.meta.pin \subseteq s.provider)
 /\ s'=[s EXCEPT !.provider=@ \cup s.meta.pin]
ReceivePeer(o) == /\ o \in s.provider \ s.objects[2]
 /\ s'=[s EXCEPT !.objects[2]=@ \cup {o}, !.peerInbox=@ \cup {o}]
PinPeer == /\ ~(Closed(s.objects[2]) \subseteq s.peerPin)
 /\ s'=[s EXCEPT !.peerPin=Closed(s.objects[2])]
ApplyPeer == /\ s.applied[2]#s.peerPin
 /\ s'=[s EXCEPT !.applied[2]=s.peerPin, !.views[2]=View(s.peerPin)]
RemoteDelete == /\ ~s.deleteMade /\ Deps("D") \subseteq s.applied[2]
 /\ (Scenario="concurrent" => "I" \notin s.applied[2])
 /\ s'=[s EXCEPT !.deleteMade=TRUE, !.objects[2]=@ \cup {"D"}]
ReceiveDelete == /\ "D" \in s.peerPin /\ "D" \notin s.objects[1]
 /\ s'=[s EXCEPT !.objects[1]=@ \cup {"D"}]
ApplyDelete == /\ ~s.down /\ "D" \in s.meta.pin /\ "D" \notin s.applied[1]
 /\ s'=[s EXCEPT !.applied[1]=@ \cup {"D"}, !.claim=FALSE, !.receiptActive=FALSE,
    !.pending=IF Policy="dropAdmitted" THEN FALSE ELSE @,
    !.views[1]=View(s.applied[1] \cup {"D"} \cup IF s.pending THEN {"I"} ELSE {})]
\* Cleanup considers both metadata outcomes plus the admitted live input.
Collect(v) == /\ v \in s.payloads /\ ~s.down
 /\ v \notin Refs(s.disk)
 /\ (v \notin Refs(s.meta) \/ Policy="earlyCleanup")
 /\ ~(v=1 /\ (s.pending \/ s.consent)) /\ ~(v=2 /\ s.newWritten /\ ~s.observedB)
 /\ s'=[s EXCEPT !.payloads=@ \ {v}]
Crash(m,keepName) == /\ ~s.down /\ s.crashes<2
 /\ m \in {s.meta,s.disk} /\ keepName \in BOOLEAN
 /\ s'=[s EXCEPT !.down=TRUE, !.crashes=@+1, !.meta=m, !.disk=m,
    !.installedCut=@ \/ (s.crashes=0 /\ ~s.meta.settled /\ ~s.ack
                    /\ ("I" \in s.objects[1] \/ (s.stage=3 /\ keepName))),
    !.settledCut=@ \/ (s.crashes=1 /\ s.meta.settled /\ "D" \in s.applied[1]),
    !.objects[1]=IF s.stage=3 /\ keepName THEN @ \cup {"I"} ELSE @,
    !.metadataPhase="idle", !.stage=0, !.pending=FALSE, !.consent=FALSE,
    !.claim=FALSE, !.receiptActive=FALSE, !.frame=-1, !.neutralAdmitted=FALSE,
    !.applied[1]={}, !.views[1]=View({})]
Recover == /\ s.down /\ Closed(s.objects[1])=s.meta.pin
 /\ s'=[s EXCEPT !.down=FALSE, !.recovered=@+1,
                 !.applied[1]=s.meta.pin, !.views[1]=View(s.meta.pin)]
RepeatScan == /\ ~s.down /\ s.recovered>0 /\ s.file=1
 /\ "I" \in s.meta.pin /\ "D" \in s.applied[1]
 /\ Policy="liveOnlyLookup" /\ "J" \notin s.objects[1]
 /\ s'=[s EXCEPT !.objects[1]=@ \cup {"J"}]
Next == FileChanges \/ WritePreview \/ RetainPreviewBytes \/ CommitPreview
 \/ Disappear \/ ChangeRoot \/ Observe \/ Approve \/ InstallMetadata
 \/ RejectMetadata \/ SyncMetadata \/ Admit \/ WriteGroup \/ SyncGroup
 \/ InstallGroupName \/ SyncGroupDirectory \/ PrematurePin \/ AcceptLocal
 \/ Publish \/ PinPeer \/ ApplyPeer \/ RemoteDelete \/ ReceiveDelete \/ ApplyDelete
 \/ Recover \/ RepeatScan
 \/ (\E k \in {"reserve","pin","settle"}: PrepareMetadata(k))
 \/ (\E o \in Ops: ReceivePeer(o)) \/ (\E v \in {1,2}: Collect(v))
 \/ (\E m \in {s.meta,s.disk}, keep \in BOOLEAN: Crash(m,keep))
Spec == Init /\ [][Next]_vars
FairSpec == Spec \* Action-safety configurations add no progress assumption.
MetaType == [pin:SUBSET Ops,latest:0..2,reserved:BOOLEAN,link:BOOLEAN,settled:BOOLEAN]
TypeOK == /\ s.objects \in [Hosts -> SUBSET Ops] /\ s.applied \in [Hosts -> SUBSET Ops]
 /\ \A m \in {s.meta,s.disk,s.expected,s.draft}: m \in MetaType
 /\ s.payloads \subseteq {1,2} /\ s.crashes \in 0..2 /\ s.recovered \in 0..2
 /\ s.stage \in 0..4 /\ s.file \in 0..2 /\ s.root \in 0..1
ReferencesHaveBytes == Refs(s.meta) \cup Refs(s.disk) \subseteq s.payloads
LatestRetained == s.observedB => 2 \in s.payloads /\ s.meta.latest=2
PinHasClosure == s.meta.pin \subseteq Closed(s.objects[1])
 /\ s.peerPin \subseteq Closed(s.objects[2])
AcknowledgedRecoverable == s.ack => "I" \in Closed(s.objects[1])
NoRepeatedImport == "J" \notin s.objects[1]
NeutralHasNoEcho == Neutral => "I" \notin UNION {s.objects[h]:h \in Hosts}
SettledLinkStaysTransferred == s.meta.settled => ~s.meta.link
DeletedBirthAbsent == \A h \in Hosts: "D" \in s.applied[h] => s.views[h].body=0
ConcurrentValueSurvives == Scenario="concurrent" => \A h \in Hosts:
 {"I","D"} \subseteq s.applied[h] => s.views[h].conflict=1
CoveredValueIsHistory == Scenario \in {"covered","import"} => \A h \in Hosts:
 "D" \in s.applied[h] => s.views[h].conflict=0
Safety == ReferencesHaveBytes /\ LatestRetained /\ PinHasClosure
 /\ AcknowledgedRecoverable /\ NoRepeatedImport /\ NeutralHasNoEcho
 /\ DeletedBirthAbsent /\ ConcurrentValueSurvives /\ CoveredValueIsHistory
 /\ SettledLinkStaysTransferred
AdmissionNeedsFreshDecision == [][(~s.pending /\ s'.pending) \/
 (~s.neutralAdmitted /\ s'.neutralAdmitted) =>
 s.consent /\ s.file=1 /\ s.frame=s.root /\ "D" \notin s.applied[1]]_vars
ReceiptNeedsCurrentAuthority == [][~s.receiptActive /\ s'.receiptActive =>
 s.file=1 /\ s.frame=s.root /\ s.claim /\ "D" \notin s.applied[1]]_vars
DeleteCannotCancelAdmission == [][s.pending /\ ~s'.pending /\ ~s'.down =>
 "I" \in s'.meta.pin]_vars
NeverRecoveredDeletedImport == ~(Scenario="import" /\ s.recovered=2
 /\ s.installedCut /\ s.settledCut
 /\ s.meta.settled /\ {"I","D"} \subseteq s.applied[1] /\ s.views[1].body=0)
NeverKeptNewPreview == ~(s.recovered=2 /\ s.observedB /\ s.meta.settled
 /\ s.installedCut /\ s.settledCut
 /\ {"I","D"} \subseteq s.applied[1] /\ 2 \in s.payloads)
NeverSettledNeutral == ~(Neutral /\ s.meta.settled /\ s.receiptActive
 /\ s.objects[1]={"g"})
NeverRejectedStaleMetadata == ~s.staleRejected
=============================================================================
