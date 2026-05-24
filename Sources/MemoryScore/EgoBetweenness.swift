import Foundation

/// Ego-betweenness centrality on a small subgraph. Brandes' algorithm
/// adapted for an undirected graph (we treat edges as symmetric for the
/// purposes of structural centrality even when the underlying relation is
/// directed — relation semantics are preserved in the edge table). The
/// design doc spells out that this is the local approximation referenced by
/// Everett & Borgatti (2005) and Chai et al. (2013).
public enum EgoBetweenness {
    /// Compute normalised betweenness over the supplied adjacency map. The
    /// map is `node -> neighbours` (assumed symmetric). Returns a dictionary
    /// keyed by node id.
    public static func compute(adjacency: [Int64: Set<Int64>]) -> [Int64: Double] {
        var betweenness = [Int64: Double]()
        let nodes = Array(adjacency.keys)
        for s in nodes { betweenness[s] = 0 }
        if nodes.count < 3 { return betweenness }

        for s in nodes {
            var stack: [Int64] = []
            var preds = [Int64: [Int64]]()
            var sigma = [Int64: Double]()
            var dist = [Int64: Int]()
            for v in nodes { sigma[v] = 0; dist[v] = -1; preds[v] = [] }
            sigma[s] = 1; dist[s] = 0
            var queue: [Int64] = [s]
            while !queue.isEmpty {
                let v = queue.removeFirst()
                stack.append(v)
                let neighbours = adjacency[v] ?? []
                for w in neighbours {
                    if dist[w] == -1 {
                        dist[w] = (dist[v] ?? 0) + 1
                        queue.append(w)
                    }
                    if dist[w] == (dist[v] ?? 0) + 1 {
                        sigma[w] = (sigma[w] ?? 0) + (sigma[v] ?? 0)
                        preds[w]?.append(v)
                    }
                }
            }
            var delta = [Int64: Double]()
            for v in nodes { delta[v] = 0 }
            while let w = stack.popLast() {
                let sw = sigma[w] ?? 0
                guard sw > 0 else { continue }
                for v in (preds[w] ?? []) {
                    let sv = sigma[v] ?? 0
                    let contribution = (sv / sw) * (1 + (delta[w] ?? 0))
                    delta[v] = (delta[v] ?? 0) + contribution
                }
                if w != s {
                    betweenness[w] = (betweenness[w] ?? 0) + (delta[w] ?? 0)
                }
            }
        }
        // Normalise: divide by (n-1)(n-2) for undirected graphs.
        let n = Double(nodes.count)
        let denom = (n - 1) * (n - 2)
        if denom > 0 {
            for k in betweenness.keys {
                betweenness[k] = (betweenness[k] ?? 0) / denom
            }
        }
        return betweenness
    }
}
