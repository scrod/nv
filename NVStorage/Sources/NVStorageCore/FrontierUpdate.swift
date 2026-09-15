/// Advances the maxima of a dependency-closed graph with a complete new batch.
/// Existing ancestors below a previous maximum were already removed from that set.
package func advancingFrontier<ID: Hashable>(_ previous: Set<ID>, adding: Set<ID>, parents: Set<ID>) -> Set<ID> {
    previous.union(adding).subtracting(parents)
}
