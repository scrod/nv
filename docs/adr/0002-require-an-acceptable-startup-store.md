# Require an acceptable complete startup store

Status: accepted.

NV publishes the editable live store only from complete, exactly identified local evidence. It first coordinates and classifies the canonical `Notes & Settings`; a provider-current, materialized, decodable checkpoint may be accepted directly. It then scans `NSApplicationSupportDirectory/Notational Velocity/Recovery Journals` and the selected root's legacy exact-name WAL, positively associates every matching artifact with the root, recovers or proves represented every valid record, installs any required recovery checkpoint, and creates and synchronizes one fresh host-local WAL. Noncanonical or historical checkpoint versions are not startup inputs.

When checkpoint materialization fails, **Work Offline** is available only if complete checkpoint bytes and every matching local or legacy WAL are readable and recoverable. Otherwise the user may retry, quit, or choose another directory. NV never exposes a partially recovered read-only store.

Neither `ENOENT` nor an apparently empty selected directory creates a collection implicitly. Silent initialization is limited to a directory NV exclusively created in the current new-collection operation; every preexisting directory requires explicit **Create a New Notes Collection Here** and expected-absence revalidation in the checkpoint transaction. If no acceptable checkpoint can produce a store, **Rebuild from Note Files** uses one stable current-visible double-catalog snapshot of direct-child note files, explicit extension decoding or Ignore choices, and an all-or-nothing detached reconstruction. Provider-managed rebuild targets plaintext; outside that contract, uniform recognized input retains its format and mixed recognized input requires an explicit target format plus detached conversion. Rebuild installs and verifies the new checkpoint before creating the fresh WAL or enabling editing. A concurrent appearance, changed catalog, ambiguity, or unreadable input restarts or fails without publication.

Normative requirements: `AUTH-01`, `START-01`, `WAIT-01`, `CKPT-01`.
