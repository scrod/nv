# Keep the database name and limit epoch-4 recovery

Modern NV will keep the canonical `Notes & Settings` filename and add only backward-readable checkpoint identity fields, leaving the provider to retain simultaneous database writes as recovery versions. Until an unchanged epoch-4 checkpoint receives a random identity on its next verified modern save, a new journal identifies its base as a tagged SHA-256 digest of the exact loaded checkpoint bytes. If legacy and modern journals coexist, modern NV recovers and checkpoints the legacy exact-name journal first, then evaluates its active modern journal against that replacement checkpoint.

Epoch 4 must read a clean modern checkpoint, but after a modern crash the user must launch modern NV to recover its uniquely named WAL; NV will not maintain a hard-link, clone, or copied legacy WAL alias because epoch 4 would treat it as abandoned, delete it, and create a competing writer.

Normative requirements: `START-01`, `DUR-01`.
