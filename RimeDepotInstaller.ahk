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
#Include RimeDepotRecipe.ahk
#Include RimeDepotArchive.ahk
#Include RimeDepotGit.ahk

/** Staged package installer; deployment and schema enabling are out of scope. */
class RimeDepotInstaller {
    __New(config, client, git_client := 0) {
        this.Config := config
        this.Client := client
        this.GitClient := git_client
    }

    InstallAsync(target, catalog, options, job, callback) {
        operation := RimeDepotInstallerOperation(this, target, catalog, options, job, callback)
        operation.Start()
        return operation
    }
}

class RimeDepotInstallerOperation {
    __New(installer, target, catalog, options, job, callback) {
        this.Installer := installer
        this.Config := installer.Config
        this.Client := installer.Client
        this.Target := target
        this.Catalog := catalog
        this.Options := IsObject(options) ? options : Map()
        this.Job := job
        this.Callback := callback
        this.Plan := []
        this.PlanIndex := 0
        this.CurrentRequest := 0
        this.CurrentSource := ""
        this.CurrentRoot := ""
        this.InstallRoot := ""
        this.StageRoot := ""
        this.Changed := Map()
        this.Installed := []
        this.Done := false
        this._step_timer := ObjBindMethod(this, "_Step")
    }

    Start() {
        try {
            if this.Config.RimeDirectory = "" {
                throw RimeDepotError("RimeDirectory must be configured before installing a package.", "RimeDepotInstaller")
            }
            RimeDepotUtil.EnsureDirectory(this.Config.CachePath)
            this.StageRoot := RimeDepotUtil.TempDirectory(RimeDepotUtil.JoinPath(this.Config.CachePath, "staging"), "job-")
            this.InstallRoot := RimeDepotUtil.JoinPath(this.StageRoot, "install")
            RimeDepotUtil.EnsureDirectory(this.InstallRoot)
            this._BuildPlan()
            this.PlanIndex := 1
            SetTimer(this._step_timer, -1)
        } catch as err {
            this._Fail(err)
        }
        return this
    }

    Cancel(*) {
        if this.CurrentRequest && HasMethod(this.CurrentRequest, "Cancel") {
            this.CurrentRequest.Cancel()
        }
        this.Done := true
        this._Cleanup()
    }

    _BuildPlan() {
        if !(this.Catalog is RimeDepotCatalog) {
            throw RimeDepotCatalogError("InstallAsync requires a validated RimeDepotCatalog.")
        }
        this.Plan := []
        states := Map()
        target_entry := this.Catalog.Resolve(this.Target)
        this._Visit(target_entry, states)
    }

    _Visit(entry, states) {
        key := StrLower(entry.Id)
        state := states.Has(key) ? states[key] : 0
        if state = 1 {
            throw RimeDepotCatalogError("Circular package dependency while installing '" . entry.Id . "'.")
        }
        if state = 2 {
            return
        }
        states[key] := 1
        for _, dependency in entry.Dependencies {
            dependency_entry := this.Catalog.Resolve(RimeDepotCatalog.DependencyValue(dependency))
            this._Visit(dependency_entry, states)
        }
        states[key] := 2
        this.Plan.Push(entry)
    }

    _Step() {
        if this.Done || this.Job.IsCancelled() {
            return
        }
        try {
            if this.PlanIndex <= this.Plan.Length {
                entry := this.Plan[this.PlanIndex]
                this._FetchEntry(entry, this.PlanIndex)
                return
            }
            this._Commit()
            this.Done := true
            result := Map("target", this.Target, "entries", this.Installed, "changed", this._ChangedArray(),
                "stage", this.StageRoot, "catalog", this.Catalog, "warnings", this.Catalog.Warnings)
            this.Callback.Call(true, result, 0)
            ; Keep no staging data after a successful commit.
            this._Cleanup()
        } catch as err {
            this._Fail(err)
        }
    }

    _FetchEntry(entry, index) {
        local ref_kind, target_ref, source_repo, archive_url, use_git, git_client, proxy
        this.CurrentSource := RimeDepotUtil.JoinPath(this.StageRoot, "source-" . index)
        RimeDepotUtil.EnsureDirectory(this.CurrentSource)
        source_repo := entry.Repo
        archive_url := entry.ArchiveUrl
        ref := entry.Branch != "" ? entry.Branch : (entry.Tag != "" ? entry.Tag : entry.Sha)
        ref_kind := entry.RefKind != "" ? entry.RefKind
            : (entry.Branch != "" ? "branch" : (entry.Tag != "" ? "tag" : (entry.Sha != "" ? "sha" : "default")))
        if this.Target is RimeDepotTarget && index = this.Plan.Length {
            ; A package-id target may resolve through the catalog while still
            ; carrying a parsed Repo field (for example "Openfly@branch").
            ; Only an explicitly supplied direct source may replace the
            ; catalog repository; ref/recipe/parameter overrides remain valid.
            if this.Target.SourceExplicit && this.Target.Repo != "" {
                source_repo := this.Target.Repo
            }
            if this.Target.ArchiveUrl != "" {
                archive_url := this.Target.ArchiveUrl
            }
            target_ref := this.Target.Ref
            if this.Target.SourceExplicit && this.Target.RefKind = "default" {
                ; A structured direct target with no ref explicitly asks for
                ; the repository default, even if a matching RPPI entry has a
                ; catalog-specific branch.
                ref := ""
                ref_kind := "default"
            } else if target_ref != "" {
                ref := target_ref
                ref_kind := this.Target.RefKind != "" ? this.Target.RefKind
                    : (this.Target.Sha != "" ? "sha" : (this.Target.Tag != "" ? "tag" : "branch"))
            }
        }
        this.Job.ReportProgress(Map("phase", "install", "state", "fetching", "entry", entry.Id,
            "index", index, "total", this.Plan.Length))
        use_git := RimeDepotUtil.GetValue(this.Options, ["UseGit", "use_git"], this.Config.UseGit)
        if use_git {
            if RimeDepotArchive.IsExplicitZipUrl(archive_url) || RimeDepotArchive.IsExplicitZipUrl(source_repo) {
                throw RimeDepotUnsupportedError(
                    "Git mode cannot install an explicit .zip URL; disable Git or provide a repository URL."
                )
            }
            git_client := this.Installer.GitClient
            if !git_client || git_client.Config != this.Config {
                git_client := RimeDepotGitClient(this.Config)
            }
            this.CurrentRequest := git_client.FetchAsync(source_repo, this.CurrentSource, ref, this.Job,
                ObjBindMethod(this, "_GitFetched", entry, index))
        } else {
            if source_repo ~= "i)\.gitmodules$" {
                throw RimeDepotUnsupportedError("HTTP package sources cannot be a .gitmodules repository.")
            }
            if archive_url = "" {
                archive_url := RimeDepotArchive.GitHubArchiveUrl(source_repo, ref, ref_kind)
            } else if !RimeDepotArchive.IsExplicitZipUrl(archive_url) {
                throw RimeDepotUnsupportedError(
                    "Archive mode requires an explicit HTTP(S) .zip URL; enable Git for repository URLs."
                )
            }
            proxy := RimeDepotUtil.GetString(this.Options, ["Proxy", "proxy"], this.Config.Proxy)
            this.CurrentRequest := RimeDepotArchive.DownloadAndExtractAsync(this.Client, archive_url, this.CurrentSource,
                this.Job, ObjBindMethod(this, "_HttpFetched", entry, index), proxy)
        }
    }

    _GitFetched(entry, index, success, root, error) {
        this.CurrentRequest := 0
        if this.Done || this.Job.IsCancelled() {
            return
        }
        if !success {
            this._Fail(error ? error : Error("Git package fetch failed."))
            return
        }
        try {
            this._PreparePackage(entry, index, this.CurrentSource)
        } catch as err {
            this._Fail(err)
        }
    }

    _HttpFetched(entry, index, success, root_or_error) {
        this.CurrentRequest := 0
        if this.Done || this.Job.IsCancelled() {
            return
        }
        if !success {
            this._Fail(root_or_error)
            return
        }
        try {
            this._PreparePackage(entry, index, root_or_error)
        } catch as err {
            this._Fail(err)
        }
    }

    _PreparePackage(entry, index, root) {
        if this.Job.IsCancelled() {
            return
        }
        this.CurrentRoot := root
        if !DirExist(root) {
            throw RimeDepotError("Fetched package has no directory: " . entry.Id, "RimeDepotInstaller")
        }
        if !RimeDepotUtil.IsPathInside(this.StageRoot, root) {
            throw RimeDepotSecurityError("Fetched package root escaped its staging directory.")
        }
        if !this._ConfigFilesAllowed(root) {
            throw RimeDepotUnsupportedError("HTTP package contains .gitmodules; enable Git to install submodules.")
        }
        recipe := this._SelectRecipe(entry, index, root)
        if recipe {
            this._SeedPatchFiles(recipe)
            this.Job.ReportProgress(Map("phase", "install", "state", "recipe", "entry", entry.Id))
            this.CurrentRequest := recipe.ApplyAsync(this.Client, root, this.InstallRoot,
                this._RecipeParameters(entry, index), this.Job, ObjBindMethod(this, "_RecipeDone", entry, index))
            return
        }
        this._InstallDefault(root)
        this._EntryDone(entry, index)
    }

    _RecipeDone(entry, index, success, error) {
        this.CurrentRequest := 0
        if this.Done || this.Job.IsCancelled() {
            return
        }
        if !success {
            this._Fail(error)
            return
        }
        this._MarkAllStageFiles()
        this._EntryDone(entry, index)
    }

    _EntryDone(entry, index) {
        this.Installed.Push(entry.Id)
        this.Job.ReportProgress(Map("phase", "install", "state", "staged", "entry", entry.Id,
            "index", index, "total", this.Plan.Length))
        this.PlanIndex += 1
        SetTimer(this._step_timer, -1)
    }

    _SelectRecipe(entry, index, root) {
        recipe_name := ""
        if this.Target is RimeDepotTarget && index = this.Plan.Length {
            recipe_name := this.Target.Recipe
        }
        if recipe_name != "" && !RimeDepotUtil.IsSafeKey(recipe_name) {
            throw RimeDepotSecurityError("Unsafe recipe name: " . recipe_name)
        }
        value := recipe_name != "" ? RimeDepotInstaller.RecipeValue(entry, recipe_name) : entry.Recipe
        if value {
            return value is RimeDepotRecipe ? value : RimeDepotRecipe.Parse(value, recipe_name)
        }
        if recipe_name != "" {
            path := RimeDepotUtil.JoinPath(root, recipe_name . ".recipe.yaml")
            if !FileExist(path) {
                throw RimeDepotCatalogError("Requested recipe was not found: " . recipe_name)
            }
            return RimeDepotRecipe.Parse(FileRead(path, "UTF-8"), recipe_name)
        }
        recipe_path := RimeDepotUtil.JoinPath(root, "recipe.yaml")
        if FileExist(recipe_path) {
            return RimeDepotRecipe.Parse(FileRead(recipe_path, "UTF-8"), "")
        }
        return 0
    }

    static RecipeValue(entry, name) {
        if entry.Recipes is Map && entry.Recipes.Has(name) {
            return entry.Recipes[name]
        }
        if entry.Recipe is Map && entry.Recipe.Has(name) {
            return entry.Recipe[name]
        }
        return 0
    }

    _RecipeParameters(entry, index) {
        result := Map()
        if entry.Recipe is Map {
            params := RimeDepotUtil.GetValue(entry.Recipe, ["parameters", "options"], 0)
            if IsObject(params) && !(params is Array) {
                for key, value in params {
                    result[key] := value
                }
            }
        }
        if this.Target is RimeDepotTarget && index = this.Plan.Length {
            for key, value in this.Target.Parameters {
                result[key] := value
            }
        }
        for key, value in this.Options {
            if RegExMatch(String(key), "i)^recipe_[A-Za-z_][A-Za-z0-9_.-]*$") {
                result[SubStr(String(key), 8)] := value
            }
        }
        return result
    }

    _SeedPatchFiles(recipe) {
        for path, _ in recipe.PatchFiles {
            path := RimeDepotUtil.SafeRelativePath(path)
            stage_path := RimeDepotUtil.JoinPath(this.InstallRoot, path)
            if FileExist(stage_path) {
                continue
            }
            existing := RimeDepotUtil.JoinPath(this.Config.RimeDirectory, path)
            if FileExist(existing) {
                RimeDepotUtil.EnsureDirectory(RegExReplace(stage_path, "[\\/][^\\/]*$"))
                FileCopy(existing, stage_path, true)
            }
        }
    }

    _InstallDefault(root) {
        ; Match plum's default data-file policy: top-level yaml/txt/gram and
        ; selected opencc files, while omitting custom and recipe YAML files.
        Loop Files, RimeDepotUtil.JoinPath(root, "*"), "F" {
            if InStr(FileGetAttrib(A_LoopFileFullPath), "L") {
                throw RimeDepotSecurityError("Package contains a reparse-point file: " . A_LoopFileName)
            }
            extension := StrLower(RegExReplace(A_LoopFileName, ".*\.", ""))
            if extension = "yaml" {
                if RegExMatch(A_LoopFileName, "i)(?:\.custom|\.recipe)\.yaml$") || StrLower(A_LoopFileName) = "recipe.yaml" {
                    continue
                }
            } else if extension != "txt" && extension != "gram" {
                continue
            }
            this._CopyPackageFile(A_LoopFileFullPath, A_LoopFileName)
        }
        opencc := RimeDepotUtil.JoinPath(root, "opencc")
        if DirExist(opencc) {
            Loop Files, RimeDepotUtil.JoinPath(opencc, "*"), "F" {
                if InStr(FileGetAttrib(A_LoopFileFullPath), "L") {
                    throw RimeDepotSecurityError("Package contains a reparse-point file: " . A_LoopFileName)
                }
                extension := StrLower(RegExReplace(A_LoopFileName, ".*\.", ""))
                if extension != "json" && extension != "ocd" && extension != "txt" {
                    continue
                }
                relative := RimeDepotUtil.RelativePath(root, A_LoopFileFullPath,
                    "Package file escaped its source root.")
                this._CopyPackageFile(A_LoopFileFullPath, relative)
            }
        }
    }

    _CopyPackageFile(source, relative) {
        relative := RimeDepotUtil.SafeRelativePath(relative)
        destination := RimeDepotUtil.JoinPath(this.InstallRoot, relative)
        if !RimeDepotUtil.IsPathInside(this.InstallRoot, destination) {
            throw RimeDepotSecurityError("Package file escaped install staging.")
        }
        RimeDepotUtil.EnsureDirectory(RegExReplace(destination, "[\\/][^\\/]*$"))
        FileCopy(source, destination, true)
        this.Changed[relative] := true
    }

    _MarkAllStageFiles() {
        Loop Files, RimeDepotUtil.JoinPath(this.InstallRoot, "*"), "FR" {
            relative := RimeDepotUtil.RelativePath(this.InstallRoot, A_LoopFileFullPath,
                "Staged install file escaped install staging.")
            this.Changed[RimeDepotUtil.SafeRelativePath(relative)] := true
        }
    }

    _ConfigFilesAllowed(root) {
        ; A repository may keep its submodule manifest below a package
        ; directory.  HTTP archives cannot initialize those submodules, so
        ; reject every `.gitmodules` file before staging any package data.
        Loop Files, RimeDepotUtil.JoinPath(root, "*"), "FR" {
            if StrLower(A_LoopFileName) = ".gitmodules" {
                return false
            }
        }
        return true
    }

    _ChangedArray() {
        result := []
        for relative, _ in this.Changed {
            result.Push(relative)
        }
        return result
    }

    _Commit() {
        if this.Changed.Count = 0 {
            return
        }
        RimeDepotUtil.EnsureDirectory(this.Config.RimeDirectory)
        backup_root := RimeDepotUtil.JoinPath(this.StageRoot, "backup")
        RimeDepotUtil.EnsureDirectory(backup_root)
        moved := []
        backups := []
        try {
            for relative, _ in this.Changed {
                source := RimeDepotUtil.JoinPath(this.InstallRoot, relative)
                target := RimeDepotUtil.JoinPath(this.Config.RimeDirectory, relative)
                if !FileExist(source) {
                    throw RimeDepotError("Staged install file disappeared: " . relative, "RimeDepotInstaller")
                }
                if !RimeDepotUtil.IsPathInside(this.Config.RimeDirectory, target) {
                    throw RimeDepotSecurityError("Install target escaped RimeDirectory.")
                }
                RimeDepotUtil.EnsureDirectory(RegExReplace(target, "[\\/][^\\/]*$"))
                if FileExist(target) {
                    backup := RimeDepotUtil.JoinPath(backup_root, relative)
                    RimeDepotUtil.EnsureDirectory(RegExReplace(backup, "[\\/][^\\/]*$"))
                    FileMove(target, backup, true)
                    backups.Push({Target: target, Backup: backup})
                }
                FileMove(source, target, true)
                moved.Push(target)
            }
        } catch as err {
            ; Restore all files that have been moved so far.  Rollback errors
            ; are reported in OutputDebug while the original failure remains
            ; the operation's public error.
            for _, target in moved {
                try FileDelete(target)
            }
            for _, item in backups {
                try {
                    if FileExist(item.Backup) {
                        RimeDepotUtil.EnsureDirectory(RegExReplace(item.Target, "[\\/][^\\/]*$"))
                        FileMove(item.Backup, item.Target, true)
                    }
                } catch as rollback_error {
                    OutputDebug("RimeDepot install rollback failed: " . rollback_error.Message)
                }
            }
            throw err
        }
    }

    _Fail(error) {
        if this.Done {
            return
        }
        this.Done := true
        this._Cleanup()
        this.Callback.Call(false, 0, error ? error : Error("RimeDepot installation failed."))
    }

    _Cleanup() {
        if this.StageRoot != "" && (DirExist(this.StageRoot) || FileExist(this.StageRoot)) {
            try RimeDepotUtil.DeleteTree(this.StageRoot)
        }
    }
}
