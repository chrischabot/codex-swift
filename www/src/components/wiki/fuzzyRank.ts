// Compact fuzzy ranker (granite parity, M29 core) — scores a query against a
// candidate string and returns matched character ranges for highlighting.
// Pure + allocation-light so the quick-switcher can rank the WHOLE vault
// (thousands of titles) per keystroke and render only the top N, instead of
// putting every page in the DOM for cmdk to score.
//
// Scoring favors, in order: exact / prefix / word-boundary contiguous hits,
// then a subsequence match. Higher score = better. Returns null on no match.

export interface FuzzyMatch {
  score: number;
  /** Inclusive [start,end) ranges of matched chars in the candidate, merged. */
  ranges: ReadonlyArray<readonly [number, number]>;
}

const WORD_BOUNDARY = /[\s/\-_.:#|([{]/;

/** Score `query` against `text`. Empty query matches everything at score 0. */
export function fuzzyMatch(query: string, text: string): FuzzyMatch | null {
  const q = query.trim().toLowerCase();
  if (q === "") return { score: 0, ranges: [] };
  const lower = text.toLowerCase();

  // Fast path: contiguous substring. Score by position (earlier = better) and
  // a big bonus for a word-boundary / prefix start.
  const idx = lower.indexOf(q);
  if (idx !== -1) {
    const atStart = idx === 0;
    const atBoundary = idx > 0 && WORD_BOUNDARY.test(text[idx - 1]);
    let score = 1000 - idx; // earlier wins
    if (atStart) score += 4000;
    else if (atBoundary) score += 2000;
    score -= text.length / 100; // gently prefer shorter titles
    return { score, ranges: [[idx, idx + q.length]] };
  }

  // Subsequence: every query char appears in order. Reward consecutive runs and
  // word-boundary starts; this is the "loose" fallback.
  const ranges: Array<[number, number]> = [];
  let qi = 0;
  let score = 0;
  let runStart = -1;
  let prevMatched = -2;
  for (let i = 0; i < lower.length && qi < q.length; i++) {
    if (lower[i] === q[qi]) {
      if (i === prevMatched + 1) {
        score += 5; // consecutive run
      } else {
        score += 1;
        if (i === 0 || WORD_BOUNDARY.test(text[i - 1])) score += 8; // boundary
        if (runStart !== -1) ranges.push([runStart, prevMatched + 1]);
        runStart = i;
      }
      prevMatched = i;
      qi++;
    }
  }
  if (qi !== q.length) return null; // not all query chars consumed
  if (runStart !== -1) ranges.push([runStart, prevMatched + 1]);
  score -= text.length / 100;
  return { score, ranges };
}

export interface Ranked<T> {
  item: T;
  score: number;
  ranges: ReadonlyArray<readonly [number, number]>;
}

/**
 * Rank `items` by `query` against `key(item)`, best first, keeping at most
 * `limit`. Empty query returns the first `limit` items unscored (list order).
 */
export function fuzzyRank<T>(
  query: string,
  items: ReadonlyArray<T>,
  key: (item: T) => string,
  limit = 50,
): Ranked<T>[] {
  if (query.trim() === "") {
    return items.slice(0, limit).map((item) => ({ item, score: 0, ranges: [] }));
  }
  const out: Ranked<T>[] = [];
  for (const item of items) {
    const m = fuzzyMatch(query, key(item));
    if (m) out.push({ item, score: m.score, ranges: m.ranges });
  }
  out.sort((a, b) => b.score - a.score);
  return out.slice(0, limit);
}
