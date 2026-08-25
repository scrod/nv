# Separate WAL durability from provider work

NV will keep WAL append/synchronization on a serial durability lane separate from the serial provider lane used for coordinated scans, materialization, note-file mutations, and checkpoints. Provider work may block for network access, but it must not block the UI or delay local journal durability.

Each opened directory has one root session incarnation that owns its rooted-directory reference, provider lane, presenter, cancellation state, and reconciliation dirty bit. Detached reconciliation transactions take an exact provider fence over the provider catalog token and persistent version identifier set, validate note-content and structural generations, and may commit only while that same root session incarnation remains active. Late completions from a replaced or closing incarnation are discarded without a separate global generation counter.
