import Foundation

// CRUD for the M8 curation tables (Inventory / Datasets / Collect). Same-actor
// extension (no second writer) so writes stay transactional with the rest of the
// store. All list reads are dedicated-column projections — they NEVER read bodies.
extension MemoryStore {

    // MARK: - inventory records

    @discardableResult
    public func upsertInventoryRecord(_ r: InventoryRecordRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO wiki_inventory_record(slug,kind,status,priority,title,summary,next_action,tags,sources,
            origin,confidence,body_md,quantity,unit,item_state,created_at,updated_at,last_checked,lifecycle_status)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(slug) DO UPDATE SET
          kind=excluded.kind, status=excluded.status, priority=excluded.priority, title=excluded.title,
          summary=excluded.summary, next_action=excluded.next_action, tags=excluded.tags, sources=excluded.sources,
          origin=excluded.origin, confidence=excluded.confidence, body_md=excluded.body_md, quantity=excluded.quantity,
          unit=excluded.unit, item_state=excluded.item_state, updated_at=excluded.updated_at,
          last_checked=excluded.last_checked, lifecycle_status=excluded.lifecycle_status
        RETURNING id;
        """, [
            .text(r.slug), .text(r.kind), .text(r.status), .text(r.priority), .text(r.title),
            r.summary.map(Bind.text) ?? .null, r.nextAction.map(Bind.text) ?? .null,
            r.tags.map(Bind.text) ?? .null, r.sources.map(Bind.text) ?? .null, r.origin.map(Bind.text) ?? .null,
            r.confidence.map(Bind.text) ?? .null, r.bodyMd.map(Bind.text) ?? .null,
            r.quantity.map(Bind.int) ?? .null, r.unit.map(Bind.text) ?? .null, r.itemState.map(Bind.text) ?? .null,
            .int(r.createdAt), .int(r.updatedAt), r.lastChecked.map(Bind.int) ?? .null, .text(r.lifecycleStatus),
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func inventoryRecord(slug: String) throws -> InventoryRecordRow? {
        try run("SELECT * FROM wiki_inventory_record WHERE slug=?;", [.text(slug)]).first.map(curParseInventory)
    }

    /// Compact-table projection (dedicated columns only, never bodies). Filters by
    /// kind/status; archived rows are excluded unless `includeArchived`.
    public func inventoryRecords(kind: String? = nil, status: String? = nil,
                                 includeArchived: Bool = false, limit: Int = 10_000) throws -> [InventoryRecordRow] {
        var sql = "SELECT * FROM wiki_inventory_record WHERE 1=1"
        var binds: [Bind] = []
        if let kind { sql += " AND kind=?"; binds.append(.text(kind)) }
        if let status { sql += " AND status=?"; binds.append(.text(status)) }
        if !includeArchived { sql += " AND lifecycle_status='active'" }
        sql += " ORDER BY priority, updated_at DESC LIMIT ?;"; binds.append(.int(Int64(limit)))
        return try run(sql, binds).map(curParseInventory)
    }

    // MARK: - inventory views

    @discardableResult
    public func upsertInventoryView(_ v: InventoryViewRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO wiki_inventory_view(slug,title,filters,updated_at) VALUES(?,?,?,?)
        ON CONFLICT(slug) DO UPDATE SET title=excluded.title, filters=excluded.filters, updated_at=excluded.updated_at
        RETURNING id;
        """, [.text(v.slug), .text(v.title), v.filters.map(Bind.text) ?? .null, .int(v.updatedAt)])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func inventoryViews() throws -> [InventoryViewRow] {
        try run("SELECT * FROM wiki_inventory_view ORDER BY updated_at DESC;", []).map { r in
            InventoryViewRow(id: curInt(r, "id") ?? 0, slug: (r["slug"] as? String) ?? "",
                             title: (r["title"] as? String) ?? "", filters: r["filters"] as? String,
                             updatedAt: curInt(r, "updated_at") ?? 0)
        }
    }

    // MARK: - dataset manifests + notes

    @discardableResult
    public func upsertDatasetManifest(_ m: DatasetManifestRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO wiki_dataset_manifest(dataset_id,title,status,storage,locations,formats,schema_status,
            size_bytes,record_count,inventory_links,raw_sources,license,access,checksum,refresh_cadence,
            summary,body_md,origin,created_at,updated_at,lifecycle_status)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(dataset_id) DO UPDATE SET
          title=excluded.title, status=excluded.status, storage=excluded.storage, locations=excluded.locations,
          formats=excluded.formats, schema_status=excluded.schema_status, size_bytes=excluded.size_bytes,
          record_count=excluded.record_count, inventory_links=excluded.inventory_links, raw_sources=excluded.raw_sources,
          license=excluded.license, access=excluded.access, checksum=excluded.checksum,
          refresh_cadence=excluded.refresh_cadence, summary=excluded.summary, body_md=excluded.body_md,
          origin=excluded.origin, updated_at=excluded.updated_at, lifecycle_status=excluded.lifecycle_status
        RETURNING id;
        """, [
            .text(m.datasetID), .text(m.title), .text(m.status), .text(m.storage),
            m.locations.map(Bind.text) ?? .null, m.formats.map(Bind.text) ?? .null, m.schemaStatus.map(Bind.text) ?? .null,
            m.sizeBytes.map(Bind.int) ?? .null, m.recordCount.map(Bind.int) ?? .null,
            m.inventoryLinks.map(Bind.text) ?? .null, m.rawSources.map(Bind.text) ?? .null,
            m.license.map(Bind.text) ?? .null, m.access.map(Bind.text) ?? .null, m.checksum.map(Bind.text) ?? .null,
            m.refreshCadence.map(Bind.text) ?? .null, m.summary.map(Bind.text) ?? .null, m.bodyMd.map(Bind.text) ?? .null,
            m.origin.map(Bind.text) ?? .null, .int(m.createdAt), .int(m.updatedAt), .text(m.lifecycleStatus),
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func datasetManifest(datasetID: String) throws -> DatasetManifestRow? {
        try run("SELECT * FROM wiki_dataset_manifest WHERE dataset_id=?;", [.text(datasetID)]).first.map(curParseDataset)
    }

    public func datasetManifests(status: String? = nil, includeArchived: Bool = false,
                                 limit: Int = 10_000) throws -> [DatasetManifestRow] {
        var sql = "SELECT * FROM wiki_dataset_manifest WHERE 1=1"
        var binds: [Bind] = []
        if let status { sql += " AND status=?"; binds.append(.text(status)) }
        if !includeArchived { sql += " AND lifecycle_status='active'" }
        sql += " ORDER BY updated_at DESC LIMIT ?;"; binds.append(.int(Int64(limit)))
        return try run(sql, binds).map(curParseDataset)
    }

    @discardableResult
    public func addDatasetNote(_ n: DatasetNoteRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO wiki_dataset_note(manifest_id,note_kind,title,body_md,created_at) VALUES(?,?,?,?,?) RETURNING id;
        """, [.int(n.manifestID), .text(n.noteKind), .text(n.title), .text(n.bodyMd), .int(n.createdAt)])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func datasetNotes(manifestID: Int64) throws -> [DatasetNoteRow] {
        try run("SELECT * FROM wiki_dataset_note WHERE manifest_id=? ORDER BY created_at, id;", [.int(manifestID)]).map { r in
            DatasetNoteRow(id: curInt(r, "id") ?? 0, manifestID: curInt(r, "manifest_id") ?? 0,
                           noteKind: (r["note_kind"] as? String) ?? "", title: (r["title"] as? String) ?? "",
                           bodyMd: (r["body_md"] as? String) ?? "", createdAt: curInt(r, "created_at") ?? 0)
        }
    }

    // MARK: - collect items

    /// Idempotent insert within a catalog, deduped by the first available identity key:
    /// content `sha256`, then `canonical_url`, then `source_url`. Empty strings are
    /// normalized to NULL (so a "" key never trips the `collect_dedup` UNIQUE index nor
    /// counts as an identity). A KEYLESS item (none of the three) has no natural
    /// identity and is APPENDED — idempotence is only guaranteed for items carrying at
    /// least one key. Returns the existing or new id.
    @discardableResult
    public func upsertCollectItem(_ c: CollectItemRow) throws -> Int64 {
        func ne(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }   // nil-if-empty
        let sha = ne(c.sha256), canonical = ne(c.canonicalURL), source = ne(c.sourceURL)
        for (col, val) in [("sha256", sha), ("canonical_url", canonical), ("source_url", source)] {
            // `col` is a fixed literal from this array (not user input) → no injection.
            if let val,
               let id = try run("SELECT id FROM wiki_collect_item WHERE catalog_slug=? AND \(col)=? LIMIT 1;",
                                [.text(c.catalogSlug), .text(val)]).first?["id"] as? Int64 { return id }
        }
        let rows = try run("""
        INSERT INTO wiki_collect_item(catalog_slug,row_number,title,aliases,collect_kind,canonical_url,media_url,
            source_url,origin_platform,creator,first_seen,description,evidence,found_in_context,provenance_confidence,
            rights_or_license,media_format,local_media_path,media_bytes,sha256,perceptual_hash,download_status,
            downloaded_at,next_action,created_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING id;
        """, [
            .text(c.catalogSlug), .int(c.rowNumber), .text(c.title), c.aliases.map(Bind.text) ?? .null,
            c.collectKind.map(Bind.text) ?? .null, canonical.map(Bind.text) ?? .null,
            c.mediaURL.map(Bind.text) ?? .null, source.map(Bind.text) ?? .null,
            c.originPlatform.map(Bind.text) ?? .null, c.creator.map(Bind.text) ?? .null,
            c.firstSeen.map(Bind.text) ?? .null, c.description.map(Bind.text) ?? .null,
            c.evidence.map(Bind.text) ?? .null, c.foundInContext.map(Bind.text) ?? .null,
            c.provenanceConfidence.map(Bind.text) ?? .null, c.rightsOrLicense.map(Bind.text) ?? .null,
            c.mediaFormat.map(Bind.text) ?? .null, c.localMediaPath.map(Bind.text) ?? .null,
            c.mediaBytes.map(Bind.int) ?? .null, sha.map(Bind.text) ?? .null,
            c.perceptualHash.map(Bind.text) ?? .null, c.downloadStatus.map(Bind.text) ?? .null,
            c.downloadedAt.map(Bind.int) ?? .null, c.nextAction.map(Bind.text) ?? .null, .int(c.createdAt),
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func collectItems(catalogSlug: String, limit: Int = 10_000) throws -> [CollectItemRow] {
        try run("SELECT * FROM wiki_collect_item WHERE catalog_slug=? ORDER BY row_number, id LIMIT ?;",
                [.text(catalogSlug), .int(Int64(limit))]).map(curParseCollect)
    }

    public func collectCatalogs() throws -> [(slug: String, count: Int)] {
        try run("SELECT catalog_slug, COUNT(*) AS n FROM wiki_collect_item GROUP BY catalog_slug ORDER BY catalog_slug;", [])
            .map { ((($0["catalog_slug"] as? String) ?? ""), Int(curInt($0, "n") ?? 0)) }
    }
}

// MARK: - row parsers (file-private; tolerate Int64-or-Double numerics)

private func curInt(_ row: [String: Any], _ k: String) -> Int64? {
    if let i = row[k] as? Int64 { return i }
    if let d = row[k] as? Double { return Int64(d) }
    return nil
}

private func curParseInventory(_ r: [String: Any]) -> InventoryRecordRow {
    InventoryRecordRow(
        id: curInt(r, "id") ?? 0, slug: (r["slug"] as? String) ?? "", kind: (r["kind"] as? String) ?? "",
        status: (r["status"] as? String) ?? "", priority: (r["priority"] as? String) ?? "",
        title: (r["title"] as? String) ?? "", summary: r["summary"] as? String, nextAction: r["next_action"] as? String,
        tags: r["tags"] as? String, sources: r["sources"] as? String, origin: r["origin"] as? String,
        confidence: r["confidence"] as? String, bodyMd: r["body_md"] as? String, quantity: curInt(r, "quantity"),
        unit: r["unit"] as? String, itemState: r["item_state"] as? String,
        createdAt: curInt(r, "created_at") ?? 0, updatedAt: curInt(r, "updated_at") ?? 0,
        lastChecked: curInt(r, "last_checked"), lifecycleStatus: (r["lifecycle_status"] as? String) ?? "active")
}

private func curParseDataset(_ r: [String: Any]) -> DatasetManifestRow {
    DatasetManifestRow(
        id: curInt(r, "id") ?? 0, datasetID: (r["dataset_id"] as? String) ?? "", title: (r["title"] as? String) ?? "",
        status: (r["status"] as? String) ?? "", storage: (r["storage"] as? String) ?? "",
        locations: r["locations"] as? String, formats: r["formats"] as? String, schemaStatus: r["schema_status"] as? String,
        sizeBytes: curInt(r, "size_bytes"), recordCount: curInt(r, "record_count"),
        inventoryLinks: r["inventory_links"] as? String, rawSources: r["raw_sources"] as? String,
        license: r["license"] as? String, access: r["access"] as? String, checksum: r["checksum"] as? String,
        refreshCadence: r["refresh_cadence"] as? String, summary: r["summary"] as? String, bodyMd: r["body_md"] as? String,
        origin: r["origin"] as? String, createdAt: curInt(r, "created_at") ?? 0, updatedAt: curInt(r, "updated_at") ?? 0,
        lifecycleStatus: (r["lifecycle_status"] as? String) ?? "active")
}

private func curParseCollect(_ r: [String: Any]) -> CollectItemRow {
    CollectItemRow(
        id: curInt(r, "id") ?? 0, catalogSlug: (r["catalog_slug"] as? String) ?? "",
        rowNumber: curInt(r, "row_number") ?? 0, title: (r["title"] as? String) ?? "", aliases: r["aliases"] as? String,
        collectKind: r["collect_kind"] as? String, canonicalURL: r["canonical_url"] as? String,
        mediaURL: r["media_url"] as? String, sourceURL: r["source_url"] as? String,
        originPlatform: r["origin_platform"] as? String, creator: r["creator"] as? String,
        firstSeen: r["first_seen"] as? String, description: r["description"] as? String, evidence: r["evidence"] as? String,
        foundInContext: r["found_in_context"] as? String, provenanceConfidence: r["provenance_confidence"] as? String,
        rightsOrLicense: r["rights_or_license"] as? String, mediaFormat: r["media_format"] as? String,
        localMediaPath: r["local_media_path"] as? String, mediaBytes: curInt(r, "media_bytes"),
        sha256: r["sha256"] as? String, perceptualHash: r["perceptual_hash"] as? String,
        downloadStatus: r["download_status"] as? String, downloadedAt: curInt(r, "downloaded_at"),
        nextAction: r["next_action"] as? String, createdAt: curInt(r, "created_at") ?? 0)
}
