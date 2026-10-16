# Source and support-file coverage

Every project-owned validation file under the inventoried roots appears here. Helpers, fixtures, fault hooks and process drivers support executable checks; they are not individually counted as test declarations. Vendored upstream suites and generated build products are outside this project-owned index.

| Source | Role | Catalogue entries | Referencing runners/sources |
| --- | --- | ---: | --- |
| [NVStorage/Tests/NVStorageCoreTests/BootstrapDescriptorTests.swift](../../NVStorage/Tests/NVStorageCoreTests/BootstrapDescriptorTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageCoreTests/CanonicalPrimitivesTests.swift](../../NVStorage/Tests/NVStorageCoreTests/CanonicalPrimitivesTests.swift) | executable definitions | 7 |  |
| [NVStorage/Tests/NVStorageCoreTests/CausalUndoQueryTests.swift](../../NVStorage/Tests/NVStorageCoreTests/CausalUndoQueryTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/ChangesPayloadV1Tests.swift](../../NVStorage/Tests/NVStorageCoreTests/ChangesPayloadV1Tests.swift) | executable definitions | 11 |  |
| [NVStorage/Tests/NVStorageCoreTests/ConnectedRecordTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ConnectedRecordTests.swift) | executable definitions | 2 |  |
| [NVStorage/Tests/NVStorageCoreTests/ConservativeMergeTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ConservativeMergeTests.swift) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/CurrentRowFrameTests.swift](../../NVStorage/Tests/NVStorageCoreTests/CurrentRowFrameTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/CurrentStateTests.swift](../../NVStorage/Tests/NVStorageCoreTests/CurrentStateTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageCoreTests/DerivedStateTests.swift](../../NVStorage/Tests/NVStorageCoreTests/DerivedStateTests.swift) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/ExtendedCurrentCodecTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ExtendedCurrentCodecTests.swift) | executable definitions | 2 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/connected-records.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/connected-records.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/current-cell-v2.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/current-cell-v2.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/current-state.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/current-state.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/derived-state.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/derived-state.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/descriptors.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/descriptors.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/envelopes.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/envelopes.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/general-snapshot.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/general-snapshot.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/initial-bootstrap.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/initial-bootstrap.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/initial-snapshot.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/initial-snapshot.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/merge.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/merge.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/private-current-dictionary.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/private-current-dictionary.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/private-current-frame.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/private-current-frame.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/private-records.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/private-records.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-descriptor.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-descriptor.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-filename.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-filename.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-observations.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-observations.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-stamp.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-stamp.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-text-output.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-text-output.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-transport.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-transport.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/Fixtures/restoration.json](../../NVStorage/Tests/NVStorageCoreTests/Fixtures/restoration.json) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageCoreTests/FrontierUpdateTests.swift](../../NVStorage/Tests/NVStorageCoreTests/FrontierUpdateTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageCoreTests/GeneralSnapshotTests.swift](../../NVStorage/Tests/NVStorageCoreTests/GeneralSnapshotTests.swift) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/InitialBootstrapValidationTests.swift](../../NVStorage/Tests/NVStorageCoreTests/InitialBootstrapValidationTests.swift) | executable definitions | 16 | [test-bootstrap-mutations.py](../../tools/test-bootstrap-mutations.py), [test-storage-apple-peer.py](../../tools/test-storage-apple-peer.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py), [test-zstd-mutations.py](../../tools/test-zstd-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/InitialSnapshotTests.swift](../../NVStorage/Tests/NVStorageCoreTests/InitialSnapshotTests.swift) | executable definitions | 2 |  |
| [NVStorage/Tests/NVStorageCoreTests/ObjectEnvelopeTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ObjectEnvelopeTests.swift) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-zstd-mutations.py](../../tools/test-zstd-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/OperationV1Tests.swift](../../NVStorage/Tests/NVStorageCoreTests/OperationV1Tests.swift) | executable definitions | 9 |  |
| [NVStorage/Tests/NVStorageCoreTests/PlaintextNoteValueTests.swift](../../NVStorage/Tests/NVStorageCoreTests/PlaintextNoteValueTests.swift) | executable definitions | 4 |  |
| [NVStorage/Tests/NVStorageCoreTests/PrivateRecordTests.swift](../../NVStorage/Tests/NVStorageCoreTests/PrivateRecordTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageCoreTests/ProjectionDescriptorTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ProjectionDescriptorTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/ProjectionFilenameTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ProjectionFilenameTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/ProjectionObservationTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ProjectionObservationTests.swift) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/ProjectionStampTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ProjectionStampTests.swift) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/ProjectionTextOutputTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ProjectionTextOutputTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/ProjectionTransportTests.swift](../../NVStorage/Tests/NVStorageCoreTests/ProjectionTransportTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageCoreTests/RecoveryArtifactsTests.swift](../../NVStorage/Tests/NVStorageCoreTests/RecoveryArtifactsTests.swift) | executable definitions | 3 | [check-recovery-artifact-fixtures.py](../../tools/check-recovery-artifact-fixtures.py) |
| [NVStorage/Tests/NVStorageCoreTests/RestorationCodecTests.swift](../../NVStorage/Tests/NVStorageCoreTests/RestorationCodecTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageCoreTests/SettlementRecordTests.swift](../../NVStorage/Tests/NVStorageCoreTests/SettlementRecordTests.swift) | executable definitions | 3 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/ActorAcceptanceTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ActorAcceptanceTests.swift) | executable definitions | 1 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/BootstrapReconstructionTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/BootstrapReconstructionTests.swift) | executable definitions | 9 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/BootstrapStoreTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/BootstrapStoreTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/CollectionBootstrapTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CollectionBootstrapTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/CollectionCopySwitchTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CollectionCopySwitchTests.swift) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/CollectionStartupTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CollectionStartupTests.swift) | executable definitions | 13 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/CollectionStartupWorkTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CollectionStartupWorkTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/CollectionWaitTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CollectionWaitTests.swift) | executable definitions | 11 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/CommandSchedulingTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CommandSchedulingTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/CompensationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CompensationTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ConnectedCommandTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ConnectedCommandTests.swift) | executable definitions | 2 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/ConnectedEdgeTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ConnectedEdgeTests.swift) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ConnectedSemanticsTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ConnectedSemanticsTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ConnectedValidationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ConnectedValidationTests.swift) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ConnectionReuseTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ConnectionReuseTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/CurrentBasisTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CurrentBasisTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/CurrentBasisWorkTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CurrentBasisWorkTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/CurrentRowStorageTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CurrentRowStorageTests.swift) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/CurrentStartupBenchmarkTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/CurrentStartupBenchmarkTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/DatabaseBoundaryTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/DatabaseBoundaryTests.swift) | executable definitions | 6 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/GeneralSnapshotRuntimeTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/GeneralSnapshotRuntimeTests.swift) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/GrowthHistoryFixtureTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/GrowthHistoryFixtureTests.swift) | executable definitions | 3 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/HistoryReadBenchmark.swift](../../NVStorage/Tests/NVStorageRuntimeTests/HistoryReadBenchmark.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/HistoryReaderReferenceTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/HistoryReaderReferenceTests.swift) | executable definitions | 2 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/HistorySchedulingTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/HistorySchedulingTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/HistoryTraversalTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/HistoryTraversalTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/MaintenanceTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/MaintenanceTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/MergePreviewTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/MergePreviewTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/MixedRecoveryTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/MixedRecoveryTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/NativeCoverageTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/NativeCoverageTests.swift) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/NoteHistoryTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/NoteHistoryTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/OptionalStartupTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/OptionalStartupTests.swift) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/OrdinaryValidationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/OrdinaryValidationTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/PendingSettlementTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/PendingSettlementTests.swift) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/Phase3BoundaryTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/Phase3BoundaryTests.swift) | executable definitions | 3 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/Phase5ConnectedTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/Phase5ConnectedTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/PrivateBackupTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/PrivateBackupTests.swift) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/PrivateRepairTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/PrivateRepairTests.swift) | executable definitions | 12 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/PrivateStateTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/PrivateStateTests.swift) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionDeletionInputTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionDeletionInputTests.swift) | executable definitions | 33 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionFileCreationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionFileCreationTests.swift) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionFileReadTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionFileReadTests.swift) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionFileReplacementTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionFileReplacementTests.swift) | executable definitions | 17 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionHistoryTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionHistoryTests.swift) | executable definitions | 9 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionObservationRuntimeTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionObservationRuntimeTests.swift) | executable definitions | 18 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionProducerTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionProducerTests.swift) | executable definitions | 11 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionReplacementInputTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionReplacementInputTests.swift) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ProjectionTransportRuntimeTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ProjectionTransportRuntimeTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ReceiveIsolationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ReceiveIsolationTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ReceivedSnapshotTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ReceivedSnapshotTests.swift) | executable definitions | 14 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RecoveryWorkReferenceTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RecoveryWorkReferenceTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/RejectedDependencyTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RejectedDependencyTests.swift) | executable definitions | 1 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryAvailabilityTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryAvailabilityTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryBatchTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryBatchTests.swift) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryBootstrapExchangeTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryBootstrapExchangeTests.swift) | executable definitions | 2 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryCoordinationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryCoordinationTests.swift) | executable definitions | 10 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryCopyTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryCopyTests.swift) | executable definitions | 12 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryDiscoveryAnalysisTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryDiscoveryAnalysisTests.swift) | executable definitions | 2 | [benchmark-storage-discovery-work.py](../../tools/benchmark-storage-discovery-work.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryDiscoveryVariantTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryDiscoveryVariantTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryExchangeFailureTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryExchangeFailureTests.swift) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryExchangeLifecycleTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryExchangeLifecycleTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryExchangeTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryExchangeTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryFilesTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryFilesTests.swift) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryInventoryTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryInventoryTests.swift) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryListingTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryListingTests.swift) | executable definitions | 2 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryPublicationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryPublicationTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryRepairTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryRepairTests.swift) | executable definitions | 23 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryRootTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryRootTests.swift) | executable definitions | 18 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryScanBenchmarkTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryScanBenchmarkTests.swift) | executable definitions | 1 | [benchmark-storage-directory-scan.py](../../tools/benchmark-storage-directory-scan.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RepositoryTransportTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RepositoryTransportTests.swift) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RestorationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RestorationTests.swift) | executable definitions | 5 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RetentionTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RetentionTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ReviewRegressionTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ReviewRegressionTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/RuntimeSchedulesTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/RuntimeSchedulesTests.swift) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/SavedActionTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/SavedActionTests.swift) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/ScopedHistoryTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ScopedHistoryTests.swift) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/SharedBootstrapEnvelopeTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/SharedBootstrapEnvelopeTests.swift) | executable definitions | 1 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/SnapshotAcceptanceTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/SnapshotAcceptanceTests.swift) | executable definitions | 9 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/SnapshotRetentionTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/SnapshotRetentionTests.swift) | executable definitions | 10 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/StorageHealthTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/StorageHealthTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/StorageReviewTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/StorageReviewTests.swift) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/StoreSelectionTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/StoreSelectionTests.swift) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/SynchronousHistoryReference.swift](../../NVStorage/Tests/NVStorageRuntimeTests/SynchronousHistoryReference.swift) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/TypedBoundaryTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/TypedBoundaryTests.swift) | executable definitions | 3 |  |
| [NVStorage/Tests/NVStorageRuntimeTests/ValidationResumptionTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/ValidationResumptionTests.swift) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/NVStorageRuntimeTests/VerificationTests.swift](../../NVStorage/Tests/NVStorageRuntimeTests/VerificationTests.swift) | executable definitions | 13 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) |
| [NVStorage/Tests/Support/CStorageFaults/NVStorageFaults.c](../../NVStorage/Tests/Support/CStorageFaults/NVStorageFaults.c) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/Support/CStorageFaults/include/NVStorageFaults.h](../../NVStorage/Tests/Support/CStorageFaults/include/NVStorageFaults.h) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/Support/NVStorageProbe/CollectionControllerProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/CollectionControllerProbe.swift) | executable definitions | 17 |  |
| [NVStorage/Tests/Support/NVStorageProbe/CollectionStartupProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/CollectionStartupProbe.swift) | executable definitions | 5 |  |
| [NVStorage/Tests/Support/NVStorageProbe/CurrentMaintenanceProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/CurrentMaintenanceProbe.swift) | executable definitions | 3 |  |
| [NVStorage/Tests/Support/NVStorageProbe/PrivateProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/PrivateProbe.swift) | executable definitions | 19 |  |
| [NVStorage/Tests/Support/NVStorageProbe/Probe.swift](../../NVStorage/Tests/Support/NVStorageProbe/Probe.swift) | executable definitions | 42 | [SQLCipherRecoveryProbe.swift](../../tests/SQLCipherRecoveryProbe.swift), [run-sqlcipher-variation-probe.py](../../tests/run-sqlcipher-variation-probe.py), [test-actor-database.py](../../tools/prototypes/test-actor-database.py) |
| [NVStorage/Tests/Support/NVStorageProbe/RepositoryCopyProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/RepositoryCopyProbe.swift) | executable definitions | 5 |  |
| [NVStorage/Tests/Support/NVStorageProbe/RepositoryDriverProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/RepositoryDriverProbe.swift) | executable definitions | 17 |  |
| [NVStorage/Tests/Support/NVStorageProbe/RepositoryExchangeProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/RepositoryExchangeProbe.swift) | executable definitions | 3 |  |
| [NVStorage/Tests/Support/NVStorageProbe/RepositoryFilesProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/RepositoryFilesProbe.swift) | executable definitions | 3 |  |
| [NVStorage/Tests/Support/NVStorageProbe/RepositoryRootProbe.swift](../../NVStorage/Tests/Support/NVStorageProbe/RepositoryRootProbe.swift) | executable definitions | 18 |  |
| [NVStorage/Tests/Support/NVStorageTestSupport/Fixtures.swift](../../NVStorage/Tests/Support/NVStorageTestSupport/Fixtures.swift) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/Support/NVStorageTestSupport/GrowthHistory.swift](../../NVStorage/Tests/Support/NVStorageTestSupport/GrowthHistory.swift) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/Support/NVStorageTestSupport/ProjectionNativeFixtures.swift](../../NVStorage/Tests/Support/NVStorageTestSupport/ProjectionNativeFixtures.swift) | fixture / support / build prerequisite | 0 |  |
| [NVStorage/Tests/Support/NVStorageTestSupport/Resources/ProjectionFilesSyncFault.c](../../NVStorage/Tests/Support/NVStorageTestSupport/Resources/ProjectionFilesSyncFault.c) | executable definitions | 4 |  |
| [build.sh](../../build.sh) | executable definitions | 1 | [run-startup-storage-comparison.py](../../tests/run-startup-storage-comparison.py), [release.sh](../../tools/release.sh) |
| [docs/tla/BindingIntentComposition.cfg](../tla/BindingIntentComposition.cfg) | executable definitions | 1 |  |
| [docs/tla/BindingIntentComposition.tla](../tla/BindingIntentComposition.tla) | executable definitions | 1 |  |
| [docs/tla/CausalIncarnationSafety.cfg](../tla/CausalIncarnationSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/CausalIncarnationSafety.tla](../tla/CausalIncarnationSafety.tla) | executable definitions | 1 |  |
| [docs/tla/CausalUndoRules.tla](../tla/CausalUndoRules.tla) | executable definitions | 1 | [check-segment-models.py](../tla/check-segment-models.py) |
| [docs/tla/CoAddIntentLab.cfg](../tla/CoAddIntentLab.cfg) | executable definitions | 1 |  |
| [docs/tla/CoAddIntentLab.tla](../tla/CoAddIntentLab.tla) | executable definitions | 1 |  |
| [docs/tla/CoAddLateHistoryLab.cfg](../tla/CoAddLateHistoryLab.cfg) | executable definitions | 1 |  |
| [docs/tla/CoAddLateHistoryLab.tla](../tla/CoAddLateHistoryLab.tla) | executable definitions | 1 |  |
| [docs/tla/CoAddRevalidationLab.cfg](../tla/CoAddRevalidationLab.cfg) | executable definitions | 1 |  |
| [docs/tla/CoAddRevalidationLab.tla](../tla/CoAddRevalidationLab.tla) | executable definitions | 1 |  |
| [docs/tla/CoAddSlotLab.cfg](../tla/CoAddSlotLab.cfg) | executable definitions | 1 |  |
| [docs/tla/CoAddSlotLab.tla](../tla/CoAddSlotLab.tla) | executable definitions | 1 |  |
| [docs/tla/CoalescedRecoverySafety.tla](../tla/CoalescedRecoverySafety.tla) | executable definitions | 1 |  |
| [docs/tla/CollectionStartupAssociationSafety.tla](../tla/CollectionStartupAssociationSafety.tla) | executable definitions | 1 | [check-collection-startup-association.py](../tla/check-collection-startup-association.py) |
| [docs/tla/CompensationOverlapBridge.cfg](../tla/CompensationOverlapBridge.cfg) | executable definitions | 1 |  |
| [docs/tla/CompensationOverlapBridge.tla](../tla/CompensationOverlapBridge.tla) | executable definitions | 1 |  |
| [docs/tla/ConcurrentUndoExecutionSafety.cfg](../tla/ConcurrentUndoExecutionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ConcurrentUndoExecutionSafety.tla](../tla/ConcurrentUndoExecutionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/CrossMachineConflictDispositionSafety.cfg](../tla/CrossMachineConflictDispositionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/CrossMachineConflictDispositionSafety.tla](../tla/CrossMachineConflictDispositionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/CurrentVisibleReconciliationSafety.cfg](../tla/CurrentVisibleReconciliationSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/CurrentVisibleReconciliationSafety.tla](../tla/CurrentVisibleReconciliationSafety.tla) | executable definitions | 1 |  |
| [docs/tla/DeletionIntentTransportSafety.cfg](../tla/DeletionIntentTransportSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/DeletionIntentTransportSafety.tla](../tla/DeletionIntentTransportSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ExternalAssociationSafety.cfg](../tla/ExternalAssociationSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ExternalAssociationSafety.tla](../tla/ExternalAssociationSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ExternalFileLifecycleSafety.cfg](../tla/ExternalFileLifecycleSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ExternalFileLifecycleSafety.tla](../tla/ExternalFileLifecycleSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ExternalImportAdmissionLab.cfg](../tla/ExternalImportAdmissionLab.cfg) | executable definitions | 1 |  |
| [docs/tla/ExternalImportAdmissionLab.tla](../tla/ExternalImportAdmissionLab.tla) | executable definitions | 1 |  |
| [docs/tla/ExternalImportPolicyLab.cfg](../tla/ExternalImportPolicyLab.cfg) | executable definitions | 1 |  |
| [docs/tla/ExternalImportPolicyLab.tla](../tla/ExternalImportPolicyLab.tla) | executable definitions | 1 | [check-segment-models.py](../tla/check-segment-models.py) |
| [docs/tla/ExternalRecoveryBridge.cfg](../tla/ExternalRecoveryBridge.cfg) | executable definitions | 1 |  |
| [docs/tla/ExternalRecoveryBridge.tla](../tla/ExternalRecoveryBridge.tla) | executable definitions | 1 |  |
| [docs/tla/ImmutableSegmentDurabilitySafety.cfg](../tla/ImmutableSegmentDurabilitySafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ImmutableSegmentDurabilitySafety.tla](../tla/ImmutableSegmentDurabilitySafety.tla) | executable definitions | 1 |  |
| [docs/tla/IntentRetirementLab.cfg](../tla/IntentRetirementLab.cfg) | executable definitions | 1 |  |
| [docs/tla/IntentRetirementLab.tla](../tla/IntentRetirementLab.tla) | executable definitions | 1 |  |
| [docs/tla/LiveBindingHandshake.cfg](../tla/LiveBindingHandshake.cfg) | executable definitions | 1 |  |
| [docs/tla/LiveBindingHandshake.tla](../tla/LiveBindingHandshake.tla) | executable definitions | 1 |  |
| [docs/tla/LocalDurabilityLaneIndependence.cfg](../tla/LocalDurabilityLaneIndependence.cfg) | executable definitions | 1 |  |
| [docs/tla/LocalDurabilityLaneIndependence.tla](../tla/LocalDurabilityLaneIndependence.tla) | executable definitions | 1 |  |
| [docs/tla/NVConflictCopySafety.cfg](../tla/NVConflictCopySafety.cfg) | executable definitions | 1 |  |
| [docs/tla/NVConflictCopySafety.tla](../tla/NVConflictCopySafety.tla) | executable definitions | 1 |  |
| [docs/tla/NativeCausalUndoBridge.tla](../tla/NativeCausalUndoBridge.tla) | executable definitions | 1 |  |
| [docs/tla/NativeUndoSpanSafety.cfg](../tla/NativeUndoSpanSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/NativeUndoSpanSafety.tla](../tla/NativeUndoSpanSafety.tla) | executable definitions | 1 |  |
| [docs/tla/OptionalReadyStartupSafety.tla](../tla/OptionalReadyStartupSafety.tla) | executable definitions | 1 |  |
| [docs/tla/PendingReferenceSafety.cfg](../tla/PendingReferenceSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/PendingReferenceSafety.tla](../tla/PendingReferenceSafety.tla) | executable definitions | 1 |  |
| [docs/tla/PortableCausalUndoSafety.cfg](../tla/PortableCausalUndoSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/PortableCausalUndoSafety.tla](../tla/PortableCausalUndoSafety.tla) | executable definitions | 1 |  |
| [docs/tla/PrivateMaintenanceSafety.tla](../tla/PrivateMaintenanceSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ProjectionRecoveryBridge.cfg](../tla/ProjectionRecoveryBridge.cfg) | executable definitions | 1 |  |
| [docs/tla/ProjectionRecoveryBridge.tla](../tla/ProjectionRecoveryBridge.tla) | executable definitions | 1 |  |
| [docs/tla/ProjectionStampSafety.cfg](../tla/ProjectionStampSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ProjectionStampSafety.tla](../tla/ProjectionStampSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ProjectionTransitionSafety.cfg](../tla/ProjectionTransitionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ProjectionTransitionSafety.tla](../tla/ProjectionTransitionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ReceiveRejectionSafety.cfg](../tla/ReceiveRejectionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ReceiveRejectionSafety.tla](../tla/ReceiveRejectionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ReceiveResumptionSafety.cfg](../tla/ReceiveResumptionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ReceiveResumptionSafety.tla](../tla/ReceiveResumptionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ReceiveSnapshotAssemblySafety.tla](../tla/ReceiveSnapshotAssemblySafety.tla) | executable definitions | 1 |  |
| [docs/tla/RepositoryAccessorDriverSafety.tla](../tla/RepositoryAccessorDriverSafety.tla) | executable definitions | 1 | [check-repository-accessor-driver.py](../tla/check-repository-accessor-driver.py) |
| [docs/tla/RepositoryCopySafety.cfg](../tla/RepositoryCopySafety.cfg) | executable definitions | 1 |  |
| [docs/tla/RepositoryCopySafety.tla](../tla/RepositoryCopySafety.tla) | executable definitions | 1 |  |
| [docs/tla/RepositoryDiscoverySafety.tla](../tla/RepositoryDiscoverySafety.tla) | executable definitions | 1 | [check-repository-discovery-model.py](../tla/check-repository-discovery-model.py) |
| [docs/tla/RepositoryMetadataBatchSafety.tla](../tla/RepositoryMetadataBatchSafety.tla) | executable definitions | 1 | [check-repository-metadata-batches.py](../tla/check-repository-metadata-batches.py) |
| [docs/tla/RepositoryRepairSafety.cfg](../tla/RepositoryRepairSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/RepositoryRepairSafety.tla](../tla/RepositoryRepairSafety.tla) | executable definitions | 1 |  |
| [docs/tla/RepositorySwitchSafety.tla](../tla/RepositorySwitchSafety.tla) | executable definitions | 1 |  |
| [docs/tla/ReviewedUndoSafety.cfg](../tla/ReviewedUndoSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/ReviewedUndoSafety.tla](../tla/ReviewedUndoSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SQLiteCollectionSafety.cfg](../tla/SQLiteCollectionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SQLiteCollectionSafety.tla](../tla/SQLiteCollectionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SQLiteFastStartSafety.cfg](../tla/SQLiteFastStartSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SQLiteFastStartSafety.tla](../tla/SQLiteFastStartSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SegmentActionRecoverySafety.cfg](../tla/SegmentActionRecoverySafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SegmentActionRecoverySafety.tla](../tla/SegmentActionRecoverySafety.tla) | executable definitions | 1 |  |
| [docs/tla/SegmentBootstrapSafety.cfg](../tla/SegmentBootstrapSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SegmentBootstrapSafety.tla](../tla/SegmentBootstrapSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SegmentDeletionOrderingSafety.cfg](../tla/SegmentDeletionOrderingSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SegmentDeletionOrderingSafety.tla](../tla/SegmentDeletionOrderingSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SegmentDeletionSafety.cfg](../tla/SegmentDeletionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SegmentDeletionSafety.tla](../tla/SegmentDeletionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SegmentMergeSafety.cfg](../tla/SegmentMergeSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SegmentMergeSafety.tla](../tla/SegmentMergeSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SeparateFileDeletionSafety.cfg](../tla/SeparateFileDeletionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SeparateFileDeletionSafety.tla](../tla/SeparateFileDeletionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SharedNoteViewOwnershipSafety.cfg](../tla/SharedNoteViewOwnershipSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/SharedNoteViewOwnershipSafety.tla](../tla/SharedNoteViewOwnershipSafety.tla) | executable definitions | 1 |  |
| [docs/tla/SnapshotReconstructionSafety.tla](../tla/SnapshotReconstructionSafety.tla) | executable definitions | 1 | [check-reconstruction-model.py](../tla/check-reconstruction-model.py) |
| [docs/tla/SnapshotRetentionCoverageSafety.tla](../tla/SnapshotRetentionCoverageSafety.tla) | executable definitions | 1 |  |
| [docs/tla/UUIDAssociationLab.cfg](../tla/UUIDAssociationLab.cfg) | executable definitions | 1 |  |
| [docs/tla/UUIDAssociationLab.tla](../tla/UUIDAssociationLab.tla) | executable definitions | 1 |  |
| [docs/tla/UndoHistoryHandoffSafety.cfg](../tla/UndoHistoryHandoffSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/UndoHistoryHandoffSafety.tla](../tla/UndoHistoryHandoffSafety.tla) | executable definitions | 1 |  |
| [docs/tla/UnresolvedVersionResolutionSafety.cfg](../tla/UnresolvedVersionResolutionSafety.cfg) | executable definitions | 1 |  |
| [docs/tla/UnresolvedVersionResolutionSafety.tla](../tla/UnresolvedVersionResolutionSafety.tla) | executable definitions | 1 |  |
| [docs/tla/VerificationRecoverySafety.tla](../tla/VerificationRecoverySafety.tla) | executable definitions | 1 |  |
| [docs/tla/check-collection-startup-association.py](../tla/check-collection-startup-association.py) | executable definitions | 24 |  |
| [docs/tla/check-improvement-models.py](../tla/check-improvement-models.py) | executable definitions | 61 |  |
| [docs/tla/check-receive-models.py](../tla/check-receive-models.py) | executable definitions | 63 |  |
| [docs/tla/check-reconstruction-model.py](../tla/check-reconstruction-model.py) | executable definitions | 21 |  |
| [docs/tla/check-repository-accessor-driver.py](../tla/check-repository-accessor-driver.py) | executable definitions | 18 |  |
| [docs/tla/check-repository-discovery-model.py](../tla/check-repository-discovery-model.py) | executable definitions | 16 |  |
| [docs/tla/check-repository-metadata-batches.py](../tla/check-repository-metadata-batches.py) | executable definitions | 10 |  |
| [docs/tla/check-segment-models.py](../tla/check-segment-models.py) | executable definitions | 609 |  |
| [docs/tla/check-uuid-experiments.py](../tla/check-uuid-experiments.py) | executable definitions | 473 |  |
| [tests/AgedStartupStorageComparison.m](../../tests/AgedStartupStorageComparison.m) | executable definitions | 11 | [run-startup-storage-comparison.py](../../tests/run-startup-storage-comparison.py) |
| [tests/AppearanceColorTest.m](../../tests/AppearanceColorTest.m) | executable definitions | 1 | [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/DirectoryScanBenchmark.m](../../tests/DirectoryScanBenchmark.m) | executable definitions | 1 | [benchmark-storage-directory-scan.py](../../tools/benchmark-storage-directory-scan.py) |
| [tests/Epoch4CompatibilitySmokeMain.m](../../tests/Epoch4CompatibilitySmokeMain.m) | executable definitions | 1 | [test-epoch4-v5-compatibility.sh](../../tools/test-epoch4-v5-compatibility.sh) |
| [tests/FSEventsHistoryProbe.m](../../tests/FSEventsHistoryProbe.m) | executable definitions | 1 | [CoAddRevalidationLab.tla](../tla/CoAddRevalidationLab.tla) |
| [tests/GlobalPrefsArchiveMigrationTest.m](../../tests/GlobalPrefsArchiveMigrationTest.m) | executable definitions | 7 | [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/ICloudAPIContractTest-Info.plist](../../tests/ICloudAPIContractTest-Info.plist) | fixture / support / build prerequisite | 0 |  |
| [tests/ICloudAPIContractTest.m](../../tests/ICloudAPIContractTest.m) | executable definitions | 209 | [ICloudRootLockProbe.h](../../tests/ICloudRootLockProbe.h), [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/ICloudMetadataProbe.h](../../tests/ICloudMetadataProbe.h) | executable definitions | 25 | [ICloudAPIContractTest.m](../../tests/ICloudAPIContractTest.m), [ICloudRootLockProbe.h](../../tests/ICloudRootLockProbe.h), [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/ICloudRootLockProbe.h](../../tests/ICloudRootLockProbe.h) | executable definitions | 53 | [ICloudAPIContractTest.m](../../tests/ICloudAPIContractTest.m), [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/Makefile](../../tests/Makefile) | executable definitions | 43 | [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-phase5-connected.py](../../tools/test-storage-phase5-connected.py), [update-integration-build-manifest.py](../../tools/update-integration-build-manifest.py) |
| [tests/ModernStickiesImportTest.m](../../tests/ModernStickiesImportTest.m) | executable definitions | 1 | [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/NVIntegrationTest.m](../../tests/NVIntegrationTest.m) | executable definitions | 175 | [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/NVRootedDirectoryTestHooks.h](../../tests/NVRootedDirectoryTestHooks.h) | fixture / support / build prerequisite | 0 |  |
| [tests/NVRootedDirectoryTestHooks.m](../../tests/NVRootedDirectoryTestHooks.m) | fixture / support / build prerequisite | 0 |  |
| [tests/NVStorageContract-Info.plist](../../tests/NVStorageContract-Info.plist) | fixture / support / build prerequisite | 0 |  |
| [tests/NativeUndoProbe.m](../../tests/NativeUndoProbe.m) | executable definitions | 2 |  |
| [tests/PrivateCurrentRowFixture.c](../../tests/PrivateCurrentRowFixture.c) | executable definitions | 1 |  |
| [tests/ProjectionFilesCleanupProbe.c](../../tests/ProjectionFilesCleanupProbe.c) | executable definitions | 2 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tests/ProjectionFilesCreateProbe.c](../../tests/ProjectionFilesCreateProbe.c) | executable definitions | 1 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tests/ProjectionFilesCreateProcessProbe.c](../../tests/ProjectionFilesCreateProcessProbe.c) | executable definitions | 1 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tests/ProjectionFilesPresenterProbe.m](../../tests/ProjectionFilesPresenterProbe.m) | executable definitions | 1 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tests/ProjectionFilesReadProbe.c](../../tests/ProjectionFilesReadProbe.c) | executable definitions | 1 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tests/ProjectionFilesRelocateProbe.m](../../tests/ProjectionFilesRelocateProbe.m) | executable definitions | 1 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tests/ProjectionFilesReplaceProbe.m](../../tests/ProjectionFilesReplaceProbe.m) | executable definitions | 1 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tests/ProjectionFilesSourceProbe.c](../../tests/ProjectionFilesSourceProbe.c) | executable definitions | 1 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tests/ProjectionReferenceRaceProbe.m](../../tests/ProjectionReferenceRaceProbe.m) | executable definitions | 7 |  |
| [tests/ProjectionReplacementProbe.m](../../tests/ProjectionReplacementProbe.m) | executable definitions | 1 |  |
| [tests/ProjectionTextEncodingProbe.swift](../../tests/ProjectionTextEncodingProbe.swift) | fixture / support / build prerequisite | 0 |  |
| [tests/RepositoryAppleInstallProbe.m](../../tests/RepositoryAppleInstallProbe.m) | executable definitions | 1 | [test-storage-apple-stage.py](../../tools/test-storage-apple-stage.py) |
| [tests/RepositoryCoordinationPeer.m](../../tests/RepositoryCoordinationPeer.m) | executable definitions | 2 | [test-storage-apple-peer.py](../../tools/test-storage-apple-peer.py) |
| [tests/RepositoryDiscoveryBatchBenchmark.c](../../tests/RepositoryDiscoveryBatchBenchmark.c) | executable definitions | 1 | [benchmark-storage-discovery-work.py](../../tools/benchmark-storage-discovery-work.py) |
| [tests/RepositoryFilesIOProbe.c](../../tests/RepositoryFilesIOProbe.c) | executable definitions | 14 | [test-storage-coordinated-install.py](../../tools/test-storage-coordinated-install.py), [test-storage-immutable-files.py](../../tools/test-storage-immutable-files.py), [test-storage-immutable-mutations.py](../../tools/test-storage-immutable-mutations.py), [test-storage-immutable-volumes.py](../../tools/test-storage-immutable-volumes.py) |
| [tests/RepositoryMetadataProbe.c](../../tests/RepositoryMetadataProbe.c) | executable definitions | 11 | [test-storage-metadata-batches.py](../../tools/test-storage-metadata-batches.py) |
| [tests/RepositoryRepairReplacementProbe.m](../../tests/RepositoryRepairReplacementProbe.m) | executable definitions | 3 | [test-storage-repair-replacement-capability.py](../../tools/test-storage-repair-replacement-capability.py) |
| [tests/RepositoryRootIOProbe.c](../../tests/RepositoryRootIOProbe.c) | executable definitions | 4 | [test-storage-root-c.py](../../tools/test-storage-root-c.py) |
| [tests/SQLCipherColdStartProbe.c](../../tests/SQLCipherColdStartProbe.c) | executable definitions | 1 | [test-sqlcipher-cold-start.py](../../tools/test-sqlcipher-cold-start.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/SQLCipherKeyWrappingProbe.swift](../../tests/SQLCipherKeyWrappingProbe.swift) | fixture / support / build prerequisite | 0 |  |
| [tests/SQLCipherRecoveryProbe.swift](../../tests/SQLCipherRecoveryProbe.swift) | fixture / support / build prerequisite | 0 |  |
| [tests/SQLCipherVariationProbe.c](../../tests/SQLCipherVariationProbe.c) | executable definitions | 10 | [SQLCipherRecoveryProbe.swift](../../tests/SQLCipherRecoveryProbe.swift), [run-sqlcipher-variation-probe.py](../../tests/run-sqlcipher-variation-probe.py) |
| [tests/SQLMaintenanceInterpose.h](../../tests/SQLMaintenanceInterpose.h) | fixture / support / build prerequisite | 0 |  |
| [tests/SQLMaintenancePrivacyProbe.c](../../tests/SQLMaintenancePrivacyProbe.c) | executable definitions | 1 | [test-sql-maintenance-privacy.py](../../tools/test-sql-maintenance-privacy.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/SQLMaintenanceProbe.c](../../tests/SQLMaintenanceProbe.c) | executable definitions | 1 | [test-sql-maintenance.py](../../tools/test-sql-maintenance.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/SQLiteCollectionProtocolProbe.c](../../tests/SQLiteCollectionProtocolProbe.c) | executable definitions | 8 | [SQLiteCollectionSafety.tla](../tla/SQLiteCollectionSafety.tla), [run-sqlite-collection-protocol.py](../../tests/run-sqlite-collection-protocol.py), [run-sqlite-fast-start-contract.py](../../tests/run-sqlite-fast-start-contract.py) |
| [tests/SQLiteLocalStoreProbe.c](../../tests/SQLiteLocalStoreProbe.c) | executable definitions | 11 | [SQLiteCollectionSafety.tla](../tla/SQLiteCollectionSafety.tla), [AgedStartupStorageComparison.m](../../tests/AgedStartupStorageComparison.m), [SQLCipherRecoveryProbe.swift](../../tests/SQLCipherRecoveryProbe.swift), [SQLCipherVariationProbe.c](../../tests/SQLCipherVariationProbe.c), [SQLiteCollectionProtocolProbe.c](../../tests/SQLiteCollectionProtocolProbe.c), [StartupStorageComparison.m](../../tests/StartupStorageComparison.m), [run-sqlcipher-variation-probe.py](../../tests/run-sqlcipher-variation-probe.py), [run-sqlite-collection-protocol.py](../../tests/run-sqlite-collection-protocol.py), [run-sqlite-fast-start-contract.py](../../tests/run-sqlite-fast-start-contract.py), [run-sqlite-local-store-probe.py](../../tests/run-sqlite-local-store-probe.py), [run-startup-storage-comparison.py](../../tests/run-startup-storage-comparison.py) |
| [tests/StartupStorageComparison.m](../../tests/StartupStorageComparison.m) | executable definitions | 3 | [AgedStartupStorageComparison.m](../../tests/AgedStartupStorageComparison.m), [run-startup-storage-comparison.py](../../tests/run-startup-storage-comparison.py) |
| [tests/StorageSwiftTestingLauncher.c](../../tests/StorageSwiftTestingLauncher.c) | executable definitions | 1 | [benchmark-storage-discovery-variants.py](../../tools/benchmark-storage-discovery-variants.py) |
| [tests/WebArchiveImportIntegrationTest.m](../../tests/WebArchiveImportIntegrationTest.m) | executable definitions | 1 | [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tests/ZstdDictionaryContracts.h](../../tests/ZstdDictionaryContracts.h) | fixture / support / build prerequisite | 0 |  |
| [tests/ZstdDictionaryExperiment.h](../../tests/ZstdDictionaryExperiment.h) | fixture / support / build prerequisite | 0 |  |
| [tests/fixtures/LegacyEncryptedNotesDatabase.base64](../../tests/fixtures/LegacyEncryptedNotesDatabase.base64) | fixture / support / build prerequisite | 0 |  |
| [tests/fixtures/LegacyUnencryptedNotesDatabase.base64](../../tests/fixtures/LegacyUnencryptedNotesDatabase.base64) | fixture / support / build prerequisite | 0 |  |
| [tests/run-incarnation-experiments.py](../../tests/run-incarnation-experiments.py) | executable definitions | 26 |  |
| [tests/run-sqlcipher-variation-probe.py](../../tests/run-sqlcipher-variation-probe.py) | executable definitions | 9 | [SQLCipherRecoveryProbe.swift](../../tests/SQLCipherRecoveryProbe.swift) |
| [tests/run-sqlite-collection-protocol.py](../../tests/run-sqlite-collection-protocol.py) | executable definitions | 115 | [run-sqlite-fast-start-contract.py](../../tests/run-sqlite-fast-start-contract.py) |
| [tests/run-sqlite-fast-start-contract.py](../../tests/run-sqlite-fast-start-contract.py) | executable definitions | 22 |  |
| [tests/run-sqlite-local-store-probe.py](../../tests/run-sqlite-local-store-probe.py) | executable definitions | 7 |  |
| [tests/run-sqlite-schema-contract.py](../../tests/run-sqlite-schema-contract.py) | executable definitions | 20 |  |
| [tests/run-startup-storage-comparison.py](../../tests/run-startup-storage-comparison.py) | executable definitions | 5 |  |
| [tests/sqlcipher-sanitizer-probe.c](../../tests/sqlcipher-sanitizer-probe.c) | executable definitions | 1 | [test-storage-sanitizers.py](../../tools/test-storage-sanitizers.py) |
| [tools/benchmark-storage-directory-scan.py](../../tools/benchmark-storage-directory-scan.py) | executable definitions | 2 |  |
| [tools/benchmark-storage-discovery-variants.py](../../tools/benchmark-storage-discovery-variants.py) | executable definitions | 1 |  |
| [tools/benchmark-storage-discovery-work.py](../../tools/benchmark-storage-discovery-work.py) | executable definitions | 2 |  |
| [tools/build-storage-cross-macos.py](../../tools/build-storage-cross-macos.py) | executable definitions | 1 |  |
| [tools/build-storage-deps.sh](../../tools/build-storage-deps.sh) | executable definitions | 1 |  |
| [tools/check-connected-record-fixtures.py](../../tools/check-connected-record-fixtures.py) | executable definitions | 2 |  |
| [tools/check-current-cell-fixtures.py](../../tools/check-current-cell-fixtures.py) | executable definitions | 2 |  |
| [tools/check-current-state-fixtures.py](../../tools/check-current-state-fixtures.py) | executable definitions | 2 |  |
| [tools/check-derived-state-fixtures.py](../../tools/check-derived-state-fixtures.py) | executable definitions | 2 | [check-current-cell-fixtures.py](../../tools/check-current-cell-fixtures.py) |
| [tools/check-envelope-fixtures.mjs](../../tools/check-envelope-fixtures.mjs) | executable definitions | 3 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/check-general-snapshot-fixtures.py](../../tools/check-general-snapshot-fixtures.py) | executable definitions | 2 |  |
| [tools/check-initial-bootstrap-fixtures.py](../../tools/check-initial-bootstrap-fixtures.py) | executable definitions | 2 |  |
| [tools/check-initial-snapshot-fixtures.py](../../tools/check-initial-snapshot-fixtures.py) | executable definitions | 2 |  |
| [tools/check-merge-fixtures.py](../../tools/check-merge-fixtures.py) | executable definitions | 2 |  |
| [tools/check-private-current-fixtures.mjs](../../tools/check-private-current-fixtures.mjs) | executable definitions | 1 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/check-private-record-fixtures.py](../../tools/check-private-record-fixtures.py) | executable definitions | 2 |  |
| [tools/check-projection-descriptor-fixtures.py](../../tools/check-projection-descriptor-fixtures.py) | executable definitions | 2 |  |
| [tools/check-projection-encoding-observations.py](../../tools/check-projection-encoding-observations.py) | executable definitions | 2 |  |
| [tools/check-projection-filename-fixtures.py](../../tools/check-projection-filename-fixtures.py) | executable definitions | 16 |  |
| [tools/check-projection-observation-fixtures.py](../../tools/check-projection-observation-fixtures.py) | executable definitions | 2 |  |
| [tools/check-projection-stamp-fixtures.py](../../tools/check-projection-stamp-fixtures.py) | executable definitions | 2 |  |
| [tools/check-projection-transport-fixtures.py](../../tools/check-projection-transport-fixtures.py) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/check-recovery-artifact-fixtures.py](../../tools/check-recovery-artifact-fixtures.py) | executable definitions | 2 | [RecoveryArtifactsTests.swift](../../NVStorage/Tests/NVStorageCoreTests/RecoveryArtifactsTests.swift) |
| [tools/check-restoration-fixtures.py](../../tools/check-restoration-fixtures.py) | executable definitions | 2 |  |
| [tools/check-storage-elf.py](../../tools/check-storage-elf.py) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/check-verification-fixtures.py](../../tools/check-verification-fixtures.py) | executable definitions | 2 |  |
| [tools/check-zstd-frames.mjs](../../tools/check-zstd-frames.mjs) | executable definitions | 1 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/compiler_probe_batches.py](../../tools/compiler_probe_batches.py) | fixture / support / build prerequisite | 0 |  |
| [tools/current-row-frame.mjs](../../tools/current-row-frame.mjs) | fixture / support / build prerequisite | 0 |  |
| [tools/disable_nib_autolayout.sh](../../tools/disable_nib_autolayout.sh) | fixture / support / build prerequisite | 0 |  |
| [tools/generate-test-index.py](../../tools/generate-test-index.py) | executable definitions | 3 |  |
| [tools/inspect-storage-history.mjs](../../tools/inspect-storage-history.mjs) | executable definitions | 1 | [inspect-storage-process-artifacts.py](../../tools/inspect-storage-process-artifacts.py), [test-projection-producer-process.py](../../tools/test-projection-producer-process.py), [test-projection-transport-process.py](../../tools/test-projection-transport-process.py), [test-storage-apple-repair.py](../../tools/test-storage-apple-repair.py), [test-storage-apple-startup.py](../../tools/test-storage-apple-startup.py), [test-storage-apple-transport.py](../../tools/test-storage-apple-transport.py), [test-storage-bootstrap-reconstruction-process.py](../../tools/test-storage-bootstrap-reconstruction-process.py), [test-storage-current-maintenance-process.py](../../tools/test-storage-current-maintenance-process.py), [test-storage-disposal-process.py](../../tools/test-storage-disposal-process.py), [test-storage-generated.py](../../tools/test-storage-generated.py), [test-storage-history-process.py](../../tools/test-storage-history-process.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-phase3-process.py](../../tools/test-storage-phase3-process.py), [test-storage-phase5-connected.py](../../tools/test-storage-phase5-connected.py), [test-storage-private-process.py](../../tools/test-storage-private-process.py), [test-storage-process.py](../../tools/test-storage-process.py), [test-storage-received-snapshot-process.py](../../tools/test-storage-received-snapshot-process.py), [test-storage-rejection.py](../../tools/test-storage-rejection.py), [test-storage-repository-copy-process.py](../../tools/test-storage-repository-copy-process.py), [test-storage-repository-cross-host.py](../../tools/test-storage-repository-cross-host.py), [test-storage-repository-exchange.py](../../tools/test-storage-repository-exchange.py), [test-storage-repository-repair-process.py](../../tools/test-storage-repository-repair-process.py), [test-storage-restoration-process.py](../../tools/test-storage-restoration-process.py), [test-storage-retention-delivery.py](../../tools/test-storage-retention-delivery.py), [test-storage-scoped-platform.py](../../tools/test-storage-scoped-platform.py), [test-storage-snapshot-process.py](../../tools/test-storage-snapshot-process.py), [test-storage-startup-process.py](../../tools/test-storage-startup-process.py), [test-storage-startup-remote.py](../../tools/test-storage-startup-remote.py) |
| [tools/inspect-storage-process-artifacts.py](../../tools/inspect-storage-process-artifacts.py) | executable definitions | 1 |  |
| [tools/link-integration-test.py](../../tools/link-integration-test.py) | executable definitions | 1 | [qualification_reuse.py](../../tools/qualification_reuse.py), [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/prototypes/ActorDatabaseProbe.swift](../../tools/prototypes/ActorDatabaseProbe.swift) | fixture / support / build prerequisite | 0 |  |
| [tools/prototypes/test-actor-database.py](../../tools/prototypes/test-actor-database.py) | executable definitions | 3 |  |
| [tools/qualification_reuse.py](../../tools/qualification_reuse.py) | fixture / support / build prerequisite | 0 |  |
| [tools/release.sh](../../tools/release.sh) | fixture / support / build prerequisite | 0 |  |
| [tools/run-native-undo-probes.py](../../tools/run-native-undo-probes.py) | executable definitions | 1 |  |
| [tools/run_filesystem_image_tests.sh](../../tools/run_filesystem_image_tests.sh) | executable definitions | 12 |  |
| [tools/test-bootstrap-mutations.py](../../tools/test-bootstrap-mutations.py) | executable definitions | 11 | [test-storage-apple-peer.py](../../tools/test-storage-apple-peer.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py), [test-zstd-mutations.py](../../tools/test-zstd-mutations.py) |
| [tools/test-compiler-probe-batches.py](../../tools/test-compiler-probe-batches.py) | executable definitions | 16 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-epoch4-v5-compatibility.sh](../../tools/test-epoch4-v5-compatibility.sh) | executable definitions | 1 | [Epoch4CompatibilitySmokeMain.m](../../tests/Epoch4CompatibilitySmokeMain.m) |
| [tools/test-projection-create-process.py](../../tools/test-projection-create-process.py) | executable definitions | 3 | [test-projection-files-c.py](../../tools/test-projection-files-c.py) |
| [tools/test-projection-files-c.py](../../tools/test-projection-files-c.py) | executable definitions | 51 |  |
| [tools/test-projection-output-process.py](../../tools/test-projection-output-process.py) | executable definitions | 9 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-projection-producer-process.py](../../tools/test-projection-producer-process.py) | executable definitions | 12 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-projection-read-process.py](../../tools/test-projection-read-process.py) | executable definitions | 10 |  |
| [tools/test-projection-transport-process.py](../../tools/test-projection-transport-process.py) | executable definitions | 12 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-qualification-reuse.py](../../tools/test-qualification-reuse.py) | executable definitions | 14 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-sql-maintenance-privacy.py](../../tools/test-sql-maintenance-privacy.py) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-sql-maintenance.py](../../tools/test-sql-maintenance.py) | executable definitions | 4 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-sqlcipher-cold-start.py](../../tools/test-sqlcipher-cold-start.py) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-apple-peer.py](../../tools/test-storage-apple-peer.py) | executable definitions | 2 |  |
| [tools/test-storage-apple-repair.py](../../tools/test-storage-apple-repair.py) | executable definitions | 7 |  |
| [tools/test-storage-apple-stage.py](../../tools/test-storage-apple-stage.py) | executable definitions | 2 |  |
| [tools/test-storage-apple-startup.py](../../tools/test-storage-apple-startup.py) | executable definitions | 3 |  |
| [tools/test-storage-apple-transport.py](../../tools/test-storage-apple-transport.py) | executable definitions | 4 | [test-storage-apple-repair.py](../../tools/test-storage-apple-repair.py), [test-storage-apple-startup.py](../../tools/test-storage-apple-startup.py) |
| [tools/test-storage-bootstrap-reconstruction-process.py](../../tools/test-storage-bootstrap-reconstruction-process.py) | executable definitions | 13 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-coordinated-install.py](../../tools/test-storage-coordinated-install.py) | executable definitions | 2 |  |
| [tools/test-storage-current-maintenance-process.py](../../tools/test-storage-current-maintenance-process.py) | executable definitions | 33 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-disposal-process.py](../../tools/test-storage-disposal-process.py) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-generated.py](../../tools/test-storage-generated.py) | executable definitions | 31 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-history-process.py](../../tools/test-storage-history-process.py) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-immutable-files.py](../../tools/test-storage-immutable-files.py) | executable definitions | 2 | [test-storage-coordinated-install.py](../../tools/test-storage-coordinated-install.py), [test-storage-immutable-mutations.py](../../tools/test-storage-immutable-mutations.py), [test-storage-immutable-volumes.py](../../tools/test-storage-immutable-volumes.py) |
| [tools/test-storage-immutable-mutations.py](../../tools/test-storage-immutable-mutations.py) | executable definitions | 15 |  |
| [tools/test-storage-immutable-process.py](../../tools/test-storage-immutable-process.py) | executable definitions | 3 |  |
| [tools/test-storage-immutable-volumes.py](../../tools/test-storage-immutable-volumes.py) | executable definitions | 6 |  |
| [tools/test-storage-merge-process.py](../../tools/test-storage-merge-process.py) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-metadata-batches.py](../../tools/test-storage-metadata-batches.py) | executable definitions | 17 |  |
| [tools/test-storage-phase2.py](../../tools/test-storage-phase2.py) | executable definitions | 62 |  |
| [tools/test-storage-phase3-process.py](../../tools/test-storage-phase3-process.py) | executable definitions | 66 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-phase5-connected.py](../../tools/test-storage-phase5-connected.py), [test-storage-scoped-platform.py](../../tools/test-storage-scoped-platform.py) |
| [tools/test-storage-phase5-connected.py](../../tools/test-storage-phase5-connected.py) | executable definitions | 10 |  |
| [tools/test-storage-private-process.py](../../tools/test-storage-private-process.py) | executable definitions | 101 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-private-types.py](../../tools/test-storage-private-types.py) | executable definitions | 180 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-process.py](../../tools/test-storage-process.py) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-received-snapshot-process.py](../../tools/test-storage-received-snapshot-process.py) | executable definitions | 30 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-rejection.py](../../tools/test-storage-rejection.py) | executable definitions | 10 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-repair-replacement-capability.py](../../tools/test-storage-repair-replacement-capability.py) | executable definitions | 6 |  |
| [tools/test-storage-repository-copy-process.py](../../tools/test-storage-repository-copy-process.py) | executable definitions | 38 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-repository-cross-host.py](../../tools/test-storage-repository-cross-host.py) | executable definitions | 3 |  |
| [tools/test-storage-repository-exchange.py](../../tools/test-storage-repository-exchange.py) | executable definitions | 11 |  |
| [tools/test-storage-repository-repair-process.py](../../tools/test-storage-repository-repair-process.py) | executable definitions | 34 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-restoration-process.py](../../tools/test-storage-restoration-process.py) | executable definitions | 8 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-retention-delivery.py](../../tools/test-storage-retention-delivery.py) | executable definitions | 9 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-review-process.py](../../tools/test-storage-review-process.py) | executable definitions | 6 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-root-c.py](../../tools/test-storage-root-c.py) | executable definitions | 1 |  |
| [tools/test-storage-root-process.py](../../tools/test-storage-root-process.py) | executable definitions | 8 | [test-projection-read-process.py](../../tools/test-projection-read-process.py), [test-storage-root-volumes.py](../../tools/test-storage-root-volumes.py) |
| [tools/test-storage-root-types.py](../../tools/test-storage-root-types.py) | executable definitions | 247 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-root-volumes.py](../../tools/test-storage-root-volumes.py) | executable definitions | 8 |  |
| [tools/test-storage-runtime-mutations.py](../../tools/test-storage-runtime-mutations.py) | executable definitions | 318 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-runtime-types.py](../../tools/test-storage-runtime-types.py) | executable definitions | 186 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-sanitizers.py](../../tools/test-storage-sanitizers.py) | executable definitions | 3 |  |
| [tools/test-storage-scoped-platform.py](../../tools/test-storage-scoped-platform.py) | executable definitions | 2 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-snapshot-process.py](../../tools/test-storage-snapshot-process.py) | executable definitions | 21 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-storage-startup-process.py](../../tools/test-storage-startup-process.py) | executable definitions | 10 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-startup-remote.py](../../tools/test-storage-startup-remote.py) |
| [tools/test-storage-startup-remote.py](../../tools/test-storage-startup-remote.py) | executable definitions | 2 |  |
| [tools/test-storage-test-targets.py](../../tools/test-storage-test-targets.py) | executable definitions | 28 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/test-swift-storage-types.py](../../tools/test-swift-storage-types.py) | executable definitions | 72 | [test-storage-phase2.py](../../tools/test-storage-phase2.py), [test-storage-private-types.py](../../tools/test-storage-private-types.py), [test-storage-root-types.py](../../tools/test-storage-root-types.py), [test-storage-runtime-types.py](../../tools/test-storage-runtime-types.py) |
| [tools/test-zstd-mutations.py](../../tools/test-zstd-mutations.py) | executable definitions | 7 | [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/update-integration-build-manifest.py](../../tools/update-integration-build-manifest.py) | executable definitions | 1 | [test-qualification-reuse.py](../../tools/test-qualification-reuse.py), [test-storage-phase2.py](../../tools/test-storage-phase2.py) |
| [tools/zstd-frame.mjs](../../tools/zstd-frame.mjs) | fixture / support / build prerequisite | 0 |  |
