/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * The callbacks accepted by RimeDepotService operations.
 *
 * Callback arguments are `(job, value)` for progress and completion, and
 * `(job, error)` for errors.  A callback may be a function object, bound
 * function, or any object exposing Call().
 */
class RimeDepotCallbacks {
    __New(progress := 0, complete := 0, error := 0) {
        this.Progress := progress
        this.Complete := complete
        this.Error := error
    }

    ReportProgress(job, value) {
        if this.Progress {
            return this.Progress.Call(job, value)
        }
    }

    ReportComplete(job, value) {
        if this.Complete {
            return this.Complete.Call(job, value)
        }
    }

    ReportError(job, value) {
        if this.Error {
            return this.Error.Call(job, value)
        }
    }
}

/** A cancellable asynchronous operation owned by one RimeDepotService. */
class RimeDepotJob {
    __New(kind := "", callbacks := 0, service := 0) {
        this.Id := RimeDepotUtil.NextId()
        this.Kind := kind
        this.Status := "pending"
        this.Result := ""
        this.Error := ""
        this.Progress := 0
        this.CreatedAt := A_TickCount
        this.StartedAt := 0
        this.FinishedAt := 0
        this.CancelRequested := false
        this._callbacks := callbacks is RimeDepotCallbacks ? callbacks : RimeDepotCallbacks()
        this._service := service
        this._cancel_handler := 0
        this._finish_handler := 0
    }

    Start() {
        if this.Status != "pending" {
            return this
        }
        this.Status := "running"
        this.StartedAt := A_TickCount
        return this
    }

    SetCancelHandler(handler) {
        this._cancel_handler := handler
        if this.CancelRequested && handler {
            handler.Call(this)
        }
        return this
    }

    SetFinishHandler(handler) {
        this._finish_handler := handler
        return this
    }

    IsDone() {
        return this.Status = "completed" || this.Status = "failed" || this.Status = "cancelled"
    }

    IsCancelled() {
        return this.CancelRequested || this.Status = "cancelled"
    }

    Cancel() {
        if this.IsDone() {
            return false
        }
        this.CancelRequested := true
        if this._cancel_handler {
            try {
                this._cancel_handler.Call(this)
            } catch as err {
                this.Fail(err)
                return true
            }
        }
        if !this.IsDone() {
            this.Fail(RimeDepotCancelledError("The RimeDepot job was cancelled."), true)
        }
        return true
    }

    ReportProgress(value) {
        if this.IsDone() {
            return false
        }
        this.Progress := value
        try {
            this._callbacks.ReportProgress(this, value)
        } catch as err {
            this.Fail(err)
            return false
        }
        return true
    }

    Complete(value := "") {
        if this.IsDone() {
            return false
        }
        this.Status := "completed"
        this.Result := value
        this.FinishedAt := A_TickCount
        try {
            this._callbacks.ReportComplete(this, value)
        } catch as err {
            ; A completion observer cannot undo an operation.  Preserve the
            ; operation result while exposing observer failures to callers
            ; through OutputDebug rather than recursively failing the job.
            OutputDebug("RimeDepot completion callback failed: " . err.Message)
        }
        if this._finish_handler {
            this._finish_handler.Call(this)
        }
        return true
    }

    Fail(error, cancelled := false) {
        if this.IsDone() {
            return false
        }
        if !IsObject(error) {
            error := Error(String(error))
        }
        this.Error := error
        this.Status := cancelled || error is RimeDepotCancelledError ? "cancelled" : "failed"
        this.FinishedAt := A_TickCount
        try {
            this._callbacks.ReportError(this, error)
        } catch as callback_error {
            OutputDebug("RimeDepot error callback failed: " . callback_error.Message)
        }
        if this._finish_handler {
            this._finish_handler.Call(this)
        }
        return true
    }
}

/** A normalized catalog item.  Raw index fields are retained for extensions. */
class RimeDepotCatalogEntry {
    __New(value := 0, id := "") {
        this.Id := id
        this.Name := id
        this.Repo := ""
        this.Ref := ""
        this.Branch := ""
        this.Tag := ""
        this.Sha := ""
        this.RefKind := ""
        this.Labels := []
        this.Category := ""
        this.CategoryPath := ""
        this.Schemas := []
        this.Dependencies := []
        ; RPPI uses this for optional reverse-lookup packages, not the
        ; inverse of the hard dependency graph.
        this.ReverseDependencies := []
        this.License := ""
        this.Recipe := 0
        this.Recipes := Map()
        this.Description := ""
        this.IndexUrl := ""
        this.Source := ""
        this.Raw := value
        this.Files := []
        this.Url := ""
        this.ArchiveUrl := ""

        if !IsObject(value) {
            if value != "" {
                this.Repo := String(value)
            }
            return
        }
        this._Read(value, id)
    }

    _Read(value, id) {
        this.Id := RimeDepotUtil.GetString(value, ["id", "Id", "key"], id)
        this.Name := RimeDepotUtil.GetString(value, ["name", "Name", "package"], this.Id)
        this.Repo := RimeDepotUtil.GetString(value, ["repo", "repository", "Repo", "source"], "")
        this.Branch := RimeDepotUtil.GetString(value, ["branch", "Branch"], "")
        this.Tag := RimeDepotUtil.GetString(value, ["tag", "Tag"], "")
        this.Sha := RimeDepotUtil.GetString(value, ["sha", "SHA", "commit", "revision"], "")
        this.Ref := RimeDepotUtil.GetString(value, ["ref", "Ref"], "")
        this.RefKind := StrLower(RimeDepotUtil.GetString(value, ["ref_kind", "refKind", "kind"], ""))
        if this.Branch = "" && this.Tag = "" && this.Sha = "" && this.Ref != "" {
            if this.RefKind = "commit" || this.RefKind = "sha" {
                this.Sha := this.Ref
            } else if this.RefKind = "tag" {
                this.Tag := this.Ref
            } else if this.RefKind = "branch" {
                this.Branch := this.Ref
            } else if this.Ref ~= "i)^[0-9a-f]{7,40}$" {
                ; RPPI records historically used only `ref`.  Preserve the
                ; existing SHA shorthand convention even without ref_kind.
                this.Sha := this.Ref
            } else {
                this.Branch := this.Ref
            }
        }
        if this.Branch != "" {
            RimeDepotUtil.ValidateRef(this.Branch)
        }
        if this.Tag != "" {
            RimeDepotUtil.ValidateRef(this.Tag)
        }
        if this.Sha != "" {
            RimeDepotUtil.ValidateRef(this.Sha, true)
        }
        this.Url := RimeDepotUtil.GetString(value, ["url", "homepage", "web"], "")
        this.ArchiveUrl := RimeDepotUtil.GetString(value, ["archive", "archiveUrl", "archive_url"], "")
        if this.RefKind = "commit" {
            this.RefKind := "sha"
        }
        if this.RefKind = "" {
            this.RefKind := this.Branch != "" ? "branch" : (this.Tag != "" ? "tag" : (this.Sha != "" ? "sha" : ""))
        }
        this.Description := RimeDepotUtil.GetString(value, ["description", "summary"], "")
        this.License := RimeDepotUtil.GetString(value, ["license", "licence"], "")
        this.IndexUrl := RimeDepotUtil.GetString(value, ["indexUrl", "index_url", "sourceIndex"], "")
        this.Source := RimeDepotUtil.GetString(value, ["source"], "")

        this.Labels := RimeDepotUtil.ToArray(RimeDepotUtil.GetValue(value, ["labels", "label", "categories"], []))
        this.Category := RimeDepotUtil.GetString(value, ["category", "Category"], "")
        this.CategoryPath := RimeDepotUtil.GetString(value, ["category_path", "categoryPath", "CategoryPath"], this.Category)
        this.Schemas := RimeDepotUtil.ToArray(RimeDepotUtil.GetValue(value, ["schemas", "schema"], []))
        this.Dependencies := RimeDepotUtil.ToArray(RimeDepotUtil.GetValue(value, ["dependencies", "depends", "requires"], []))
        this.ReverseDependencies := RimeDepotUtil.ToArray(
            RimeDepotUtil.GetValue(value, ["reverseDependencies", "reverse_dependencies", "dependents"], []))
        this.Files := RimeDepotUtil.ToArray(RimeDepotUtil.GetValue(value, ["files", "installFiles", "install_files"], []))
        this.Recipe := RimeDepotUtil.GetValue(value, ["recipe"], 0)

        recipes := RimeDepotUtil.GetValue(value, ["recipes"], 0)
        if IsObject(recipes) && !(recipes is Array) {
            this.Recipes := recipes
        }
        if !this.Repo {
            this.Repo := this.Id
        }
    }

    ToMap() {
        return Map(
            "id", this.Id,
            "name", this.Name,
            "repo", this.Repo,
            "ref", this.Ref,
            "branch", this.Branch,
            "tag", this.Tag,
            "sha", this.Sha,
            "ref_kind", this.RefKind,
            "labels", this.Labels,
            "category", this.Category,
            "category_path", this.CategoryPath,
            "schemas", this.Schemas,
            "dependencies", this.Dependencies,
            "reverseDependencies", this.ReverseDependencies,
            "license", this.License,
            "recipe", this.Recipe,
            "recipes", this.Recipes,
            "description", this.Description,
            "indexUrl", this.IndexUrl,
            "source", this.Source,
            "url", this.Url,
            "archiveUrl", this.ArchiveUrl,
            "raw", this.Raw
        )
    }
}

/** Parsed install target, including an optional branch/tag/SHA and recipe. */
class RimeDepotTarget {
    __New(value := "", ref := "", recipe := "", parameters := 0) {
        ; Maps/objects are the structured API.  String(Map()) is not a useful
        ; representation in AHK v2 and, more importantly, would discard URL
        ; and archive fields before they reach the installer.
        this.Raw := IsObject(value) && !(value is String)
            ? RimeDepotUtil.GetString(value, ["raw", "Raw"], "") : String(value)
        this.RawBase := ""
        this.Name := ""
        this.Repo := ""
        this.SourceExplicit := false
        this.ArchiveUrl := ""
        this.Ref := ref
        this.Branch := ""
        this.Tag := ""
        this.Sha := ""
        this.RefKind := ""
        this.Recipe := recipe
        this.Parameters := parameters is Map ? parameters : Map()
        this.Options := Map()

        if IsObject(value) && !(value is String) {
            this.Name := RimeDepotUtil.GetString(value, ["name", "Name", "id", "Id"], "")
            this.Repo := RimeDepotUtil.GetString(value, ["repo", "repository", "Repo", "source"], "")
            source_url := RimeDepotUtil.GetString(value, ["url", "URL"], "")
            this.ArchiveUrl := RimeDepotUtil.GetString(value, ["archive", "archiveUrl", "archive_url"], "")
            this.SourceExplicit := this.Repo != "" || source_url != "" || this.ArchiveUrl != ""
            if this.Repo = "" {
                this.Repo := source_url
            }
            if this.ArchiveUrl = "" && this.Repo != "" && RimeDepotTarget.IsArchiveUrl(this.Repo) {
                this.ArchiveUrl := this.Repo
            }
            if this.Repo = "" && this.ArchiveUrl != "" {
                ; An explicit archive is a complete direct source even when
                ; no repository display name was supplied.
                this.Repo := this.ArchiveUrl
            }
            if this.ArchiveUrl = "" && source_url != "" && RimeDepotTarget.IsArchiveUrl(source_url) {
                this.ArchiveUrl := source_url
            }
            this.RefKind := StrLower(RimeDepotUtil.GetString(value, ["ref_kind", "refKind", "kind"], ""))
            branch := RimeDepotUtil.GetString(value, ["branch", "Branch"], "")
            tag := RimeDepotUtil.GetString(value, ["tag", "Tag"], "")
            sha := RimeDepotUtil.GetString(value, ["sha", "SHA", "commit", "revision"], "")
            explicit_ref := RimeDepotUtil.GetString(value, ["ref", "Ref"], "")
            if sha != "" {
                this.Ref := sha
                this.RefKind := "sha"
            } else if tag != "" {
                this.Ref := tag
                this.RefKind := "tag"
            } else if branch != "" {
                this.Ref := branch
                this.RefKind := "branch"
            } else if explicit_ref != "" {
                this.Ref := explicit_ref
            }
            this.Recipe := RimeDepotUtil.GetString(value, ["recipe", "Recipe"], this.Recipe)
            parameters_value := RimeDepotUtil.GetValue(value, ["parameters", "options"], 0)
            if IsObject(parameters_value) && !(parameters_value is Array) {
                this.Parameters := parameters_value
            }
            this.Options := this.Parameters
            if this.RefKind = "" {
                this.RefKind := this.Ref != "" && this.Ref ~= "i)^[0-9a-f]{7,40}$" ? "sha"
                    : (this.Ref != "" ? "branch" : "default")
            }
            if this.RefKind = "commit" {
                this.RefKind := "sha"
            }
            if this.RefKind != "" && this.RefKind != "default" && this.Ref = "" {
                throw RimeDepotTargetError("A Git ref kind requires a ref value.")
            }
            if this.RefKind != "default" && this.RefKind != "" {
                if this.RefKind != "branch" && this.RefKind != "tag" && this.RefKind != "sha" {
                    throw RimeDepotTargetError("Unsupported Git ref kind: " . this.RefKind)
                }
            }
            if this.RefKind = "sha" && this.Ref != "" {
                this.Sha := this.Ref
            } else if this.RefKind = "tag" && this.Ref != "" {
                this.Tag := this.Ref
            } else if this.RefKind = "branch" && this.Ref != "" {
                this.Branch := this.Ref
            } else if this.Ref != "" {
                throw RimeDepotTargetError("A Git ref kind requires a ref value.")
            }
            this.RawBase := this.Repo != "" ? this.Repo : this.Name
            if this.RawBase = "" {
                throw RimeDepotTargetError("An install target must specify a package name or repository.")
            }
            if this.Ref != "" {
                RimeDepotUtil.ValidateRef(this.Ref, this.Sha != "")
            }
            return
        }
        if RimeDepotTarget.IsStructuredUrl(String(value)) {
            this.Repo := String(value)
            this.SourceExplicit := true
            this.RawBase := this.Repo
            this.RefKind := this.Ref != "" ? (this.Ref ~= "i)^[0-9a-f]{7,40}$" ? "sha" : "branch") : "default"
            this.Name := this.Repo
            if RimeDepotTarget.IsArchiveUrl(this.Repo) {
                this.ArchiveUrl := this.Repo
            }
            if this.Ref != "" {
                if this.RefKind = "sha" {
                    this.Sha := this.Ref
                } else {
                    this.Branch := this.Ref
                }
                RimeDepotUtil.ValidateRef(this.Ref, this.Sha != "")
            }
            return
        }
        this._Parse(String(value))
    }

    static Parse(value) {
        return RimeDepotTarget(value)
    }

    _Parse(value) {
        if value = "" {
            throw RimeDepotTargetError("An install target cannot be empty.")
        }
        parts := StrSplit(value, ":")
        base := parts[1]
        if parts.Length >= 2 {
            this.Recipe := parts[2]
        }
        if parts.Length >= 3 {
            Loop parts.Length - 2 {
                option := parts[A_Index + 2]
                if option = "" {
                    continue
                }
                equal_at := InStr(option, "=")
                if !equal_at {
                    throw RimeDepotTargetError("Recipe option must use key=value: " . option)
                }
                key := SubStr(option, 1, equal_at - 1)
                val := SubStr(option, equal_at + 1)
                if !RimeDepotUtil.IsSafeKey(key) {
                    throw RimeDepotTargetError("Unsafe recipe option name: " . key)
                }
                this.Parameters[key] := val
            }
        }

        at := InStr(base, "@", , -1)
        if at {
            this.Ref := SubStr(base, at + 1)
            base := SubStr(base, 1, at - 1)
        }
        if this.Ref != "" {
            RimeDepotUtil.ValidateRef(this.Ref)
        }
        this.RawBase := base
        this.Name := base
        this.Repo := base
        this.SourceExplicit := InStr(base, "/") > 0
        if this.Ref ~= "i)^[0-9a-f]{7,40}$" {
            this.Sha := this.Ref
            this.RefKind := "sha"
        } else if this.Ref {
            this.Branch := this.Ref
            this.RefKind := "branch"
        } else {
            this.RefKind := "default"
        }
    }

    ToString() {
        result := this.Name
        if this.Ref {
            result .= "@" . this.Ref
        }
        if this.Recipe {
            result .= ":" . this.Recipe
            for key, value in this.Parameters {
                result .= ":" . key . "=" . value
            }
        }
        return result
    }

    static IsStructuredUrl(value) {
        value := String(value)
        return value ~= "i)^https?://[^\s]+$"
            || value ~= "i)^ssh://[^\s]+$"
            || value ~= "i)^git@[^:\s]+:[^\s]+$"
    }

    static IsArchiveUrl(value) {
        return String(value) ~= "i)^https?://[^\s]+\.zip(?:[?#][^\s]*)?$"
    }
}

class RimeDepotError extends Error {
    __New(message, what := "RimeDepot") {
        super.__New(message)
        this.What := what
    }
}

class RimeDepotBusyError extends RimeDepotError {
    __New(message := "RimeDepotService already has an active job.") {
        super.__New(message, "RimeDepotService")
    }
}

class RimeDepotCancelledError extends RimeDepotError {
    __New(message := "The RimeDepot job was cancelled.") {
        super.__New(message, "RimeDepotJob.Cancel")
    }
}

class RimeDepotTargetError extends RimeDepotError {
    __New(message) {
        super.__New(message, "RimeDepotTarget")
    }
}

class RimeDepotCatalogError extends RimeDepotError {
    __New(message) {
        super.__New(message, "RimeDepotCatalog")
    }
}

class RimeDepotUnsupportedError extends RimeDepotError {
    __New(message) {
        super.__New(message, "RimeDepotUnsupported")
    }
}

class RimeDepotSecurityError extends RimeDepotError {
    __New(message) {
        super.__New(message, "RimeDepotSecurity")
    }
}

/** Small dependency-free helpers shared by the RimeDepot modules. */
class RimeDepotUtil {
    static NextId() {
        static sequence := 0
        sequence += 1
        return Format("{}-{}-{}", A_TickCount, A_Now, sequence)
    }

    static GetValue(value, keys, default := "") {
        if !IsObject(value) {
            return default
        }
        for _, key in keys {
            try {
                if value.Has(key) {
                    return value[key]
                }
            } catch {
                try {
                    if HasProp(value, key) {
                        return value.%key%
                    }
                }
            }
        }
        return default
    }

    static GetString(value, keys, default := "") {
        result := this.GetValue(value, keys, default)
        return IsObject(result) ? default : String(result)
    }

    static ToArray(value) {
        if !IsObject(value) {
            return value = "" ? [] : [value]
        }
        if value is Array {
            return value
        }
        result := []
        for key, item in value {
            ; A mapping is useful as a dependency list too.  Preserve its
            ; values when they are scalar and its keys when they are flags.
            if item = true {
                result.Push(key)
            } else {
                result.Push(item)
            }
        }
        return result
    }

    static IsSafeKey(value) {
        return value != "" && value ~= "i)^[a-z_][a-z0-9_.-]*$"
    }

    static ValidateRef(value, sha_only := false) {
        value := String(value)
        if value = "" || value ~= "[\x00-\x20~^:?*\[\\]" || value ~= "\.\.|@\{"
            || SubStr(value, 1, 1) = "/" || SubStr(value, -1) = "/"
            || SubStr(value, -1) = "." || SubStr(value, 1, 1) = "-" {
            throw RimeDepotTargetError("Unsafe Git ref: " . value)
        }
        if sha_only && !(value ~= "i)^[0-9a-f]{7,40}$") {
            throw RimeDepotTargetError("Git SHA must contain 7 to 40 hexadecimal characters: " . value)
        }
        return value
    }

    static IsUrl(value) {
        return value ~= "i)^https?://[^\s]+$"
    }

    static JoinPath(root, relative) {
        return RimeDepotUtil.NormalizePath(root . "\" . relative)
    }

    static NormalizePath(value) {
        return RegExReplace(String(value), "[\\/]+", "\")
    }

    static ExpandEnvironment(value) {
        value := String(value)
        Loop 32 {
            if !RegExMatch(value, "%([^%]+)%", &match) {
                break
            }
            replacement := EnvGet(match[1])
            if replacement = "" || replacement = match[0] {
                break
            }
            value := StrReplace(value, match[0], replacement)
        }
        return value
    }

    static IsPathInside(root, candidate) {
        root := RimeDepotUtil.NormalizePath(RTrim(root, "\\"))
        candidate := RimeDepotUtil.NormalizePath(candidate)
        return StrLower(SubStr(candidate, 1, StrLen(root))) = StrLower(root)
            && (StrLen(candidate) = StrLen(root) || SubStr(candidate, StrLen(root) + 1, 1) = "\")
    }

    static SafeRelativePath(value) {
        value := StrReplace(String(value), "/", "\")
        ; AHK's `0 spelling is the digit-zero character, while Chr(0) is
        ; treated as an empty needle by InStr.  ZIP callers scan raw filename
        ; bytes before decoding, so do not use a false NUL check here.
        if value = "" || SubStr(value, 1, 1) = "\" || value ~= "i)^[a-z]:" {
            throw RimeDepotSecurityError("Unsafe relative path: " . value)
        }
        for _, piece in StrSplit(value, "\") {
            if piece = ".." || piece = "." || InStr(piece, ":") {
                throw RimeDepotSecurityError("Unsafe relative path: " . value)
            }
        }
        return value
    }

    static EnsureDirectory(path) {
        if path = "" || DirExist(path) {
            return
        }
        DirCreate(path)
    }

    static TempDirectory(parent, prefix := "rime-depot-") {
        this.EnsureDirectory(parent)
        Loop 20 {
            path := RimeDepotUtil.JoinPath(parent, prefix . Format("{:x}", A_TickCount) . "-" . A_Index)
            if !DirExist(path) && !FileExist(path) {
                DirCreate(path)
                return path
            }
        }
        throw RimeDepotError("Unable to create a temporary RimeDepot directory.", "RimeDepotUtil.TempDirectory")
    }

    static AtomicWrite(path, content, encoding := "UTF-8-RAW") {
        directory := RegExReplace(path, "[\\/][^\\/]*$")
        this.EnsureDirectory(directory)
        temp := path . ".tmp-" . Format("{:x}", A_TickCount)
        try {
            FileAppend(content, temp, encoding)
            FileMove(temp, path, true)
        } catch as err {
            if FileExist(temp) {
                try FileDelete(temp)
            }
            throw err
        }
    }

    static DeleteTree(path) {
        if DirExist(path) {
            DirDelete(path, true)
        } else if FileExist(path) {
            FileDelete(path)
        }
    }
}
