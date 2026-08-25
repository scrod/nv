--------------------- MODULE ReconciliationInterface ----------------------

\* Version sets contain persistent version identifiers. Provider catalog token values
\* are opaque; these predicates compare them only for equality.

AllSelectedRepresented(selectedVersions, representedVersions) ==
    selectedVersions \subseteq representedVersions

ExactProviderFence(snapshotCatalogToken, secondCatalogToken,
                   snapshotVersions, secondVersions) ==
    /\ snapshotCatalogToken = secondCatalogToken
    /\ snapshotVersions = secondVersions

UnchangedModelFence(snapshotSession, activeSession,
                    snapshotStructuralGeneration, structuralGeneration,
                    snapshotNoteLSN, noteLSN) ==
    /\ snapshotSession = activeSession
    /\ snapshotStructuralGeneration = structuralGeneration
    /\ snapshotNoteLSN = noteLSN

CompleteFence(snapshotVersions, unreadableVersions, enumerationComplete,
              snapshotCatalogToken, secondCatalogToken, secondVersions,
              snapshotSession, activeSession,
              snapshotStructuralGeneration, structuralGeneration,
              snapshotNoteLSN, noteLSN, representedVersions) ==
    /\ snapshotVersions # {}
    /\ enumerationComplete
    /\ snapshotVersions \cap unreadableVersions = {}
    /\ ExactProviderFence(snapshotCatalogToken, secondCatalogToken,
                          snapshotVersions, secondVersions)
    /\ UnchangedModelFence(snapshotSession, activeSession,
                           snapshotStructuralGeneration,
                           structuralGeneration,
                           snapshotNoteLSN, noteLSN)
    /\ AllSelectedRepresented(snapshotVersions, representedVersions)

PartialProviderEvidence(snapshotVersions, unreadableVersions,
                        enumerationComplete, snapshotCatalogToken,
                        secondCatalogToken, secondVersions) ==
    \/ ~enumerationComplete
    \/ snapshotVersions \cap unreadableVersions # {}
    \/ ~ExactProviderFence(snapshotCatalogToken, secondCatalogToken,
                           snapshotVersions, secondVersions)

=============================================================================
