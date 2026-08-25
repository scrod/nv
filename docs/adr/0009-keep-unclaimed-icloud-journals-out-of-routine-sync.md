# Keep unclaimed iCloud journals out of routine synchronization

An unclaimed iCloud WAL may still have an active writer on another Mac because local file coordination and advisory locks do not cross machines. NV therefore catalogs the current file and every known local or nonlocal `NSFileVersion` fork as recovery evidence without normally materializing, replaying, appending to, resolving, or deleting them. Explicit recovery snapshots persistent version identifiers, validates each journal's complete prefix, and preserves otherwise-missing or differing states as deterministic nondeletion conflict notes. It never deletes or resolves evidence while a remote writer may still be active.

Ordinary local backup restoration may automatically recover one unambiguous journal-recovery-eligible candidate while holding the directory lock; modern journals do not add an inode lock. Partial or incomplete version enumeration preserves evidence and cannot declare recovery complete.
