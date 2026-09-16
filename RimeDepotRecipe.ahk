/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk
#Include RimeDepotJson.ahk
#Include RimeDepotYaml.ahk
#Include RimeDepotHttp.ahk

/** Safe, data-only subset of a plum recipe. */
class RimeDepotRecipe {
    static ALLOWED_KEYS := Map(
        "rx", true,
        "description", true,
        "summary", true,
        "args", true,
        "download_files", true,
        "install_files", true,
        "patch_files", true,
        "parameters", true,
        "options", true
    )

    __New(value := 0, name := "") {
        this.Name := name
        this.Rx := ""
        this.Description := ""
        this.Args := Map()
        this.DownloadFiles := []
        this.InstallFiles := []
        this.PatchFiles := Map()
        this.Parameters := Map()
        this.Raw := value
        if value {
            this._Read(value)
        }
    }

    static Parse(value, name := "") {
        if value is String {
            text := String(value)
            try {
                value := RimeDepotJson.Parse(text)
            } catch {
                value := RimeDepotYaml.Parse(text)
            }
        }
        recipe := RimeDepotRecipe(value, name)
        recipe.Validate()
        return recipe
    }

    _Read(value) {
        if !IsObject(value) || value is Array {
            throw RimeDepotCatalogError("A RimeDepot recipe must be a mapping.")
        }
        recipe_info := RimeDepotUtil.GetValue(value, ["recipe"], 0)
        if IsObject(recipe_info) && !(recipe_info is Array) {
            this.Rx := RimeDepotUtil.GetString(recipe_info, ["Rx", "rx"], "")
            this.Description := RimeDepotUtil.GetString(recipe_info, ["description", "summary"], "")
            args := RimeDepotUtil.GetValue(recipe_info, ["args", "Args"], 0)
            if IsObject(args) {
                this.Args := args
            }
        }
        this.Rx := RimeDepotUtil.GetString(value, ["Rx", "rx"], this.Rx)
        this.Description := RimeDepotUtil.GetString(value, ["description", "summary"], this.Description)
        args := RimeDepotUtil.GetValue(value, ["args", "Args"], 0)
        if IsObject(args) {
            this.Args := args
        }
        this.DownloadFiles := RimeDepotRecipe.NormalizeList(
            RimeDepotUtil.GetValue(value, ["download_files", "downloadFiles"], []))
        this.InstallFiles := RimeDepotRecipe.NormalizeList(
            RimeDepotUtil.GetValue(value, ["install_files", "installFiles"], []))
        patch_files := RimeDepotUtil.GetValue(value, ["patch_files", "patchFiles"], Map())
        if IsObject(patch_files) && !(patch_files is Array) {
            this.PatchFiles := patch_files
        } else if patch_files is Array {
            for _, item in patch_files {
                if IsObject(item) {
                    for key, patch in item {
                        this.PatchFiles[key] := patch
                    }
                }
            }
        }
        parameters := RimeDepotUtil.GetValue(value, ["parameters", "options"], Map())
        if IsObject(parameters) && !(parameters is Array) {
            this.Parameters := parameters
        }
    }

    /** Convert plum's folded whitespace-delimited file lists to arrays. */
    static NormalizeList(value) {
        if IsObject(value) {
            return RimeDepotUtil.ToArray(value)
        }
        text := Trim(StrReplace(StrReplace(String(value), "`r`n", "`n"), "`r", "`n"))
        if text = "" {
            return []
        }
        result := []
        Loop Parse, text, " `t`n" {
            if A_LoopField != "" {
                result.Push(A_LoopField)
            }
        }
        return result
    }

    Validate() {
        if this.Rx != "" && (!RimeDepotUtil.IsSafeKey(this.Rx)
            || !RimeDepotRecipe.IsSafeText(this.Rx, false)) {
            throw RimeDepotUnsupportedError("Recipe Rx contains unsafe expression syntax.")
        }
        RimeDepotRecipe.ValidateValue(this.Raw, "recipe")
        for _, item in this.DownloadFiles {
            if IsObject(item) {
                url := RimeDepotUtil.GetString(item, ["url", "URL", "source"], "")
                if url = "" || !RimeDepotUtil.IsUrl(url) {
                    throw RimeDepotUnsupportedError("Recipe download_files entries require an HTTP(S) URL.")
                }
            } else {
                item := String(item)
                url := InStr(item, "::") ? SubStr(item, InStr(item, "::") + 2) : item
                if !RimeDepotUtil.IsUrl(url) {
                    throw RimeDepotUnsupportedError("Recipe download_files entry is not an HTTP(S) URL.")
                }
            }
        }
        for _, pattern in this.InstallFiles {
            RimeDepotRecipe.ValidatePattern(String(pattern))
        }
        for path, patch in this.PatchFiles {
            RimeDepotUtil.SafeRelativePath(path)
            RimeDepotRecipe.ValidateValue(patch, "recipe.patch_files." . path)
            RimeDepotRecipe.SerializePatch(patch)
        }
        return this
    }

    /** Start asynchronous recipe downloads and staged file operations. */
    ApplyAsync(client, source_root, destination_root, parameters, job, callback) {
        this.Validate()
        operation := RimeDepotRecipeOperation(client, this, source_root, destination_root,
            parameters is Map ? parameters : Map(), job, callback)
        operation.Start()
        return operation
    }

    static ValidateValue(value, path) {
        if IsObject(value) {
            if value is Array {
                for index, item in value {
                    this.ValidateValue(item, path . "[" . index . "]")
                }
            } else {
                for key, item in value {
                    key_text := StrLower(String(key))
                    ; Match complete dangerous field names (or explicit
                    ; underscore-delimited variants).  A substring match
                    ; would reject harmless metadata such as `description`
                    ; because it contains the letters `script`.
                    if !RimeDepotRecipe.ALLOWED_KEYS.Has(key_text)
                        && key_text ~= "i)(^|[_-])(command|shell|run|exec|eval|script|bash|powershell|cmd|spawn|process)([_-]|$)" {
                        throw RimeDepotUnsupportedError("Recipe field is executable and is not supported: " . path . "." . key)
                    }
                    this.ValidateValue(item, path . "." . key)
                }
            }
            return
        }
        this.IsSafeText(String(value), true)
    }

    static IsSafeText(value, allow_patch := true) {
        ; Parameter substitution is data-only.  Reject common expression or
        ; shell interpolation forms before they can reach a path or patch.
        if value ~= "i)(^|[^$])\$\([^)]*\)" || value ~= "i)(^|[^%])%[^%]+%" {
            throw RimeDepotUnsupportedError("Recipe contains dynamic expression syntax.")
        }
        if value ~= "i)(^|[\s;&|])(?:cmd|cmd\.exe|powershell|pwsh|bash|sh|eval|exec)(?:\.exe)?(?:\s|$)" {
            throw RimeDepotUnsupportedError("Recipe contains a shell command.")
        }
        if !allow_patch && value ~= "i)(`n|`r|[{};])" {
            ; Rx identifiers are intentionally simple and cannot encode code.
            throw RimeDepotUnsupportedError("Recipe Rx is not a plain identifier.")
        }
        return true
    }

    static ValidatePattern(pattern) {
        if pattern = "" || pattern ~= "i)^[a-z]:" || SubStr(pattern, 1, 1) = "\"
            || InStr(StrReplace(pattern, "/", "\"), "..\") {
            throw RimeDepotSecurityError("Unsafe recipe install glob: " . pattern)
        }
        if InStr(pattern, "`0") {
            throw RimeDepotSecurityError("NUL is not allowed in a recipe install glob.")
        }
    }

    static Expand(value, parameters) {
        if IsObject(value) {
            if value is Array {
                result := []
                for _, item in value {
                    result.Push(this.Expand(item, parameters))
                }
                return result
            }
            result := Map()
            for key, item in value {
                result[key] := this.Expand(item, parameters)
            }
            return result
        }
        return this._ExpandText(String(value), parameters)
    }

    /**
     * Expand parameter tokens in one left-to-right pass.  RegExReplace only
     * accepts a replacement string here, so matches are consumed explicitly.
     * Replacement values are not rescanned, preventing a default or user
     * value from becoming a second expression pass.
     */
    static _ExpandText(value, parameters) {
        local pattern, position, result, match, key, default_value, has_default
        pattern := "\$\{([A-Za-z_][A-Za-z0-9_.-]*):-([^{}]*)\}|\$\{([A-Za-z_][A-Za-z0-9_.-]*)\}|\{\{([A-Za-z_][A-Za-z0-9_.-]*)\}\}"
        position := 1
        result := ""
        while position <= StrLen(value) {
            if !RegExMatch(value, pattern, &match, position) {
                result .= SubStr(value, position)
                break
            }
            result .= SubStr(value, position, match.Pos - position)
            key := ""
            default_value := ""
            has_default := false
            if match[1] != "" {
                key := match[1]
                default_value := match[2]
                has_default := true
            } else if match[3] != "" {
                key := match[3]
            } else {
                key := match[4]
            }
            result .= this._Parameter(parameters, key, default_value, has_default)
            position := match.Pos + match.Len
        }
        return result
    }

    static _Parameter(parameters, key, default_value := "", has_default := false) {
        if !parameters.Has(key) {
            if has_default {
                return default_value
            }
            throw RimeDepotUnsupportedError("Recipe parameter is not supplied: " . key)
        }
        value := parameters[key]
        if IsObject(value) {
            throw RimeDepotUnsupportedError("Recipe parameter must be scalar: " . key)
        }
        return String(value)
    }

    ResolveParameters(parameters) {
        result := Map()
        if this.Args is Map {
            for key, value in this.Args {
                if !IsObject(value) {
                    result[key] := value
                } else if value is Map && value.Has("default") && !IsObject(value["default"]) {
                    result[key] := value["default"]
                }
            }
        }
        if parameters is Map {
            for key, value in parameters {
                result[key] := value
            }
        }
        return result
    }

    static SerializePatch(value) {
        if !IsObject(value) {
            return String(value)
        }
        if value is Array {
            scalar_only := true
            for _, item in value {
                if IsObject(item) {
                    scalar_only := false
                    break
                }
            }
            if scalar_only {
                return this.JoinLines(value)
            }
        }
        return RimeDepotJson.Stringify(value, true, 2)
    }

    static GlobFiles(root, pattern) {
        local relative, result
        this.ValidatePattern(pattern)
        pattern := StrReplace(pattern, "/", "\")
        result := []
        Loop Files, RimeDepotUtil.JoinPath(root, pattern), "F" {
            if InStr(FileGetAttrib(A_LoopFileFullPath), "L") {
                throw RimeDepotSecurityError("Recipe glob matched a reparse point: " . A_LoopFileName)
            }
            relative := RimeDepotUtil.RelativePath(root, A_LoopFileFullPath,
                "Recipe glob escaped its staging directory: " . pattern)
            result.Push({Absolute: A_LoopFileFullPath, Relative: relative})
        }
        return result
    }

    static PatchText(existing, patch, marker) {
        local marker_start, marker_end, patch_start, patch_end, patch_header
        local line_position, search_position, remove_end, insert_position, scan_position, next_node, prefix, suffix
        patch := RimeDepotRecipe.IndentPatch(RimeDepotRecipe.SerializePatch(patch))
        marker_start := "# Rx: " . marker . " {"
        marker_end := "# }"
        patch_start := InStr(existing, marker_start)
        while patch_start {
            if patch_start = 1 || SubStr(existing, patch_start - 1, 1) = "`n" {
                line_position := patch_start + StrLen(marker_start)
                while SubStr(existing, line_position, 1) = " " || SubStr(existing, line_position, 1) = "`t" {
                    line_position += 1
                }
                if SubStr(existing, line_position, 1) = ""
                    || SubStr(existing, line_position, 1) = "`n"
                    || (SubStr(existing, line_position, 1) = "`r"
                        && SubStr(existing, line_position + 1, 1) = "`n") {
                    break
                }
            }
            patch_start := InStr(existing, marker_start, false, patch_start + 1)
        }
        if patch_start {
            search_position := patch_start + StrLen(marker_start)
            patch_end := InStr(existing, marker_end, false, search_position)
            while patch_end {
                if patch_end = 1 || SubStr(existing, patch_end - 1, 1) = "`n" {
                    line_position := patch_end + StrLen(marker_end)
                    while SubStr(existing, line_position, 1) = " " || SubStr(existing, line_position, 1) = "`t" {
                        line_position += 1
                    }
                    if SubStr(existing, line_position, 1) = ""
                        || SubStr(existing, line_position, 1) = "`n"
                        || (SubStr(existing, line_position, 1) = "`r"
                            && SubStr(existing, line_position + 1, 1) = "`n") {
                        break
                    }
                }
                patch_end := InStr(existing, marker_end, false, patch_end + 1)
            }
            if patch_end {
                remove_end := patch_end + StrLen(marker_end)
                while SubStr(existing, remove_end, 1) = " " || SubStr(existing, remove_end, 1) = "`t" {
                    remove_end += 1
                }
                if SubStr(existing, remove_end, 1) = "`r" {
                    remove_end += 1
                }
                if SubStr(existing, remove_end, 1) = "`n" {
                    remove_end += 1
                }
                existing := SubStr(existing, 1, patch_start - 1) . SubStr(existing, remove_end)
            }
        }
        if !RegExMatch(existing, "m)^__patch:[ \t]*(?:\r?$)", &patch_header) {
            existing := RTrim(existing, "`r`n")
            if existing != "" {
                existing .= "`n"
            }
            return existing . "__patch:`n" . marker_start . "`n" . patch
                . (SubStr(patch, -1) = "`n" ? "" : "`n") . marker_end . "`n"
        }
        ; Match plum: keep a new patch inside __patch by inserting it before
        ; the first subsequent top-level YAML node.  If no such node exists,
        ; the mapping extends to EOF and the patch is appended there.
        insert_position := StrLen(existing) + 1
        scan_position := patch_header.Pos + patch_header.Len
        if RegExMatch(existing, "m)^[^ \t#\r\n]", &next_node, scan_position) {
            insert_position := next_node.Pos
        }
        prefix := SubStr(existing, 1, insert_position - 1)
        suffix := SubStr(existing, insert_position)
        if prefix != "" && SubStr(prefix, -1) != "`n" {
            prefix .= "`n"
        }
        return prefix . marker_start . "`n" . patch
            . (SubStr(patch, -1) = "`n" ? "" : "`n") . marker_end . "`n" . suffix
    }

    /** Keep patch data nested below the target file's `__patch` mapping. */
    static IndentPatch(value) {
        local result := "", lines, index, line
        value := StrReplace(StrReplace(String(value), "`r`n", "`n"), "`r", "`n")
        lines := StrSplit(value, "`n")
        for index, line in lines {
            if index > 1 {
                result .= "`n"
            }
            result .= line = "" ? "" : "  " . line
        }
        return result
    }

    static JoinLines(values) {
        result := ""
        for index, value in values {
            if index > 1 {
                result .= "`n"
            }
            result .= String(value)
        }
        return result
    }

    static EscapeRegex(value) {
        return RegExReplace(value, "([\\.\+\*\?\[\^\]\$\(\)\{\}=!<>|:\-])", "\\$1")
    }
}

class RimeDepotRecipeOperation {
    __New(client, recipe, source_root, destination_root, parameters, job, callback) {
        this.Client := client
        this.Recipe := recipe
        this.SourceRoot := source_root
        this.DestinationRoot := destination_root
        this.Parameters := parameters
        this.Job := job
        this.Callback := callback
        this.Downloads := []
        this.DownloadIndex := 0
        this.ActiveRequest := 0
        this.Done := false
        this._step_timer := ObjBindMethod(this, "_Step")
    }

    Start() {
        RimeDepotUtil.EnsureDirectory(this.SourceRoot)
        RimeDepotUtil.EnsureDirectory(this.DestinationRoot)
        this.Parameters := this.Recipe.ResolveParameters(this.Parameters)
        this.Downloads := RimeDepotRecipe.Expand(this.Recipe.DownloadFiles, this.Parameters)
        this.DownloadIndex := 1
        SetTimer(this._step_timer, -1)
        return this
    }

    Cancel(*) {
        if this.ActiveRequest && HasMethod(this.ActiveRequest, "Cancel") {
            this.ActiveRequest.Cancel()
        }
        this.Done := true
    }

    _Step() {
        if this.Done || this.Job.IsCancelled() {
            return
        }
        if this.DownloadIndex <= this.Downloads.Length {
            item := this.Downloads[this.DownloadIndex]
            this.DownloadIndex += 1
            this._Download(item)
            return
        }
        try {
            this._InstallFiles()
            this._PatchFiles()
            this.Done := true
            this.Callback.Call(true, 0)
        } catch as err {
            this.Done := true
            this.Callback.Call(false, err)
        }
    }

    _Download(item) {
        if IsObject(item) {
            url := RimeDepotUtil.GetString(item, ["url", "URL", "source"], "")
            filename := RimeDepotUtil.GetString(item, ["filename", "file", "name", "target"], "")
        } else {
            text := String(item)
            separator := InStr(text, "::")
            if separator {
                filename := SubStr(text, 1, separator - 1)
                url := SubStr(text, separator + 2)
            } else {
                url := text
                filename := SubStr(url, InStr(url, "/", , -1) + 1)
                filename := RegExReplace(filename, "[?#].*$", "")
            }
        }
        if filename = "" {
            filename := "download-" . this.DownloadIndex
        }
        filename := RimeDepotUtil.SafeRelativePath(RimeDepotRecipe.Expand(filename, this.Parameters))
        if !RimeDepotUtil.IsUrl(url) {
            throw RimeDepotUnsupportedError("Recipe download URL must be HTTP(S): " . url)
        }
        this.Job.ReportProgress(Map("phase", "recipe", "state", "downloading", "url", url, "file", filename))
        options := Map("Proxy", this.Job._service ? this.Job._service.Config.Proxy : "")
        this.ActiveRequest := this.Client.GetAsync(url,
            ObjBindMethod(this, "_DownloadResponse", filename, url), options, this.Job)
    }

    _DownloadResponse(filename, url, response) {
        this.ActiveRequest := 0
        if this.Done || this.Job.IsCancelled() {
            return
        }
        try {
            if !response || !response.Ok() {
                message := response && response.Error ? response.Error.Message : "HTTP status " . (response ? response.Status : 0)
                throw RimeDepotError("Recipe download failed for '" . url . "': " . message, "RimeDepotRecipe")
            }
            path := RimeDepotUtil.JoinPath(this.SourceRoot, filename)
            RimeDepotUtil.AtomicWrite(path, response.Body)
            SetTimer(this._step_timer, -1)
        } catch as err {
            this.Done := true
            this.Callback.Call(false, err)
        }
    }

    _InstallFiles() {
        patterns := RimeDepotRecipe.Expand(this.Recipe.InstallFiles, this.Parameters)
        for _, pattern in patterns {
            files := RimeDepotRecipe.GlobFiles(this.SourceRoot, String(pattern))
            for _, file in files {
                relative := RimeDepotUtil.SafeRelativePath(file.Relative)
                destination := RimeDepotUtil.JoinPath(this.DestinationRoot, relative)
                if !RimeDepotUtil.IsPathInside(this.DestinationRoot, destination) {
                    throw RimeDepotSecurityError("Recipe install path escaped destination staging.")
                }
                RimeDepotUtil.EnsureDirectory(RegExReplace(destination, "[\\/][^\\/]*$"))
                FileCopy(file.Absolute, destination, true)
            }
        }
    }

    _PatchFiles() {
        marker := this.Recipe.Rx != "" ? this.Recipe.Rx : this.Recipe.Name
        option_text := ""
        for key, value in this.Parameters {
            option_text .= (option_text = "" ? "" : ",") . key . "=" . value
        }
        if option_text != "" {
            marker .= ":" . option_text
        }
        for path, patch in this.Recipe.PatchFiles {
            path := RimeDepotUtil.SafeRelativePath(RimeDepotRecipe.Expand(path, this.Parameters))
            destination := RimeDepotUtil.JoinPath(this.DestinationRoot, path)
            existing := FileExist(destination) ? FileRead(destination, "UTF-8") : ""
            patch := RimeDepotRecipe.Expand(patch, this.Parameters)
            updated := RimeDepotRecipe.PatchText(existing, patch, marker)
            RimeDepotUtil.AtomicWrite(destination, updated)
        }
    }
}
