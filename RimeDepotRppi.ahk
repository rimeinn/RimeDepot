/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk
#Include RimeDepotConfig.ahk
#Include RimeDepotJson.ahk
#Include RimeDepotHttp.ahk

class RimeDepotCatalog {
    __New() {
        this.Entries := Map()
        this.Warnings := []
        this.Sources := []
    }

    Add(entry, id := "") {
        if !(entry is RimeDepotCatalogEntry) {
            entry := RimeDepotCatalogEntry(entry, id)
        }
        if id != "" && entry.Id = "" {
            entry.Id := id
        }
        if entry.Id = "" {
            entry.Id := entry.Name != "" ? entry.Name : entry.Repo
        }
        if entry.Name = "" {
            entry.Name := entry.Id
        }
        key := this._Key(entry.Id)
        if key = "" {
            throw RimeDepotCatalogError("Catalog entry has no usable identifier.")
        }
        if this.Entries.Has(key) {
            previous := this.Entries[key]
            ; Preserve a richer record when a child index only repeats a
            ; short record from its parent.
            if entry.Repo = "" {
                entry.Repo := previous.Repo
            }
            if entry.Dependencies.Length = 0 {
                entry.Dependencies := previous.Dependencies
            }
            if entry.Recipe = 0 {
                entry.Recipe := previous.Recipe
            }
            if entry.ReverseDependencies.Length = 0 {
                entry.ReverseDependencies := previous.ReverseDependencies
            }
        }
        this.Entries[key] := entry
        return entry
    }

    Resolve(value, allow_unknown := false) {
        if value is RimeDepotCatalogEntry {
            return value
        }
        if value is RimeDepotTarget {
            value := value.RawBase != "" ? value.RawBase : value.Name
        }
        value := String(value)
        candidates := [value]
        if InStr(value, "/") {
            candidates.Push(SubStr(value, InStr(value, "/", , -1) + 1))
            candidates.Push(RegExReplace(SubStr(value, InStr(value, "/", , -1) + 1), "i)^rime-", ""))
        }
        for _, candidate in candidates {
            key := this._Key(candidate)
            if key != "" && this.Entries.Has(key) {
                return this.Entries[key]
            }
            for _, entry in this.Entries {
                if this._Key(entry.Name) = key || this._Key(entry.Repo) = key {
                    return entry
                }
                repo_name := RegExReplace(SubStr(entry.Repo, InStr(entry.Repo, "/", , -1) + 1), "i)^rime-", "")
                if this._Key(repo_name) = key {
                    return entry
                }
            }
        }
        if allow_unknown {
            return 0
        }
        throw RimeDepotCatalogError("Unknown package dependency or target: " . value)
    }

    Validate() {
        local states := Map(), stack := [], key, entry, dependency, dependency_value
        for key, entry in this.Entries {
            for _, dependency in entry.Dependencies {
                dependency_value := RimeDepotCatalog.DependencyValue(dependency)
                if dependency_value = "" {
                    throw RimeDepotCatalogError("Empty dependency in catalog entry '" . entry.Id . "'.")
                }
                this.Resolve(dependency_value)
            }
        }
        for key, entry in this.Entries {
            if !states.Has(key) || states[key] = 0 {
                this._Visit(entry, states, stack)
            }
        }
        return this
    }

    ToArray() {
        result := []
        for _, entry in this.Entries {
            result.Push(entry)
        }
        return result
    }

    /** Serialize only the normalized catalog state needed for a safe snapshot. */
    ToSnapshot(root_url) {
        local entries, entry, item
        entries := []
        for _, entry in this.Entries {
            item := entry.ToMap()
            ; Raw is the original parser object and is not part of the
            ; normalized restore contract.  Excluding it also prevents an
            ; arbitrary extension object from becoming snapshot data.
            if item.Has("raw") {
                item.Delete("raw")
            }
            entries.Push(item)
        }
        return Map(
            "schema", RimeDepotRppiCache.SNAPSHOT_SCHEMA,
            "rootUrl", root_url,
            "sources", this.Sources.Clone(),
            "entries", entries
        )
    }

    /** Restore a snapshot while preserving RPPI reverse-lookup metadata. */
    static FromSnapshot(document) {
        local catalog, item, entry
        if !IsObject(document) || !document.Has("entries") || !(document["entries"] is Array) {
            throw RimeDepotCatalogError("Catalog snapshot has no entries array.")
        }
        catalog := RimeDepotCatalog()
        for _, item in document["entries"] {
            if !IsObject(item) {
                throw RimeDepotCatalogError("Catalog snapshot contains a non-object entry.")
            }
            entry := RimeDepotCatalogEntry(item, RimeDepotUtil.GetString(item, ["id", "Id", "key"], ""))
            catalog.Add(entry, entry.Id)
        }
        if document.Has("sources") && document["sources"] is Array {
            catalog.Sources := document["sources"].Clone()
        }
        catalog.Validate()
        return catalog
    }

    static DependencyValue(value) {
        if !IsObject(value) {
            return String(value)
        }
        return RimeDepotUtil.GetString(value, ["id", "name", "repo", "package", "target"], "")
    }

    _Visit(entry, states, stack) {
        key := this._Key(entry.Id)
        state := states.Has(key) ? states[key] : 0
        if state = 1 {
            cycle := []
            found := false
            for _, item in stack {
                if this._Key(item.Id) = key {
                    found := true
                }
                if found {
                    cycle.Push(item.Id)
                }
            }
            cycle.Push(entry.Id)
            throw RimeDepotCatalogError("Circular package dependency: " . RimeDepotCatalog.Join(cycle, " -> "))
        }
        if state = 2 {
            return
        }
        states[key] := 1
        stack.Push(entry)
        for _, dependency in entry.Dependencies {
            dependency_entry := this.Resolve(RimeDepotCatalog.DependencyValue(dependency))
            this._Visit(dependency_entry, states, stack)
        }
        stack.Pop()
        states[key] := 2
    }

    _Key(value) {
        value := String(value)
        value := RegExReplace(value, "i)^https?://github\.com/", "")
        value := RegExReplace(value, "i)\.git$", "")
        return StrLower(Trim(value, " /\\"))
    }

    static Join(values, separator) {
        result := ""
        for index, value in values {
            if index > 1 {
                result .= separator
            }
            result .= value
        }
        return result
    }
}

class RimeDepotRppiCache {
    static SNAPSHOT_SCHEMA := "rime-depot-catalog-snapshot-v1"

    __New(cache_path, atomic_writer := 0) {
        this.Root := RimeDepotUtil.JoinPath(cache_path, "rppi")
        this.AtomicWriter := atomic_writer
        RimeDepotUtil.EnsureDirectory(this.Root)
    }

    Read(url) {
        local paths, metadata, cached_url, body_hash, generation, body_file, body_path, body, response
        paths := this._Paths(url)
        if !FileExist(paths.Meta) {
            return 0
        }
        try {
            metadata := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
            cached_url := RimeDepotUtil.GetString(metadata, ["url", "URL"], "")
            if cached_url != url {
                return 0
            }
            body_hash := RimeDepotUtil.GetString(metadata, ["bodyHash", "body_hash"], "")
            generation := RimeDepotUtil.GetString(metadata, ["generation"], "")
            if body_hash = "" || generation = "" {
                return 0
            }
            body_file := RimeDepotUtil.GetString(metadata, ["BodyFile", "body_file"], "")
            if body_file != "" {
                body_path := this._BodyPath(url, body_file, generation)
                if !body_path || !FileExist(body_path) {
                    return 0
                }
            } else {
                ; Older releases used one fixed body file.  Keep accepting
                ; that format while all new commits use generation bodies.
                body_path := paths.Body
                if !FileExist(body_path) {
                    return 0
                }
            }
            body := FileRead(body_path, "UTF-8")
            if RimeDepotRppiCache.Hash(body) != body_hash {
                return 0
            }
            RimeDepotJson.Parse(body)
            response := RimeDepotHttpResponse(url, 200, body, Map(
                "ETag", RimeDepotUtil.GetString(metadata, ["etag", "ETag"], ""),
                "Last-Modified", RimeDepotUtil.GetString(metadata, ["lastModified", "last_modified"], "")
            ))
            response.FromCache := true
            response.StoredAt := RimeDepotUtil.GetString(metadata, ["storedAt", "stored_at"], "")
            return response
        } catch {
            ; A truncated body or metadata is not a usable cache entry.
            return 0
        }
    }

    Write(url, body, response) {
        local paths, old_body_file, old_generation, old_metadata, generation, body_file, body_path
        local metadata, old_body_path
        ; Validate before touching any cache file.  This is deliberately done
        ; here as well as in the catalog loader so callers cannot cache an
        ; arbitrary HTML error page as an index.
        RimeDepotJson.Parse(body)
        paths := this._Paths(url)
        old_body_file := ""
        old_generation := ""
        if FileExist(paths.Meta) {
            try {
                old_metadata := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
                old_body_file := RimeDepotUtil.GetString(old_metadata, ["BodyFile", "body_file"], "")
                old_generation := RimeDepotUtil.GetString(old_metadata, ["generation"], "")
            }
        }
        generation := RimeDepotUtil.NextId()
        body_file := paths.Prefix . generation . ".json"
        body_path := RimeDepotUtil.JoinPath(this.Root, body_file)
        metadata := RimeDepotJson.Stringify(Map(
            "url", url,
            "etag", response.ETag,
            "lastModified", response.LastModified,
            "storedAt", A_NowUTC,
            "generation", generation,
            "bodyHash", RimeDepotRppiCache.Hash(body),
            "BodyFile", body_file
        ))
        ; The generation body is durable before metadata points at it.  The
        ; metadata replacement is the commit point; the previous pointer and
        ; body remain intact if either write is interrupted.
        this._AtomicWrite(body_path, body)
        this._AtomicWrite(paths.Meta, metadata)
        old_body_path := this._BodyPath(url, old_body_file, old_generation)
        if old_body_path && old_body_path != body_path {
            try FileDelete(old_body_path)
        }
        return this.Read(url)
    }

    /** Read a complete, generation-validated normalized catalog snapshot. */
    ReadSnapshot(root_url) {
        local paths, metadata, body_file, generation, body_path, body_hash, body, document
        local sources, source_hash, snapshot, version_sha, complete
        paths := this._SnapshotPaths(root_url)
        if !FileExist(paths.Meta) {
            return 0
        }
        try {
            metadata := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
            if RimeDepotUtil.GetString(metadata, ["schema"], "") != RimeDepotRppiCache.SNAPSHOT_SCHEMA
                || RimeDepotUtil.GetString(metadata, ["rootUrl", "root_url"], "") != root_url {
                return 0
            }
            complete := RimeDepotUtil.GetValue(metadata, ["complete"], false)
            if complete != true {
                return 0
            }
            body_hash := RimeDepotUtil.GetString(metadata, ["bodyHash", "body_hash"], "")
            generation := RimeDepotUtil.GetString(metadata, ["generation"], "")
            body_file := RimeDepotUtil.GetString(metadata, ["BodyFile", "body_file"], "")
            if body_hash = "" || generation = "" || body_file = "" {
                return 0
            }
            body_path := this._SnapshotBodyPath(root_url, body_file, generation)
            if !body_path || !FileExist(body_path) {
                return 0
            }
            body := FileRead(body_path, "UTF-8")
            if RimeDepotRppiCache.Hash(body) != body_hash {
                return 0
            }
            document := RimeDepotJson.Parse(body)
            this._ValidateSnapshotDocument(document, root_url)
            ; Structural and hash checks are not enough: a normalized body must
            ; also describe a closed, acyclic dependency graph before it can
            ; become fallback catalog state.
            RimeDepotCatalog.FromSnapshot(document)
            sources := document["sources"]
            source_hash := RimeDepotRppiCache.Hash(RimeDepotJson.Stringify(sources))
            if RimeDepotUtil.GetString(metadata, ["sourceHash", "source_hash"], "") != source_hash {
                return 0
            }
            version_sha := StrLower(RimeDepotUtil.GetString(metadata, ["versionSha", "version_sha"], ""))
            if !RimeDepotRppiVersionProbe.IsFullSha(version_sha) {
                return 0
            }
            snapshot := Map(
                "Document", document,
                "Metadata", metadata,
                "VersionSha", version_sha,
                "ProbeETag", RimeDepotUtil.GetString(metadata, ["probeEtag", "probe_etag"], ""),
                "ProbeLastModified", RimeDepotUtil.GetString(
                    metadata, ["probeLastModified", "probe_last_modified"], ""),
                "CheckedAt", RimeDepotUtil.GetString(metadata, ["checkedAt", "checked_at"], ""),
                "StoredAt", RimeDepotUtil.GetString(metadata, ["storedAt", "stored_at"], ""),
                "Eligible", !!RimeDepotUtil.GetValue(metadata, ["eligible"], false)
            )
            return snapshot
        } catch {
            ; A partial snapshot must never be allowed to become catalog state.
            return 0
        }
    }

    /**
     * Commit a normalized snapshot body before replacing its metadata pointer.
     * The old generation remains authoritative if either write fails.
     */
    WriteSnapshot(root_url, document, version_sha, probe_response := 0, eligible := false) {
        local paths, old_metadata, old_body_file, old_generation, generation, body_file, body_path
        local body, metadata, old_body_path, sources, source_hash, probe_etag, probe_last_modified
        if document is RimeDepotCatalog {
            document := document.ToSnapshot(root_url)
        }
        this._ValidateSnapshotDocument(document, root_url)
        ; Reject semantically invalid generations before writing either the
        ; body or its metadata pointer.
        RimeDepotCatalog.FromSnapshot(document)
        version_sha := StrLower(String(version_sha))
        if !(version_sha ~= "i)^[0-9a-f]{40}$") {
            throw RimeDepotCatalogError("Catalog snapshot requires a full commit SHA.")
        }
        body := RimeDepotJson.Stringify(document)
        paths := this._SnapshotPaths(root_url)
        old_body_file := ""
        old_generation := ""
        if FileExist(paths.Meta) {
            try {
                old_metadata := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
                old_body_file := RimeDepotUtil.GetString(old_metadata, ["BodyFile", "body_file"], "")
                old_generation := RimeDepotUtil.GetString(old_metadata, ["generation"], "")
            }
        }
        generation := RimeDepotUtil.NextId()
        body_file := paths.Prefix . generation . ".json"
        body_path := RimeDepotUtil.JoinPath(this.Root, body_file)
        sources := document["sources"]
        source_hash := RimeDepotRppiCache.Hash(RimeDepotJson.Stringify(sources))
        probe_etag := probe_response && HasProp(probe_response, "ETag") ? probe_response.ETag : ""
        probe_last_modified := probe_response && HasProp(probe_response, "LastModified")
            ? probe_response.LastModified : ""
        metadata := RimeDepotJson.Stringify(Map(
            "schema", RimeDepotRppiCache.SNAPSHOT_SCHEMA,
            "rootUrl", root_url,
            "versionSha", version_sha,
            "probeEtag", probe_etag,
            "probeLastModified", probe_last_modified,
            "checkedAt", probe_response ? A_NowUTC : "",
            "storedAt", A_NowUTC,
            "generation", generation,
            "bodyHash", RimeDepotRppiCache.Hash(body),
            "sourceHash", source_hash,
            "eligible", !!eligible,
            "complete", true,
            "BodyFile", body_file
        ))
        this._AtomicWrite(body_path, body)
        this._AtomicWrite(paths.Meta, metadata)
        old_body_path := this._SnapshotBodyPath(root_url, old_body_file, old_generation)
        if old_body_path && old_body_path != body_path {
            try FileDelete(old_body_path)
        }
        return this.ReadSnapshot(root_url)
    }

    /** Update probe validators without rewriting the committed body. */
    TouchSnapshot(root_url, snapshot, version_sha := "", probe_response := 0) {
        local paths, metadata, source_metadata, body_file, generation, probe_etag, probe_last_modified, key, value
        if !snapshot || !IsObject(snapshot["Metadata"]) {
            return false
        }
        paths := this._SnapshotPaths(root_url)
        try {
            source_metadata := snapshot["Metadata"]
            metadata := Map()
            for key, value in source_metadata {
                metadata[key] := value
            }
            body_file := RimeDepotUtil.GetString(metadata, ["BodyFile", "body_file"], "")
            generation := RimeDepotUtil.GetString(metadata, ["generation"], "")
            if !this._SnapshotBodyPath(root_url, body_file, generation) {
                return false
            }
            if version_sha != "" {
                version_sha := StrLower(String(version_sha))
                if !(version_sha ~= "i)^[0-9a-f]{40}$") {
                    return false
                }
                metadata["versionSha"] := version_sha
            }
            probe_etag := probe_response && HasProp(probe_response, "ETag") ? probe_response.ETag : ""
            probe_last_modified := probe_response && HasProp(probe_response, "LastModified")
                ? probe_response.LastModified : ""
            if probe_etag != "" {
                metadata["probeEtag"] := probe_etag
            }
            if probe_last_modified != "" {
                metadata["probeLastModified"] := probe_last_modified
            }
            metadata["checkedAt"] := A_NowUTC
            this._AtomicWrite(paths.Meta, RimeDepotJson.Stringify(metadata))
            return true
        } catch {
            return false
        }
    }

    _ValidateSnapshotDocument(document, root_url) {
        local sources, entries, source, entry
        if !IsObject(document) || RimeDepotUtil.GetString(document, ["schema"], "")
            != RimeDepotRppiCache.SNAPSHOT_SCHEMA
            || RimeDepotUtil.GetString(document, ["rootUrl", "root_url"], "") != root_url {
            throw RimeDepotCatalogError("Catalog snapshot schema or root URL is invalid.")
        }
        sources := RimeDepotUtil.GetValue(document, ["sources"], 0)
        entries := RimeDepotUtil.GetValue(document, ["entries"], 0)
        if !(sources is Array) || sources.Length = 0 || sources[1] != root_url || !(entries is Array) {
            throw RimeDepotCatalogError("Catalog snapshot source or entry arrays are invalid.")
        }
        for _, source in sources {
            source := String(source)
            if !RimeDepotUtil.IsUrl(source) || source ~= "[\x00-\x20\\]" {
                throw RimeDepotCatalogError("Catalog snapshot contains an unsafe source URL.")
            }
        }
        for _, entry in entries {
            if !IsObject(entry) || RimeDepotUtil.GetString(entry, ["id", "Id", "key"], "") = "" {
                throw RimeDepotCatalogError("Catalog snapshot contains an invalid entry.")
            }
        }
        return true
    }

    _Paths(url) {
        key := RimeDepotRppiCache.Hash(url)
        return {
            Key: key,
            Prefix: "index-" . key . "-",
            Body: RimeDepotUtil.JoinPath(this.Root, "index-" . key . ".json"),
            Meta: RimeDepotUtil.JoinPath(this.Root, "index-" . key . ".meta.json")
        }
    }

    _SnapshotPaths(root_url) {
        local key
        key := RimeDepotRppiCache.Hash("snapshot|" . root_url)
        return {
            Key: key,
            Prefix: "snapshot-" . key . "-",
            Body: RimeDepotUtil.JoinPath(this.Root, "snapshot-" . key . ".json"),
            Meta: RimeDepotUtil.JoinPath(this.Root, "snapshot-" . key . ".meta.json")
        }
    }

    _SnapshotBodyPath(root_url, body_file, generation := "") {
        local paths := this._SnapshotPaths(root_url)
        if body_file = "" || body_file ~= "[\\/\r\n]" {
            return ""
        }
        if body_file != RegExReplace(body_file, ".*[\\/]", "") {
            return ""
        }
        if !RegExMatch(body_file, "^" . paths.Prefix . "[A-Za-z0-9-]+\.json$") {
            return ""
        }
        if generation != "" && body_file != paths.Prefix . generation . ".json" {
            return ""
        }
        return RimeDepotUtil.JoinPath(this.Root, body_file)
    }

    _BodyPath(url, body_file, generation := "") {
        local paths := this._Paths(url)
        if body_file = "" || body_file ~= "[\\/\r\n]" {
            return ""
        }
        if body_file != RegExReplace(body_file, ".*[\\/]", "") {
            return ""
        }
        if !RegExMatch(body_file, "^" . paths.Prefix . "[A-Za-z0-9-]+\.json$") {
            return ""
        }
        if generation != "" && body_file != paths.Prefix . generation . ".json" {
            return ""
        }
        return RimeDepotUtil.JoinPath(this.Root, body_file)
    }

    _AtomicWrite(path, content) {
        if this.AtomicWriter {
            if HasMethod(this.AtomicWriter, "Call") {
                return this.AtomicWriter.Call(path, content)
            }
            if HasMethod(this.AtomicWriter, "Write") {
                return this.AtomicWriter.Write(path, content)
            }
            throw RimeDepotError("Cache atomic writer has no Call or Write method.", "RimeDepotRppiCache")
        }
        return RimeDepotUtil.AtomicWrite(path, content)
    }

    static Hash(value) {
        hash := 5381
        for _, char in StrSplit(String(value)) {
            hash := Mod(hash * 33 + Ord(char), 2147483647)
        }
        return Format("{:x}", hash)
    }
}

/** One-request commit gate for the official raw GitHub index format. */
class RimeDepotRppiVersionProbe {
    __New(client, root_url, options := 0, snapshot := 0, callback := 0, job := 0) {
        this.Client := client
        this.RootUrl := root_url
        this.Options := IsObject(options) ? options : Map()
        this.Snapshot := snapshot
        this.Callback := callback
        this.Job := job
        this.Identity := 0
        this.Request := 0
        this.Done := false
    }

    Start() {
        local identity, ref, api_url, headers, snapshot_etag, snapshot_modified, request_options, request
        identity := RimeDepotRppiVersionProbe.ParseRawGithubUrl(this.RootUrl)
        if !identity {
            this._Finish(Map("ok", false, "error", RimeDepotCatalogError(
                "Commit probing requires an exact raw.githubusercontent.com URL.")))
            return this
        }
        this.Identity := identity
        ref := identity["ref"]
        ; A full SHA is already immutable and must not spend an API request.
        if RimeDepotRppiVersionProbe.IsFullSha(ref) {
            this._Finish(Map("ok", true, "sha", StrLower(ref), "response", 0, "notModified", false))
            return this
        }
        api_url := RimeDepotRppiVersionProbe.BuildApiUrl(identity)
        headers := Map(
            "Accept", "application/vnd.github+json",
            "X-GitHub-Api-Version", "2022-11-28",
            "User-Agent", "RimeDepot"
        )
        snapshot_etag := this.Snapshot ? RimeDepotUtil.GetString(this.Snapshot, ["ProbeETag"], "") : ""
        snapshot_modified := this.Snapshot
            ? RimeDepotUtil.GetString(this.Snapshot, ["ProbeLastModified"], "") : ""
        if snapshot_etag != "" {
            headers["If-None-Match"] := snapshot_etag
        }
        if snapshot_modified != "" {
            headers["If-Modified-Since"] := snapshot_modified
        }
        request_options := Map(
            "Proxy", RimeDepotUtil.GetString(this.Options, ["Proxy", "proxy"], ""),
            "Headers", headers
        )
        timeout := RimeDepotUtil.GetValue(this.Options, ["Timeout", "timeout"], 0)
        if timeout {
            request_options["Timeout"] := timeout
        }
        try {
            request := this.Client.GetAsync(api_url, ObjBindMethod(this, "_Response"), request_options, this.Job)
            if this.Done {
                this.Request := 0
            } else {
                this.Request := request
            }
        } catch as err {
            this._Finish(Map("ok", false, "error", err, "response", 0))
        }
        return this
    }

    Cancel(*) {
        local request
        if this.Done {
            return false
        }
        this.Done := true
        request := this.Request
        this.Request := 0
        if request && HasMethod(request, "Cancel") {
            try request.Cancel()
        }
        return true
    }

    _Response(response) {
        local document, item, sha
        this.Request := 0
        if this.Done {
            return
        }
        try {
            if response && response.Status = 304 {
                sha := this.Snapshot ? RimeDepotUtil.GetString(this.Snapshot, ["VersionSha"], "") : ""
                if !RimeDepotRppiVersionProbe.IsFullSha(sha) {
                    this._Finish(Map("ok", false, "error", RimeDepotCatalogError(
                        "GitHub returned 304 without a valid cached commit SHA."), "response", response))
                    return
                }
                this._Finish(Map("ok", true, "sha", StrLower(sha), "response", response, "notModified", true))
                return
            }
            if !response || !response.Ok() {
                this._Finish(Map("ok", false, "error", this._ResponseError(response), "response", response))
                return
            }
            document := RimeDepotJson.Parse(response.Body)
            item := document is Array ? (document.Length ? document[1] : 0) : document
            sha := IsObject(item) ? RimeDepotUtil.GetString(item, ["sha", "SHA"], "") : ""
            if !RimeDepotRppiVersionProbe.IsFullSha(sha) {
                this._Finish(Map("ok", false, "error", RimeDepotCatalogError(
                    "GitHub commit probe returned no full 40-character SHA."), "response", response))
                return
            }
            this._Finish(Map("ok", true, "sha", StrLower(sha), "response", response, "notModified", false))
        } catch as err {
            this._Finish(Map("ok", false, "error", err, "response", response))
        }
    }

    _ResponseError(response) {
        local status, message, document
        if response && response.Error {
            return response.Error
        }
        status := response ? response.Status : 0
        message := "GitHub commit probe failed (HTTP " . status . ")."
        if response && response.Body != "" {
            try {
                document := RimeDepotJson.Parse(response.Body)
                message := RimeDepotUtil.GetString(document, ["message"], message)
            }
        }
        return RimeDepotCatalogError(message)
    }

    _Finish(result) {
        if this.Done {
            return
        }
        this.Done := true
        if this.Callback {
            try {
                this.Callback.Call(result)
            } catch as err {
                OutputDebug("RimeDepot commit probe callback failed: " . err.Message)
            }
        }
    }

    static ParseRawGithubUrl(url) {
        local match, path, part, identity, owner, repo, ref
        url := String(url)
        if url = "" || InStr(url, "?") || InStr(url, "#") || InStr(url, Chr(92))
            || url ~= "[\x00-\x20]" || InStr(url, "%") {
            return 0
        }
        if !RegExMatch(url, "i)^https://raw\.githubusercontent\.com/([^/?#\\\s]+)/([^/?#\\\s]+)/([^/?#\\\s]+)/(.+)$", &match) {
            return 0
        }
        owner := match[1]
        repo := match[2]
        ref := match[3]
        path := match[4]
        if !(owner ~= "^[A-Za-z0-9][A-Za-z0-9_.-]*$")
            || !(repo ~= "^[A-Za-z0-9][A-Za-z0-9_.-]*$") {
            return 0
        }
        try RimeDepotUtil.ValidateRef(ref)
        catch {
            return 0
        }
        for _, part in StrSplit(path, "/") {
            if part = "" || part = "." || part = ".." || part ~= "[\x00-\x20]" {
                return 0
            }
        }
        identity := Map("owner", owner, "repo", repo, "ref", ref, "path", path)
        return identity
    }

    static IsFullSha(value) {
        return String(value) ~= "i)^[0-9a-f]{40}$"
    }

    static IsUniformSourceSet(root_url, sources) {
        local root, source, identity
        root := this.ParseRawGithubUrl(root_url)
        if !root || !(sources is Array) || sources.Length = 0 || sources[1] != root_url {
            return false
        }
        for _, source in sources {
            identity := this.ParseRawGithubUrl(String(source))
            if !identity || StrLower(identity["owner"]) != StrLower(root["owner"])
                || StrLower(identity["repo"]) != StrLower(root["repo"])
                || identity["ref"] != root["ref"] {
                return false
            }
        }
        return true
    }

    static CanFastPath(root_url, identity, snapshot, version_sha) {
        local document, sources, stored_sha
        if !snapshot || !IsObject(snapshot) {
            return false
        }
        if !RimeDepotUtil.GetValue(snapshot, ["Eligible"], false) {
            return false
        }
        stored_sha := RimeDepotUtil.GetString(snapshot, ["VersionSha"], "")
        if !this.IsFullSha(version_sha) || StrLower(stored_sha) != StrLower(version_sha) {
            return false
        }
        document := RimeDepotUtil.GetValue(snapshot, ["Document"], 0)
        sources := IsObject(document) ? RimeDepotUtil.GetValue(document, ["sources"], 0) : 0
        return this.IsUniformSourceSet(root_url, sources)
    }

    static BuildApiUrl(identity) {
        local owner, repo, ref, base
        owner := RimeDepotUtil.GetString(identity, ["owner"], "")
        repo := RimeDepotUtil.GetString(identity, ["repo"], "")
        ref := RimeDepotUtil.GetString(identity, ["ref"], "")
        base := "https://api.github.com/repos/" . this.EncodePathSegment(owner) . "/"
            . this.EncodePathSegment(repo) . "/commits"
        if ref = "HEAD" {
            return base . "?per_page=1"
        }
        return base . "/" . this.EncodePathSegment(ref)
    }

    static EncodePathSegment(value) {
        local byte_count, data, result, byte, char
        value := String(value)
        byte_count := StrPut(value, "UTF-8") - 1
        if byte_count <= 0 {
            return ""
        }
        data := Buffer(byte_count)
        StrPut(value, data, "UTF-8")
        result := ""
        Loop byte_count {
            byte := NumGet(data, A_Index - 1, "UChar")
            char := Chr(byte)
            if byte >= 0x30 && byte <= 0x39 || byte >= 0x41 && byte <= 0x5A
                || byte >= 0x61 && byte <= 0x7A || InStr("._~-", char) {
                result .= char
            } else {
                result .= "%" . Format("{:02X}", byte)
            }
        }
        return result
    }
}

/** Asynchronous loader for one or more linked RPPI index.json documents. */
class RimeDepotRppiLoadOperation {
    __New(client, cache, root_url, options, job, callback, refresh := false, force_reload := false) {
        this.Client := client
        this.Cache := cache
        this.RootUrl := root_url
        this.Options := IsObject(options) ? options : Map()
        this.Job := job
        this.Callback := callback
        this.Refresh := !!refresh
        this.ForceReload := !!force_reload
        ; Keep the category path alongside each URL.  A child index can be
        ; referenced by more than one category, so the first path is retained
        ; for deterministic display and search results.
        this.Queue := [{Url: root_url, CategoryPath: ""}]
        this.Visited := Map()
        this.Catalog := RimeDepotCatalog()
        this.Warnings := []
        this.ActiveRequest := 0
        this.ActiveToken := 0
        this.RequestGeneration := 0
        this.Done := false
        this._step_timer := ObjBindMethod(this, "_Step")
    }

    Start() {
        SetTimer(this._step_timer, -1)
        return this
    }

    Cancel(*) {
        request := this.ActiveRequest
        ; Invalidate the callback before cancelling the transport.  Some fake
        ; and real transports can report cancellation synchronously.
        this.ActiveToken := 0
        this.RequestGeneration += 1
        this.ActiveRequest := 0
        this.Done := true
        this.Queue := []
        if request && HasMethod(request, "Cancel") {
            request.Cancel()
        }
    }

    _Step() {
        if this.Done || this.Job.IsCancelled() {
            return
        }
        while this.Queue.Length {
            queued := this.Queue.RemoveAt(1)
            if IsObject(queued) {
                url := RimeDepotUtil.GetString(queued, ["Url", "url"], "")
                category_path := RimeDepotUtil.GetString(queued, ["CategoryPath", "category_path"], "")
            } else {
                url := String(queued)
                category_path := ""
            }
            if url = "" {
                continue
            }
            key := StrLower(url)
            if this.Visited.Has(key) {
                continue
            }
            this.Visited[key] := true
            this._Fetch(url, category_path)
            return
        }
        this._Finish()
    }

    _Fetch(url, category_path := "") {
        cached := this.ForceReload ? 0 : this.Cache.Read(url)
        headers := Map()
        if cached {
            if cached.ETag != "" {
                headers["If-None-Match"] := cached.ETag
            }
            if cached.LastModified != "" {
                headers["If-Modified-Since"] := cached.LastModified
            }
        }
        request_options := Map(
            "Proxy", RimeDepotUtil.GetString(this.Options, ["Proxy", "proxy"], ""),
            "Headers", headers
        )
        this.Job.ReportProgress(Map("phase", "catalog", "state", "fetching", "url", url,
            "cached", !!cached))
        this.RequestGeneration += 1
        token := this.RequestGeneration
        this.ActiveToken := token
        this.ActiveRequest := 0
        try {
            request := this.Client.GetAsync(
                url, ObjBindMethod(this, "_Response", token, url, cached, category_path), request_options, this.Job)
            ; GetAsync may invoke the callback before returning.  Do not keep
            ; a completed request handle as the next cancel target.
            if this.ActiveToken = token && !this.Done && !this.Job.IsCancelled() {
                this.ActiveRequest := request
            }
        } catch as err {
            if this.ActiveToken = token {
                this._Response(token, url, cached, category_path,
                    RimeDepotHttpResponse(url, 0, "", Map(), err))
            }
        }
    }

    _Response(token, url, cached, category_path, response) {
        if token != this.ActiveToken {
            return
        }
        ; Clear the token before any parsing, cache write, or callback can
        ; re-enter this operation.  Duplicate/late responses are ignored.
        this.ActiveToken := 0
        this.ActiveRequest := 0
        if this.Done || this.Job.IsCancelled() {
            return
        }
        try {
            if response && response.Status = 304 && cached {
                response := cached
            } else if response && response.Ok() {
                body := response.Body
                ; Parse and inspect before atomic cache replacement.
                document := RimeDepotJson.Parse(body)
                this.Cache.Write(url, body, response)
                this._Consume(document, url, category_path)
                this.Job.ReportProgress(Map("phase", "catalog", "state", "loaded", "url", url,
                    "cached", false))
                SetTimer(this._step_timer, -1)
                return
            } else if cached {
                cached.Stale := true
                warning := Map("kind", "stale", "url", url,
                    "message", "Network failed; using the last complete cached RPPI index.",
                    "error", response && response.Error ? response.Error : "HTTP status " . (response ? response.Status : 0))
                this.Warnings.Push(warning)
                this.Catalog.Warnings.Push(warning)
                this.Job.ReportProgress(Map("phase", "catalog", "state", "warning", "warning", warning))
                this._Consume(RimeDepotJson.Parse(cached.Body), url, category_path)
                SetTimer(this._step_timer, -1)
                return
            } else {
                message := response && response.Error ? response.Error.Message : "HTTP status " . (response ? response.Status : 0)
                throw RimeDepotCatalogError("Unable to load RPPI index '" . url . "': " . message)
            }
            this._Consume(RimeDepotJson.Parse(response.Body), url, category_path)
            SetTimer(this._step_timer, -1)
        } catch as err {
            this.Done := true
            this.Callback.Call(0, err, this.Warnings)
        }
    }

    _Consume(document, url, category_path := "") {
        this.Catalog.Sources.Push(url)
        this._Collect(document, url, "", "", category_path)
    }

    _Collect(value, base_url, suggested_id := "", container := "", category_path := "") {
        if value is Array {
            for _, item in value {
                if !IsObject(item) {
                    if RimeDepotUtil.IsUrl(String(item)) || container = "links" {
                        this._QueueUrl(base_url, String(item), category_path)
                    }
                } else {
                    this._Collect(item, base_url, "", container, category_path)
                }
            }
            return
        }
        if !IsObject(value) {
            if RimeDepotUtil.IsUrl(String(value)) || container = "links" {
                this._QueueUrl(base_url, String(value), category_path)
            } else if suggested_id != "" && container != "" {
                this._AddScalarEntry(suggested_id, value, base_url, category_path)
            }
            return
        }

        ; Official RPPI documents put package records below a parent
        ; `categories` array and expose records in a child document's
        ; `recipes` array.  Handle those containers before the generic entry
        ; test: a category's display `name` must not become a fake package.
        if value.Has("categories") {
            this._CollectCategories(value["categories"], base_url, category_path)
        }
        if value.Has("recipes") {
            this._CollectRecipes(value["recipes"], base_url, category_path)
        }

        if this._IsEntry(value) && (suggested_id != "" || container != "" || base_url = this.RootUrl) {
            entry_data := this._CopyMap(value)
            if suggested_id != "" && !entry_data.Has("id") {
                entry_data["id"] := suggested_id
            }
            this._SetCategory(entry_data, category_path)
            entry := this.Catalog.Add(RimeDepotCatalogEntry(entry_data, suggested_id), suggested_id)
            if entry.IndexUrl = "" {
                entry.IndexUrl := base_url
            }
            return
        }

        known_containers := ["entries", "packages", "repos", "repositories", "repo", "catalog", "data", "items"]
        for _, field in known_containers {
            if value.Has(field) {
                this._CollectContainer(value[field], base_url, field, category_path)
            }
        }
        for _, field in ["index", "indexes", "sources", "children", "includes", "manifests"] {
            if value.Has(field) {
                this._Collect(value[field], base_url, "", "links", category_path)
            }
        }

        ; Some RPPI versions use a map directly at the root: package id ->
        ; metadata.  Traverse only unclaimed map members as entries/links.
        for key, item in value {
            if key ~= "i)^(categories|recipes|entries|packages|repos|repositories|repo|catalog|data|items|index|indexes|sources|children|includes|manifests|date|last_update|lastUpdated)$" {
                continue
            }
            if !IsObject(item) && RimeDepotUtil.IsUrl(String(item)) {
                this._QueueUrl(base_url, String(item), category_path)
            } else if IsObject(item) && this._IsEntry(item) {
                this._Collect(item, base_url, key, "map", category_path)
            }
        }
    }

    _CollectCategories(value, base_url, parent_category := "") {
        if value is Array {
            for _, category in value {
                if IsObject(category) {
                    this._CollectCategory(category, base_url, parent_category)
                }
            }
            return
        }
        if IsObject(value) {
            ; Accept a mapping keyed by category id as a compatibility form.
            for key, category in value {
                if IsObject(category) {
                    this._CollectCategory(category, base_url, parent_category, key)
                }
            }
        }
    }

    _CollectCategory(category, base_url, parent_category := "", suggested_name := "") {
        category_name := RimeDepotUtil.GetString(
            category, ["display_name", "displayName", "title", "name", "label"], suggested_name)
        category_key := RimeDepotUtil.GetString(category, ["key", "id", "path"], "")
        category_path := parent_category
        if category_name != "" {
            category_path := category_path = "" ? category_name : parent_category . " / " . category_name
        }
        if category.Has("categories") {
            this._CollectCategories(category["categories"], base_url, category_path)
        }
        if category.Has("recipes") {
            this._CollectRecipes(category["recipes"], base_url, category_path)
        }
        if category.Has("entries") {
            this._CollectContainer(category["entries"], base_url, "entries", category_path)
        }
        ; Official RPPI category records identify their child index by key.
        ; Resolve it relative to the parent index without treating the key as
        ; a package record, while carrying the display path to child recipes.
        if category_key != "" {
            this._QueueUrl(base_url, category_key . "/index.json", category_path)
        }
        ; A category may point to a child index directly.  Do not treat its
        ; descriptive URL as a package record when `recipes` is absent.
        for _, field in ["index", "url", "source", "href"] {
            if category.Has(field) && !IsObject(category[field]) {
                candidate := String(category[field])
                if candidate != "" {
                    this._QueueUrl(base_url, candidate, category_path)
                }
            }
        }
    }

    _CollectRecipes(value, base_url, category_path := "") {
        if value is Array {
            for _, recipe in value {
                if IsObject(recipe) {
                    this._Collect(recipe, base_url, "", "recipes", category_path)
                } else if RimeDepotUtil.IsUrl(String(recipe)) {
                    this._QueueUrl(base_url, String(recipe), category_path)
                }
            }
            return
        }
        if IsObject(value) {
            for key, recipe in value {
                if IsObject(recipe) {
                    this._Collect(recipe, base_url, key, "recipes", category_path)
                } else if RimeDepotUtil.IsUrl(String(recipe)) {
                    this._QueueUrl(base_url, String(recipe), category_path)
                }
            }
        } else if RimeDepotUtil.IsUrl(String(value)) {
            this._QueueUrl(base_url, String(value), category_path)
        }
    }

    _CollectContainer(value, base_url, container, category_path := "") {
        if value is Array {
            for _, item in value {
                if IsObject(item) {
                    this._Collect(item, base_url, "", container, category_path)
                } else if RimeDepotUtil.IsUrl(String(item)) {
                    this._QueueUrl(base_url, String(item), category_path)
                }
            }
            return
        }
        if !IsObject(value) {
            return
        }
        if this._IsEntry(value) {
            this._Collect(value, base_url, "", container, category_path)
            return
        }
        for key, item in value {
            if IsObject(item) {
                this._Collect(item, base_url, key, container, category_path)
            } else if RimeDepotUtil.IsUrl(String(item)) {
                ; A repositories map may contain linked index documents.
                this._QueueUrl(base_url, String(item), category_path)
            } else if container = "repos" || container = "repositories" || container = "repo" {
                this._AddScalarEntry(key, item, base_url, category_path)
            }
        }
    }

    _AddScalarEntry(id, value, base_url, category_path := "") {
        data := Map("id", id, "name", id, "repo", String(value), "indexUrl", base_url)
        this._SetCategory(data, category_path)
        this.Catalog.Add(data, id)
    }

    _SetCategory(data, category_path) {
        if category_path != "" {
            data["category_path"] := category_path
            if !data.Has("category") {
                data["category"] := category_path
            }
        }
    }

    _IsEntry(value) {
        for _, key in ["repo", "repository", "package", "dependencies", "branch", "tag", "sha", "ref", "license", "labels", "schemas", "recipe"] {
            if value.Has(key) {
                return true
            }
        }
        return false
    }

    _CopyMap(value) {
        result := Map()
        for key, item in value {
            result[key] := item
        }
        return result
    }

    _QueueUrl(base_url, child, category_path := "") {
        child := RimeDepotRppiLoadOperation.ResolveUrl(base_url, child)
        if child != "" && !this.Visited.Has(StrLower(child)) {
            this.Queue.Push({Url: child, CategoryPath: category_path})
        }
    }

    _Finish() {
        if this.Done {
            return
        }
        try {
            this.Catalog.Validate()
            this.Done := true
            this.Callback.Call(this.Catalog, 0, this.Warnings)
        } catch as err {
            this.Done := true
            this.Callback.Call(0, err, this.Warnings)
        }
    }

    static ResolveUrl(base, child) {
        child := String(child)
        if RimeDepotUtil.IsUrl(child) {
            return child
        }
        if SubStr(child, 1, 2) = "//" {
            scheme := RegExMatch(base, "i)^(https?):", &match) ? match[1] : "https"
            return scheme . ":" . child
        }
        if SubStr(child, 1, 1) = "/" {
            if RegExMatch(base, "i)^(https?://[^/]+)", &match) {
                return match[1] . child
            }
            return ""
        }
        ; Keep the authority's double slash intact.  Splitting the complete
        ; URL on `/` and joining it again turns `https://` into `https:/`.
        ; Resolve the path separately, then prepend the original authority.
        if RegExMatch(base, "i)^(https?://[^/]+)(/.*)?$", &match) {
            authority := match[1]
            base_path := match[2] != "" ? match[2] : "/"
            base_path := RegExReplace(base_path, "/[^/]*$", "/")
            parts := StrSplit(base_path . child, "/")
            output := []
            for _, part in parts {
                if part = "" || part = "." {
                    continue
                }
                if part = ".." {
                    if output.Length {
                        output.Pop()
                    }
                    continue
                }
                output.Push(part)
            }
            return authority . "/" . RimeDepotCatalog.Join(output, "/")
        }
        base := RegExReplace(base, "[/\\][^/\\]*$", "")
        parts := StrSplit(base . "/" . child, "/")
        output := []
        for _, part in parts {
            if part = "" || part = "." {
                continue
            }
            if part = ".." {
                if output.Length {
                    output.Pop()
                }
                continue
            }
            output.Push(part)
        }
        return RimeDepotCatalog.Join(output, "/")
    }
}
