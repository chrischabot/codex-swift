import Foundation

/// Schema text for MemoryStore. Mirrors §3 of the design doc verbatim where
/// possible; the only departure from spec is the conditional `chunk_embedding`
/// blob table that exists only when sqlite-vec isn't linked (see §1 of this
/// implementation's seam discussion). Both branches share rowid space with
/// `chunk.id`.
enum MemorySchema {
    static let coreSQL: String = """
    CREATE TABLE IF NOT EXISTS document (
      id            INTEGER PRIMARY KEY,
      source        TEXT NOT NULL,
      source_uri    TEXT NOT NULL UNIQUE,
      title         TEXT,
      body_path     TEXT NOT NULL,
      fetched_at    INTEGER NOT NULL,
      published_at  INTEGER,
      content_sha   BLOB NOT NULL,
      language      TEXT,
      raw_bytes     INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS document_fetched ON document(fetched_at);
    CREATE INDEX IF NOT EXISTS document_source  ON document(source, fetched_at);

    CREATE TABLE IF NOT EXISTS chunk (
      id            INTEGER PRIMARY KEY,
      document_id   INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
      idx           INTEGER NOT NULL,
      text          TEXT NOT NULL,
      raw_text      TEXT NOT NULL,
      token_count   INTEGER NOT NULL,
      logprob_avg   REAL,
      created_at    INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS chunk_doc ON chunk(document_id, idx);

    CREATE TABLE IF NOT EXISTS entity (
      id          INTEGER PRIMARY KEY,
      kind        TEXT NOT NULL,
      canonical   TEXT NOT NULL,
      aliases     TEXT,
      first_seen  INTEGER NOT NULL,
      last_seen   INTEGER NOT NULL,
      degree      INTEGER NOT NULL DEFAULT 0,
      ego_betweenness_cached REAL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS entity_canon ON entity(kind, canonical);

    CREATE TABLE IF NOT EXISTS edge (
      id          INTEGER PRIMARY KEY,
      src         INTEGER NOT NULL REFERENCES entity(id),
      dst         INTEGER NOT NULL REFERENCES entity(id),
      relation    TEXT NOT NULL,
      first_seen  INTEGER NOT NULL,
      last_seen   INTEGER NOT NULL,
      weight      REAL NOT NULL DEFAULT 1.0,
      evidence_chunk_id INTEGER REFERENCES chunk(id) ON DELETE SET NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS edge_unique ON edge(src,dst,relation);
    CREATE INDEX IF NOT EXISTS edge_src ON edge(src);
    CREATE INDEX IF NOT EXISTS edge_dst ON edge(dst);

    CREATE TABLE IF NOT EXISTS mention (
      chunk_id    INTEGER NOT NULL REFERENCES chunk(id) ON DELETE CASCADE,
      entity_id   INTEGER NOT NULL REFERENCES entity(id),
      span_start  INTEGER, span_end INTEGER, salience REAL,
      PRIMARY KEY (chunk_id, entity_id)
    );
    CREATE INDEX IF NOT EXISTS mention_entity ON mention(entity_id);

    CREATE TABLE IF NOT EXISTS insight (
      id           INTEGER PRIMARY KEY,
      -- Nullable + ON DELETE SET NULL so cascading a document delete (via
      -- chunk.document_id ON DELETE CASCADE) leaves the insight row intact
      -- as a historical record. `recentInteresting` LEFT JOINs through this
      -- so orphan insights still surface.
      trigger_chunk_id INTEGER REFERENCES chunk(id) ON DELETE SET NULL,
      model        TEXT NOT NULL,
      input_tokens INTEGER NOT NULL,
      output_tokens INTEGER NOT NULL,
      cached_input_tokens INTEGER NOT NULL DEFAULT 0,
      cost_usd     REAL NOT NULL,
      score        REAL NOT NULL,
      card_md      TEXT NOT NULL,
      created_at   INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS source_cursor (
      source       TEXT PRIMARY KEY,
      last_etag    TEXT,
      last_modified INTEGER,
      high_watermark_id TEXT,
      next_eligible_at  INTEGER NOT NULL,
      consecutive_failures INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS spend (
      ts           INTEGER NOT NULL,
      bucket       TEXT NOT NULL,
      units        REAL NOT NULL,
      unit_kind    TEXT NOT NULL,
      cost_usd     REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS spend_ts ON spend(ts, bucket);
    """

    /// Additive Memory-Wiki knowledge model (the §4 canonical schema): durable
    /// claims + evidence + contradictions, synthesis/article/thesis/output pages,
    /// per-document provenance/trust overlay, and replayable research-session
    /// provenance. All `CREATE TABLE IF NOT EXISTS` so existing stores migrate
    /// transparently — no reindex, no embedder change, no provider-id re-stamp.
    /// Claim retrieval rides the existing chunk vectors via `claim_evidence.chunk_id`
    /// (no second embedding space → the single-embedder invariant is untouched).
    static let wikiSQL: String = """
    -- Per-document provenance/trust overlay (1:1 with the immutable document).
    CREATE TABLE IF NOT EXISTS source_meta (
      document_id   INTEGER PRIMARY KEY REFERENCES document(id) ON DELETE CASCADE,
      source_kind   TEXT NOT NULL,
      trust_tier    TEXT NOT NULL DEFAULT 'medium',   -- high|medium|low|reject
      credibility   INTEGER NOT NULL DEFAULT 0,        -- raw -N..+6 rubric score
      confidence    TEXT,                              -- high|medium|low
      volatility    TEXT NOT NULL DEFAULT 'warm',      -- hot|warm|cold
      verified_at   INTEGER, ingested_at INTEGER NOT NULL,
      author TEXT, published_at INTEGER, license TEXT, canonical_url TEXT, bias_flags TEXT,
      collection TEXT, adapter TEXT, upstream_id TEXT, revision TEXT, blob_sha TEXT,
      compiled_from TEXT NOT NULL DEFAULT 'sources',   -- sources|conversation|mixed
      frontmatter   TEXT
    );

    -- Durable atomic claim (replaces edge-synthesized claims).
    CREATE TABLE IF NOT EXISTS claim (
      id            INTEGER PRIMARY KEY,
      text          TEXT NOT NULL,
      canonical_sha BLOB NOT NULL,                     -- sha256 of NORMALIZED text (idempotent recompile)
      status        TEXT NOT NULL DEFAULT 'draft',     -- draft|active|stale|contradicted|archived
      confidence    REAL NOT NULL DEFAULT 0.5,
      volatility    TEXT NOT NULL DEFAULT 'warm',
      category      TEXT, scope TEXT,
      first_seen    INTEGER NOT NULL, last_reviewed INTEGER, updated_at INTEGER NOT NULL,
      compiled_from TEXT NOT NULL DEFAULT 'sources',
      edge_id       INTEGER REFERENCES edge(id) ON DELETE SET NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS claim_sha    ON claim(canonical_sha);
    CREATE INDEX        IF NOT EXISTS claim_status ON claim(status, volatility, last_reviewed);

    -- Evidence span: claim ⇄ chunk/document provenance (rides existing vectors).
    -- A surrogate id + an expression-unique index keeps attach idempotent even
    -- when chunk_id is NULL (a nullable column in a composite PK would let NULLs
    -- duplicate, defeating dedupe).
    CREATE TABLE IF NOT EXISTS claim_evidence (
      id          INTEGER PRIMARY KEY,
      claim_id    INTEGER NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
      document_id INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
      chunk_id    INTEGER REFERENCES chunk(id) ON DELETE SET NULL,
      stance      TEXT NOT NULL DEFAULT 'supports',   -- supports|opposes|nuances
      relevance   TEXT,                                -- direct|indirect|tangential
      strength    INTEGER NOT NULL DEFAULT 2,          -- meta>rct>cohort>case>opinion>anecdotal
      span_start  INTEGER, span_end INTEGER
    );
    CREATE UNIQUE INDEX IF NOT EXISTS claim_ev_uniq  ON claim_evidence(claim_id, document_id, IFNULL(chunk_id, -1));
    CREATE INDEX        IF NOT EXISTS claim_ev_chunk ON claim_evidence(chunk_id);
    CREATE INDEX        IF NOT EXISTS claim_ev_doc   ON claim_evidence(document_id);

    CREATE TABLE IF NOT EXISTS claim_contradiction (
      claim_id    INTEGER NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
      contradicts INTEGER NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
      detected_at INTEGER NOT NULL,
      PRIMARY KEY (claim_id, contradicts)
    );

    -- Synthesis / article / thesis / output page (durable; rendered to the vault).
    CREATE TABLE IF NOT EXISTS synthesis (
      id            INTEGER PRIMARY KEY,
      slug          TEXT NOT NULL UNIQUE,
      category      TEXT NOT NULL,                     -- concept|topic|reference|thesis|synthesis|plan|report|playbook|project|digest
      title         TEXT NOT NULL,
      body_path     TEXT NOT NULL,
      confidence    TEXT, volatility TEXT NOT NULL DEFAULT 'warm',
      verified_at   INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      human_block_sha BLOB,
      thesis_status TEXT, verdict TEXT, core_claim TEXT, key_variables TEXT, falsification TEXT,
      evidence_for  INTEGER NOT NULL DEFAULT 0, evidence_against INTEGER NOT NULL DEFAULT 0,
      format        TEXT, generated_at INTEGER, output_type TEXT
    );
    CREATE INDEX IF NOT EXISTS synthesis_cat ON synthesis(category, volatility);

    -- synthesis ⇄ claim (normalized link; the queryable source of truth).
    CREATE TABLE IF NOT EXISTS synthesis_claim (
      synthesis_id INTEGER NOT NULL REFERENCES synthesis(id) ON DELETE CASCADE,
      claim_id     INTEGER NOT NULL REFERENCES claim(id) ON DELETE CASCADE,
      PRIMARY KEY (synthesis_id, claim_id)
    );

    -- Durable replayable research-session provenance (mirror of the wiki-root
    -- .session-events.jsonl / .session-checkpoint.json files).
    CREATE TABLE IF NOT EXISTS research_session (
      session_id TEXT PRIMARY KEY, command TEXT, mode TEXT, topic TEXT,
      start_time INTEGER, min_time_budget INTEGER, current_round INTEGER,
      cumulative_sources INTEGER, cumulative_articles INTEGER,
      status TEXT, last_progress_score REAL, paths_json TEXT
    );
    CREATE TABLE IF NOT EXISTS session_event (
      id INTEGER PRIMARY KEY, session_id TEXT, ts INTEGER, command TEXT,
      phase TEXT, event TEXT, round INTEGER, sources_ingested INTEGER,
      articles_compiled INTEGER, progress_score REAL, artifacts_json TEXT, notes TEXT
    );
    CREATE INDEX IF NOT EXISTS session_ev ON session_event(session_id, ts);
    CREATE TABLE IF NOT EXISTS session_checkpoint (
      session_id TEXT PRIMARY KEY,
      updated_at INTEGER NOT NULL, status TEXT NOT NULL, summary TEXT NOT NULL
    );
    -- Crash-safe ingest ledger (§ Phase 2): a job + one row per candidate item, so
    -- an interrupted ingest is observable/queryable and the watch cursor survives.
    CREATE TABLE IF NOT EXISTS wiki_ingest_job (
      job_id TEXT PRIMARY KEY, input TEXT NOT NULL, adapter TEXT, raw_type TEXT,
      corpus TEXT, started_at INTEGER NOT NULL, finished_at INTEGER,
      status TEXT NOT NULL,                       -- running | done | failed | cancelled
      candidates INTEGER NOT NULL DEFAULT 0, written INTEGER NOT NULL DEFAULT 0,
      skipped INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0,
      cursor TEXT, error TEXT
    );
    CREATE INDEX IF NOT EXISTS wiki_ingest_job_started ON wiki_ingest_job(started_at);
    CREATE TABLE IF NOT EXISTS wiki_ingest_item (
      job_id TEXT NOT NULL REFERENCES wiki_ingest_job(job_id) ON DELETE CASCADE,
      seq INTEGER NOT NULL, source_uri TEXT NOT NULL,
      status TEXT NOT NULL,                       -- written | deduped | skipped | failed
      document_id INTEGER, error TEXT, recorded_at INTEGER NOT NULL,
      PRIMARY KEY(job_id, seq)
    );
    CREATE INDEX IF NOT EXISTS wiki_ingest_item_uri ON wiki_ingest_item(source_uri);
    -- Watched sources (§14.6): a handle + cadence + scheduling state. The poll
    -- loop reads `next_due_at`; WatchScheduler computes cadence/backoff.
    CREATE TABLE IF NOT EXISTS watch_source (
      id            TEXT PRIMARY KEY,            -- the handle/URL (dedupe key)
      kind          TEXT NOT NULL,               -- adapter kind (github-owner|feed|arxiv|url)
      volatility    TEXT NOT NULL DEFAULT 'warm',-- cadence tier (hot|warm|cold)
      last_polled_at INTEGER NOT NULL DEFAULT 0,
      error_count   INTEGER NOT NULL DEFAULT 0,
      next_due_at   INTEGER NOT NULL DEFAULT 0,
      status        TEXT NOT NULL DEFAULT 'active', -- active|paused|error|disabled
      cursor        TEXT, last_change_at INTEGER, added_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS watch_source_due ON watch_source(status, next_due_at);
    """

    static func vec0VirtualTableSQL(dim: Int) -> String {
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vec USING vec0(
          embedding float[\(dim)] distance_metric=cosine
        );
        """
    }

    static let embeddingBlobTableSQL: String = """
    CREATE TABLE IF NOT EXISTS chunk_embedding (
      chunk_id  INTEGER PRIMARY KEY REFERENCES chunk(id) ON DELETE CASCADE,
      embedding BLOB NOT NULL
    );
    """

    static let ftsSQL: String = """
    CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
      text,
      content='chunk', content_rowid='id', tokenize='porter unicode61'
    );
    """

    static let metaSQL: String = """
    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    """
}
