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
#Include RimeDepotRppi.ahk
#Include RimeDepotDirect.ahk
#Include RimeDepotInstaller.ahk

/** Public facade.  A service owns at most one active asynchronous job. */
class RimeDepotService {
    __New(options := 0, ini_path := "", dependencies := 0) {
        if !IsObject(options) {
            options := Map()
        }
        if !IsObject(dependencies) {
            dependencies := Map()
        }
        this.Config := RimeDepotConfig.Load(options, ini_path)
        this.Dependencies := dependencies
        http := RimeDepotUtil.GetValue(dependencies, ["Http", "HttpClient", "Transport"], 0)
        this.Http := http ? (http is RimeDepotHttpClient ? http : RimeDepotHttpClient(http)) : RimeDepotHttpClient()
        this.GitRunner := RimeDepotUtil.GetValue(dependencies, ["GitRunner", "git_runner"], 0)
        this.Catalog := 0
        this.ActiveJob := 0
    }

    LoadCatalog(options := 0, callbacks := 0) {
        return this._LoadCatalog(options, callbacks, false)
    }

    RefreshCatalog(options := 0, callbacks := 0) {
        return this._LoadCatalog(options, callbacks, true)
    }

    InstallEntry(entry, callbacks := 0) {
        if !this.Catalog {
            throw RimeDepotCatalogError("LoadCatalog must complete before InstallEntry.")
        }
        if !(entry is RimeDepotCatalogEntry) {
            entry := this.Catalog.Resolve(entry)
        }
        return this._InstallEntry(entry, callbacks)
    }

    InstallDirect(request, callbacks := 0) {
        request := request is RimeDepotDirectInstallRequest
            ? request : RimeDepotDirectInstallRequest(request)
        return this._InstallDirect(request, callbacks)
    }

    Cancel() {
        if this.ActiveJob && !this.ActiveJob.IsDone() {
            return this.ActiveJob.Cancel()
        }
        return false
    }

    SetConfig(config) {
        if this.ActiveJob && !this.ActiveJob.IsDone() {
            throw RimeDepotBusyError("Cannot change RimeDepotService configuration during an active job.")
        }
        this.Config := config is RimeDepotConfig ? config : RimeDepotConfig(config)
        this.Config._Normalize()
        return this.Config
    }

    Configure(config) {
        return this.SetConfig(config)
    }

    GetCatalog() {
        return this.Catalog
    }

    GetEntry(target) {
        if !this.Catalog {
            throw RimeDepotCatalogError("The catalog has not been loaded.")
        }
        return this.Catalog.Resolve(target)
    }

    _LoadCatalog(options, callbacks, refresh) {
        local job, config, cache, identity, snapshot, probe
        if options is RimeDepotCallbacks || IsObject(options) && HasMethod(options, "Call") {
            if !callbacks {
                callbacks := options
            }
            options := Map()
        } else if !IsObject(options) {
            options := Map()
        }
        if !callbacks {
            callbacks := RimeDepotUtil.GetValue(options, ["Callbacks", "callbacks"], 0)
        }
        callbacks := this._NormalizeCallbacks(callbacks)
        job := this._Begin("refresh-catalog", callbacks)
        try {
            config := this.Config.With(options)
            cache := RimeDepotRppiCache(config.CachePath)
            identity := RimeDepotRppiVersionProbe.ParseRawGithubUrl(config.RppiIndexUrl)
            ; Keep the last complete normalized generation available to every
            ; full-load path, including RefreshCatalog.  A raw load is allowed
            ; to use per-URL caches, but never to publish a mixed generation.
            snapshot := cache.ReadSnapshot(config.RppiIndexUrl)
            if !refresh && identity {
                probe := RimeDepotRppiVersionProbe(this.Http, config.RppiIndexUrl, config.AsMap(), snapshot,
                    ObjBindMethod(this, "_CatalogGateDone", job, config, cache, identity, snapshot), job)
                job.SetCancelHandler(ObjBindMethod(probe, "Cancel"))
                probe.Start()
            } else {
                this._StartCatalogLoad(job, config, cache, refresh, "", 0, false, snapshot)
            }
        } catch as err {
            job.Fail(err)
        }
        return job
    }

    _StartCatalogLoad(job, config, cache, refresh, version_sha := "", probe_response := 0,
        force_reload := false, prior_snapshot := 0) {
        local operation
        operation := RimeDepotRppiLoadOperation(this.Http, cache, config.RppiIndexUrl,
            config.AsMap(), job, ObjBindMethod(this, "_CatalogDone", job, refresh, cache,
                config.RppiIndexUrl, version_sha, probe_response, prior_snapshot),
            refresh, force_reload)
        job.SetCancelHandler(ObjBindMethod(operation, "Cancel"))
        operation.Start()
        return operation
    }

    _CatalogGateDone(job, config, cache, identity, snapshot, result) {
        local version_sha, response, warning, force_reload
        if job.IsDone() {
            return
        }
        result := IsObject(result) ? result : Map("ok", false, "error", Error("Invalid commit probe result."))
        if result["ok"] {
            version_sha := RimeDepotUtil.GetString(result, ["sha"], "")
            response := RimeDepotUtil.GetValue(result, ["response"], 0)
            if snapshot && version_sha != "" && RimeDepotRppiVersionProbe.CanFastPath(
                config.RppiIndexUrl, identity, snapshot, version_sha) {
                try {
                    cache.TouchSnapshot(config.RppiIndexUrl, snapshot, version_sha, response)
                    this._CompleteSnapshotJob(job, snapshot)
                } catch as err {
                    try {
                        this._StartCatalogLoad(job, config, cache, false, version_sha, response, false, snapshot)
                    } catch as start_error {
                        job.Fail(start_error)
                    }
                }
                return
            }
            force_reload := snapshot && snapshot["VersionSha"] != ""
                && StrLower(snapshot["VersionSha"]) != StrLower(version_sha)
            try {
                this._StartCatalogLoad(job, config, cache, false, version_sha, response, force_reload, snapshot)
            } catch as err {
                job.Fail(err)
            }
            return
        }

        if snapshot {
            warning := this._SnapshotWarning(config.RppiIndexUrl, result)
            try {
                this._CompleteSnapshotJob(job, snapshot, warning)
            } catch as err {
                ; A corrupt snapshot is treated like a cache miss; preserve the
                ; previous full-load behavior when local recovery is impossible.
                try {
                    this._StartCatalogLoad(job, config, cache, false, "", 0, false, 0)
                } catch as start_error {
                    job.Fail(start_error)
                }
            }
            return
        }
        ; There is no trusted version yet.  Keep the old first-load behavior:
        ; fetch every raw index and do not create a versioned snapshot.
        try {
            this._StartCatalogLoad(job, config, cache, false, "", 0, false, 0)
        } catch as err {
            job.Fail(err)
        }
    }

    _CompleteSnapshotJob(job, snapshot, warning := 0) {
        local catalog
        if job.IsDone() {
            return
        }
        catalog := RimeDepotCatalog.FromSnapshot(snapshot["Document"])
        if warning {
            catalog.Warnings.Push(warning)
        }
        this.Catalog := catalog
        job.Complete(catalog)
    }

    _SnapshotWarning(root_url, result) {
        local error, message
        error := RimeDepotUtil.GetValue(result, ["error"], 0)
        message := error && HasProp(error, "Message") ? error.Message : "Commit probe unavailable."
        return Map(
            "kind", "stale-snapshot",
            "url", root_url,
            "message", "Commit probe failed; using the last complete catalog snapshot.",
            "error", message
        )
    }

    _SnapshotLoadWarning(root_url, cause := 0) {
        local error, message
        error := cause
        if cause is Map && cause.Has("error") {
            error := cause["error"]
        }
        if error && HasProp(error, "Message") {
            message := error.Message
        } else if error && !IsObject(error) {
            message := String(error)
        } else {
            message := "The raw catalog load was incomplete."
        }
        return Map(
            "kind", "stale-snapshot",
            "url", root_url,
            "message", "Catalog reload was incomplete; using the last complete catalog snapshot.",
            "error", message
        )
    }

    _InstallEntry(entry, callbacks) {
        local job, config, installer, operation
        callbacks := this._NormalizeCallbacks(callbacks)
        job := this._Begin("install", callbacks)
        try {
            config := this.Config.With(Map("UseGit", false))
            config._Normalize()
            installer := RimeDepotInstaller(config, this.Http)
            operation := installer.InstallEntryAsync(entry, this.Catalog, job, ObjBindMethod(this, "_InstallDone", job))
            job.SetCancelHandler(ObjBindMethod(operation, "Cancel"))
        } catch as err {
            job.Fail(err)
        }
        return job
    }

    _InstallDirect(request, callbacks) {
        local job, config, git_client := 0, use_git, installer, operation
        callbacks := this._NormalizeCallbacks(callbacks)
        job := this._Begin("install-direct", callbacks)
        try {
            config := this.Config
            use_git := request.Transport = "git" || (request.Transport = "auto" && config.UseGit)
            if use_git {
                git_client := RimeDepotGitClient(config, this.GitRunner)
            }
            installer := RimeDepotInstaller(config, this.Http, git_client)
            operation := installer.InstallDirectAsync(request, job, ObjBindMethod(this, "_InstallDone", job))
            job.SetCancelHandler(ObjBindMethod(operation, "Cancel"))
        } catch as err {
            job.Fail(err)
        }
        return job
    }

    _CatalogDone(job, refresh, cache, root_url, version_sha, probe_response, prior_snapshot,
        catalog, error, warnings) {
        local warning, document, eligible, has_warnings, warning_cause
        if job.IsDone() {
            return
        }
        if error {
            if prior_snapshot {
                this._CompleteSnapshotJob(job, prior_snapshot, this._SnapshotLoadWarning(root_url, error))
                return
            }
            job.Fail(error)
            return
        }
        has_warnings := false
        warning_cause := 0
        if warnings is Array && warnings.Length > 0 {
            has_warnings := true
            warning_cause := warnings[1]
        }
        if catalog.Warnings is Array && catalog.Warnings.Length > 0 {
            has_warnings := true
            if !warning_cause {
                warning_cause := catalog.Warnings[1]
            }
        }
        ; A full load with any stale/error warning is not a coherent new
        ; generation.  Return the previous normalized generation when one is
        ; available, and leave its metadata pointer untouched.
        if has_warnings {
            if prior_snapshot {
                this._CompleteSnapshotJob(job, prior_snapshot,
                    this._SnapshotLoadWarning(root_url, warning_cause))
                return
            }
            this.Catalog := catalog
            job.Complete(catalog)
            return
        }
        if !refresh && version_sha != "" {
            document := catalog.ToSnapshot(root_url)
            eligible := RimeDepotRppiVersionProbe.IsUniformSourceSet(root_url, catalog.Sources)
            try {
                cache.WriteSnapshot(root_url, document, version_sha, probe_response, eligible)
            } catch as err {
                warning := Map(
                    "kind", "snapshot",
                    "url", root_url,
                    "message", "Catalog loaded but its normalized snapshot could not be committed.",
                    "error", err.Message
                )
                if prior_snapshot {
                    this._CompleteSnapshotJob(job, prior_snapshot, warning)
                    return
                }
                catalog.Warnings.Push(warning)
            }
        }
        this.Catalog := catalog
        job.Complete(catalog)
    }

    _InstallDone(job, success, result, error) {
        if job.IsDone() {
            return
        }
        if !success {
            job.Fail(error)
            return
        }
        job.Complete(result)
    }

    _Begin(kind, callbacks) {
        if this.ActiveJob && !this.ActiveJob.IsDone() {
            throw RimeDepotBusyError()
        }
        job := RimeDepotJob(kind, callbacks, this)
        this.ActiveJob := job
        job.SetFinishHandler(ObjBindMethod(this, "_JobFinished"))
        job.Start()
        return job
    }

    _JobFinished(job) {
        if this.ActiveJob = job {
            this.ActiveJob := 0
        }
    }

    _NormalizeCallbacks(callbacks) {
        if callbacks is RimeDepotCallbacks {
            return callbacks
        }
        if IsObject(callbacks) {
            if HasMethod(callbacks, "Call") {
                return RimeDepotCallbacks(0, callbacks, 0)
            }
            progress := RimeDepotUtil.GetValue(callbacks, ["Progress", "progress"], 0)
            complete := RimeDepotUtil.GetValue(callbacks, ["Complete", "complete"], 0)
            error := RimeDepotUtil.GetValue(callbacks, ["Error", "error"], 0)
            return RimeDepotCallbacks(progress, complete, error)
        }
        return RimeDepotCallbacks()
    }
}
