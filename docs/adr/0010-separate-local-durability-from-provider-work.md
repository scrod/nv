# Separate local durability from provider work

Status: accepted.

One serial local lane encodes/seals, installs history, recovers and maintains required private state and derived current rows. One provider/root lane owns coordination, discovery/materialization, projections and status. Neither provider waiting nor detached bulk reduction may starve urgent local note barriers. Main-thread admission/publication uses immutable worker results, exact root/store/structural/note generations; synchronous live search is unchanged.

LocalDurabilityLaneIndependence checks per-admitted-edit progress with no provider fairness. It proves neither concrete segment bytes nor OS durability. One root presenter plus scoped directory discovery/FSEvents/vnode hints schedules work; callbacks acknowledge accommodation/relinquishment promptly and exactly once, never supply completeness.

Positive same-root movement retains the owner. Positive authority change fences a provisional successor; missing paths, revoke, stale bookmarks and failed provider lookup leave continuity unknown. No reverse File Provider lookup/domain enumeration or automatic root-loss classification. Unknown provider classification does not erase independent rooted/generic-file evidence or force a vendor mode.

Provider uncertainty pauses provider effects; healthy positively associated private history remains editable. Generic provider unavailability needs status, not a Work Offline choice. Work Offline is offered only when newer/required provider evidence is positively disclosed but its exact bytes are unmaterialized or unreadable, and it grants no overwrite or absence inference. It bypasses an already-disclosed-evidence startup wait only; disclosure after editing begins cannot close admission or demand the choice. Local-store ownership/association/key/barrier uncertainty selects its independent admission reason. Retry uses the current session's existing positive object evidence; explicit Re-open selects and validates a new root association, while Save As constructs a new repository before an optional switch. Either may end an unavailable session without deleting its history. Outstanding operations retain resources until safely completed/fenced.

Normative requirements: AUTH-01, DUR-01, ROOT-01, PUB-01, WAIT-01.
