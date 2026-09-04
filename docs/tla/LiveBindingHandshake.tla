------------------------ MODULE LiveBindingHandshake ------------------------
EXTENDS Naturals, FiniteSets, Sequences
\* EXPERIMENT. Two host-local endpoints; item numbers are hidden transport
\* routing/ground truth, NOT portable provider IDs available to the decision.
\* A packet is <<fresh attempt nonce, challenge/reply/ack stage>>. The finite
\* nonce abstraction assumes collision-free issuance. Old transcripts remain
\* deliverable. Metadata copy/restore can ferry even fresh packets.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"tag", "reusedNonce", "challenge", "fenced", "defer"}
ASSUME Scenario \in {"clean", "copy", "retarget", "relay", "stale", "offline"}
Hosts == {1,2}
Items == {1,2}
Packet(n,k) == <<n,k>>
Packets == {Packet(n,k): n \in 1..2, k \in 1..3}
Nonce == IF Policy = "reusedNonce" THEN 1 ELSE 2
InitialEndpoint == IF Scenario \in {"copy","relay","stale"} THEN 2 ELSE 1
VARIABLE b
vars == <<b>>
InitialState == [endpoint |-> InitialEndpoint, handle |-> 20 + InitialEndpoint, anchor |-> 0,
 phaseA |-> 0, phaseB |-> 0, accepted |-> FALSE, parked |-> FALSE,
 acceptedEndpoint |-> 0, acceptedHandle |-> 0, acceptedAnchor |-> 0, moved |-> FALSE, relays |-> {},
 offers |-> [i \in Items |-> {Packet(1,1),Packet(1,2),Packet(1,3)}],
 view |-> [h \in Hosts |-> [i \in Items |-> Packet(1,3)]]]
Init == b = InitialState
Running == ~b.accepted /\ ~b.parked
Matches(h,i,k) == b.view[h][i][1] = Nonce /\ b.view[h][i][2] >= k
SendChallenge ==
 /\ Running /\ Policy \notin {"tag","defer"} /\ b.phaseA = 0
 /\ b' = [b EXCEPT !.phaseA = 1,
    !.offers[1] = @ \cup {Packet(Nonce,1)}, !.view[1][1] = Packet(Nonce,1)]
ObserveChallenge ==
 /\ Running /\ Policy \notin {"tag","defer"} /\ b.phaseB = 0
 /\ Matches(2,b.endpoint,1)
 /\ b' = [b EXCEPT !.phaseB = 1, !.anchor = b.handle]
SendReply ==
 /\ Running /\ b.phaseB = 1
 /\ b' = [b EXCEPT !.phaseB = 2,
    !.offers[b.endpoint] = @ \cup {Packet(Nonce,2)},
    !.view[2][b.endpoint] = Packet(Nonce,2)]
ObserveReply ==
 /\ Running /\ b.phaseA = 1 /\ Matches(1,1,2)
 /\ b' = [b EXCEPT !.phaseA = 2]
SendAck ==
 /\ Running /\ b.phaseA = 2
 /\ b' = [b EXCEPT !.phaseA = 3,
    !.offers[1] = @ \cup {Packet(Nonce,3)}, !.view[1][1] = Packet(Nonce,3)]
ObserveAck ==
 /\ Running /\ b.phaseB = 2 /\ Matches(2,b.endpoint,3)
 /\ b' = [b EXCEPT !.phaseB = 3]
Accept ==
 /\ Running
 /\ (Policy = "tag" \/ b.phaseB = 3)
 /\ (Policy # "fenced" \/ b.anchor = b.handle)
 /\ b' = [b EXCEPT !.accepted = TRUE, !.phaseB = 4,
      !.acceptedEndpoint = b.endpoint, !.acceptedHandle = b.handle, !.acceptedAnchor = b.anchor]
Deliver(h,i,p) ==
 /\ Scenario # "offline" /\ p \in b.offers[i] /\ b.view[h][i] # p
 /\ b' = [b EXCEPT !.view[h][i] = p]
\* One ordinary copy/reassociation can occur after ANY protocol step,
\* including after reading the ack and before publishing the alias.
CopyAndRetarget ==
 /\ Running /\ Scenario = "retarget" /\ ~b.moved
 /\ b' = [b EXCEPT !.endpoint = 2, !.handle = 22, !.moved = TRUE,
      !.offers[2] = @ \cup {b.view[2][1]}, !.view[2][2] = b.view[2][1]]
\* Three explicit metadata transplants, not spontaneous cross-item provider
\* delivery. This is a separate, stronger environment than an ordinary copy.
Relay(k) ==
 /\ Running /\ Scenario = "relay" /\ k \in 1..3 /\ k \notin b.relays
 /\ LET from == IF k = 2 THEN 2 ELSE 1
        to == IF k = 2 THEN 1 ELSE 2
        host == IF k = 2 THEN 1 ELSE 2
        p == Packet(Nonce,k)
    IN /\ p \in b.offers[from]
       /\ b' = [b EXCEPT !.relays = @ \cup {k},
           !.offers[to] = @ \cup {p}, !.view[host][to] = p]
Park ==
 /\ Running /\ (Scenario # "clean" \/ Policy = "defer")
 /\ b' = [b EXCEPT !.parked = TRUE]
Protocol == SendChallenge \/ ObserveChallenge \/ SendReply \/ ObserveReply
 \/ SendAck \/ ObserveAck \/ Accept
Next == Protocol \/ CopyAndRetarget \/ Park \/ (\E k \in 1..3: Relay(k))
 \/ (\E h \in Hosts, i \in Items, p \in Packets: Deliver(h,i,p))
Spec == Init /\ [][Next]_vars
\* Progress only under a stable endpoint and eventual latest-packet delivery.
\* No claim that arbitrary iCloud histories supply this delivery contract.
Latest(i) == CHOOSE p \in b.offers[i]:
 \A q \in b.offers[i]: p[1]*4+p[2] >= q[1]*4+q[2]
LatestDelivery == \E h \in Hosts, i \in Items: Deliver(h,i,Latest(i))
FairSpec == Init /\ [][Protocol \/ LatestDelivery \/ Park]_vars
 /\ WF_vars(SendChallenge) /\ WF_vars(ObserveChallenge) /\ WF_vars(SendReply)
 /\ WF_vars(ObserveReply) /\ WF_vars(SendAck) /\ WF_vars(ObserveAck)
 /\ WF_vars(Accept) /\ WF_vars(Park)
 /\ \A h \in Hosts, i \in Items: WF_vars(Deliver(h,i,Latest(i)))
TypeOK ==
 /\ b.endpoint \in Items /\ b.handle \in {21,22} /\ b.anchor \in {0,21,22}
 /\ b.phaseA \in 0..3 /\ b.phaseB \in 0..4
 /\ b.accepted \in BOOLEAN /\ b.parked \in BOOLEAN /\ b.moved \in BOOLEAN
 /\ b.acceptedEndpoint \in 0..2 /\ b.acceptedHandle \in {0,21,22} /\ b.acceptedAnchor \in {0,21,22}
 /\ b.relays \subseteq 1..3 /\ b.offers \in [Items -> SUBSET Packets]
 /\ b.view \in [Hosts -> [Items -> Packets]]
NoFalseBinding == b.accepted => b.acceptedEndpoint = 1
NoStaleEndpointPublication == b.accepted /\ Policy # "tag" =>
 b.acceptedAnchor = b.acceptedHandle
EventuallyBound == <>b.accepted
EventuallyFinished == <>(b.accepted \/ b.parked)
NeverBound == ~b.accepted
NeverParked == ~b.parked
NeverBoundAfterRelay == ~(b.accepted /\ b.relays = {1,2,3})
NeverCopiedAfterAck == ~(b.moved /\ b.phaseB = 3 /\ ~b.accepted)
=============================================================================
