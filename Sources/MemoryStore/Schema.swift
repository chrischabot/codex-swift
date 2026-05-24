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
      evidence_chunk_id INTEGER REFERENCES chunk(id)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS edge_unique ON edge(src,dst,relation);
    CREATE INDEX IF NOT EXISTS edge_src ON edge(src);
    CREATE INDEX IF NOT EXISTS edge_dst ON edge(dst);

    CREATE TABLE IF NOT EXISTS mention (
      chunk_id    INTEGER NOT NULL REFERENCES chunk(id),
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
