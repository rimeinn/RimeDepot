/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk
#Include RimeDepotHttp.ahk

/** GitHub archive and ZIP extraction helpers. */
class RimeDepotArchive {
    static DOWNLOAD_TIMEOUT_MS := 300000

    static GitHubArchiveUrl(repo, ref := "", ref_kind := "") {
        repo := String(repo)
        if this.IsExplicitZipUrl(repo) {
            ; An explicit archive is already a complete source URL.  Do not
            ; append a ref or rewrite its path.
            return repo
        }
        if RimeDepotUtil.IsUrl(repo) {
            if !RegExMatch(repo, "i)^https?://github\.com/", &match) {
                throw RimeDepotUnsupportedError(
                    "Archive mode supports owner/repository, a GitHub repository URL, or an explicit .zip URL; enable Git or provide a .zip URL."
                )
            }
            repo := RegExReplace(repo, "i)^https?://github\.com/", "")
            repo := RegExReplace(repo, "/(?:tree|commit)/.*$", "")
            repo := RegExReplace(repo, "[?#].*$", "")
            repo := RegExReplace(repo, "i)\.git$", "")
        } else if repo ~= "i)^(?:ssh://|git@)" {
            throw RimeDepotUnsupportedError(
                "Archive mode does not accept Git transport URLs; enable Git or provide an explicit .zip URL."
            )
        }
        repo := Trim(repo, " /\\")
        if !RegExMatch(repo, "^[^/\\\s]+/[^/\\\s]+$") {
            throw RimeDepotTargetError(
                "Archive mode requires an owner/repository target, a GitHub repository URL, or an explicit .zip URL: " . repo
            )
        }
        if ref = "" {
            ; GitHub resolves this endpoint to the repository's default
            ; branch.  `/archive/refs/heads/HEAD.zip` would instead look for
            ; a literal branch named HEAD.
            return "https://github.com/" . repo . "/archive/HEAD.zip"
        }
        ref := String(ref)
        ref_kind := StrLower(String(ref_kind))
        if ref_kind = "commit" {
            ref_kind := "sha"
        }
        if ref_kind = "" {
            ref_kind := ref ~= "i)^[0-9a-f]{7,40}$" ? "sha" : "branch"
        }
        if ref_kind != "auto" && ref_kind != "branch" && ref_kind != "tag" && ref_kind != "sha" {
            throw RimeDepotTargetError("Unsupported Git ref kind for archive: " . ref_kind)
        }
        RimeDepotUtil.ValidateRef(ref, ref_kind = "sha")
        ref := this.UrlEncodePath(ref)
        if ref_kind = "auto" {
            return "https://github.com/" . repo . "/archive/" . ref . ".zip"
        }
        if ref_kind = "sha" {
            return "https://github.com/" . repo . "/archive/" . ref . ".zip"
        }
        if ref_kind = "tag" {
            return "https://github.com/" . repo . "/archive/refs/tags/" . ref . ".zip"
        }
        return "https://github.com/" . repo . "/archive/refs/heads/" . ref . ".zip"
    }

    static IsExplicitZipUrl(value) {
        return String(value) ~= "i)^https?://[^\s]+\.zip(?:[?#][^\s]*)?$"
    }

    static DownloadAndExtractAsync(client, archive_url, staging_root, job, callback, proxy := "", shell_factory := 0) {
        RimeDepotUtil.EnsureDirectory(staging_root)
        operation := RimeDepotArchiveOperation(client, archive_url, staging_root, job, callback, proxy, shell_factory)
        operation.Start()
        return operation
    }

    static WriteBinary(path, value) {
        if !(value is Buffer) {
            throw RimeDepotError("The archive response did not contain binary data.", "RimeDepotArchive")
        }
        directory := RegExReplace(path, "[\\/][^\\/]*$")
        RimeDepotUtil.EnsureDirectory(directory)
        temp := path . ".tmp-" . Format("{:x}", A_TickCount)
        file := 0
        try {
            file := FileOpen(temp, "w")
            if !file {
                throw OSError(, , "Unable to create archive staging file.")
            }
            file.RawWrite(value)
            file.Close()
            FileMove(temp, path, true)
        } catch as err {
            if file {
                try file.Close()
            }
            if FileExist(temp) {
                try FileDelete(temp)
            }
            throw err
        }
    }

    /**
     * Inspect the ZIP central directory before Shell extraction.  Shell's
     * extractor is retained for compatibility with Windows' built-in ZIP
     * support, while this pass prevents absolute and parent-traversal names.
     */
    static ValidateZip(path) {
        file := FileOpen(path, "r")
        if !file {
            throw RimeDepotError("Unable to open package archive.", "RimeDepotArchive")
        }
        try {
            size := file.Length
            if size < 22 {
                throw RimeDepotSecurityError("Package archive is too small to be a ZIP file.")
            }
            data := Buffer(size)
            file.RawRead(data)
        } finally {
            file.Close()
        }

        eocd := RimeDepotArchive.FindSignature(data, size, 0x06054B50, 22, 65557)
        if eocd < 0 {
            throw RimeDepotSecurityError("Package archive has no ZIP end record.")
        }
        count := NumGet(data, eocd + 10, "UShort")
        directory_size := NumGet(data, eocd + 12, "UInt")
        directory_offset := NumGet(data, eocd + 16, "UInt")
        directory_end := directory_offset + directory_size
        if directory_end > size {
            throw RimeDepotSecurityError("ZIP central directory lies outside the archive.")
        }
        offset := directory_offset
        Loop count {
            if offset + 46 > directory_end || NumGet(data, offset, "UInt") != 0x02014B50 {
                throw RimeDepotSecurityError("Invalid ZIP central directory entry.")
            }
            flags := NumGet(data, offset + 8, "UShort")
            compression := NumGet(data, offset + 10, "UShort")
            name_length := NumGet(data, offset + 28, "UShort")
            extra_length := NumGet(data, offset + 30, "UShort")
            comment_length := NumGet(data, offset + 32, "UShort")
            if (flags & 1) || (compression != 0 && compression != 8) {
                throw RimeDepotUnsupportedError("Encrypted or unsupported ZIP compression is not allowed.")
            }
            if offset + 46 + name_length + extra_length + comment_length > directory_end {
                throw RimeDepotSecurityError("ZIP entry exceeds the central directory.")
            }
            Loop name_length {
                if NumGet(data, offset + 46 + A_Index - 1, "UChar") = 0 {
                    throw RimeDepotSecurityError("ZIP filename contains a NUL byte.")
                }
            }
            name := StrGet(data.Ptr + offset + 46, name_length, "UTF-8")
            if SubStr(name, -1) != "/" {
                RimeDepotUtil.SafeRelativePath(name)
            } else {
                ; Validate directory names too, without rejecting the final
                ; slash used by ZIP directory records.
                RimeDepotUtil.SafeRelativePath(RTrim(name, "/"))
            }
            offset += 46 + name_length + extra_length + comment_length
        }
        return true
    }

    static ExtractZip(path, destination, shell_factory := 0) {
        RimeDepotUtil.EnsureDirectory(destination)
        namespaces := RimeDepotArchive.OpenNamespaces(path, destination, shell_factory)
        flags := 0x14 ; FOF_NOCONFIRMATION | FOF_SILENT
        namespaces.Destination.CopyHere(namespaces.Zip.Items, flags)
        ; CopyHere is asynchronous.  Callers needing completion must use
        ; RimeDepotArchiveOperation; this compatibility helper deliberately
        ; returns after scheduling the copy and never blocks the GUI thread.
        return true
    }

    static OpenNamespaces(path, destination, shell_factory := 0) {
        if shell_factory {
            result := shell_factory.Call(path, destination)
            if IsObject(result) {
                zip_namespace := RimeDepotUtil.GetValue(result, ["Zip", "zip"], 0)
                destination_namespace := RimeDepotUtil.GetValue(result, ["Destination", "destination"], 0)
                if zip_namespace && destination_namespace {
                    return {Zip: zip_namespace, Destination: destination_namespace}
                }
            }
            throw RimeDepotError("The archive shell factory did not return both namespaces.", "RimeDepotArchive")
        }
        shell := ComObject("Shell.Application")
        zip_namespace := shell.Namespace(path)
        destination_namespace := shell.Namespace(destination)
        if !zip_namespace || !destination_namespace {
            throw RimeDepotError("Windows could not open the package archive.", "RimeDepotArchive")
        }
        return {Zip: zip_namespace, Destination: destination_namespace}
    }

    static CountNamespaceItems(namespace) {
        return this.CountItems(namespace.Items)
    }

    static CountItems(items) {
        count := 0
        for item in items {
            count += 1
            is_folder := false
            try is_folder := !!item.IsFolder
            if is_folder {
                try {
                    folder := item.GetFolder
                    count += this.CountItems(folder.Items)
                }
            }
        }
        return count
    }

    static FindPackageRoot(staging_root) {
        directories := []
        files := []
        Loop Files, RimeDepotUtil.JoinPath(staging_root, "*"), "F" {
            files.Push(A_LoopFileFullPath)
        }
        Loop Files, RimeDepotUtil.JoinPath(staging_root, "*"), "D" {
            directories.Push(A_LoopFileFullPath)
        }
        if files.Length = 0 && directories.Length = 1 {
            return directories[1]
        }
        return staging_root
    }

    static FindSignature(data, size, signature, minimum := 0, maximum := 0) {
        start := size - minimum
        stop := maximum ? Max(0, size - maximum) : 0
        while start >= stop {
            if NumGet(data, start, "UInt") = signature {
                return start
            }
            start -= 1
        }
        return -1
    }

    static UrlEncodePath(value) {
        ; RegExReplace(Func) is not available on all supported AHK v2 builds.
        ; Encode UTF-8 bytes explicitly so spaces, slash separators and
        ; non-ASCII branch/tag names cannot alter the archive URL path.
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
                || byte >= 0x61 && byte <= 0x7A || InStr("._~!$&'()+,;=@-", char) {
                result .= char
            } else {
                result .= "%" . Format("{:02X}", byte)
            }
        }
        return result
    }
}

/**
 * Owns one archive download and the asynchronous Shell.Application copy.
 * Shell's CopyHere returns before extraction is complete, so completion is
 * reported only after the recursive item count has been stable for several
 * polls.  No Sleep is used; timers keep the GUI message loop responsive.
 */
class RimeDepotArchiveOperation {
    __New(client, archive_url, staging_root, job, callback, proxy := "", shell_factory := 0) {
        this.Client := client
        this.ArchiveUrl := archive_url
        this.StagingRoot := staging_root
        this.Job := job
        this.Callback := callback
        this.Proxy := proxy
        this.ShellFactory := shell_factory
        this.ArchivePath := staging_root . ".package.zip"
        this.DownloadRequest := 0
        this.Namespaces := 0
        this.ExpectedCount := 0
        this.LastCount := -1
        this.StablePolls := 0
        this.Deadline := 0
        this.Done := false
        this._poll_timer := ObjBindMethod(this, "_PollExtraction")
    }

    Start() {
        options := Map(
            "Binary", true,
            "Proxy", this.Proxy,
            "Timeout", RimeDepotArchive.DOWNLOAD_TIMEOUT_MS
        )
        try {
            this.DownloadRequest := this.Client.GetAsync(this.ArchiveUrl,
                ObjBindMethod(this, "_DownloadResponse"), options, this.Job)
        } catch as err {
            this._Fail(err)
        }
        return this
    }

    Cancel(*) {
        if this.Done {
            return false
        }
        this.Done := true
        SetTimer(this._poll_timer, 0)
        if this.DownloadRequest && HasMethod(this.DownloadRequest, "Cancel") {
            try this.DownloadRequest.Cancel()
        }
        this.DownloadRequest := 0
        this._DeleteArchive()
        return true
    }

    _DownloadResponse(response) {
        this.DownloadRequest := 0
        if this.Done || this.Job.IsCancelled() {
            return
        }
        try {
            if !response || !response.Ok() {
                message := response && response.Error ? response.Error.Message
                    : "HTTP status " . (response ? response.Status : 0)
                throw RimeDepotError("Archive download failed: " . message, "RimeDepotArchive")
            }
            RimeDepotArchive.WriteBinary(this.ArchivePath, response.Body)
            RimeDepotArchive.ValidateZip(this.ArchivePath)
            this._BeginExtraction()
        } catch as err {
            this._Fail(err)
        }
    }

    _BeginExtraction() {
        this.Namespaces := RimeDepotArchive.OpenNamespaces(this.ArchivePath, this.StagingRoot, this.ShellFactory)
        flags := 0x14 ; FOF_NOCONFIRMATION | FOF_SILENT
        this.Namespaces.Destination.CopyHere(this.Namespaces.Zip.Items, flags)
        this.ExpectedCount := RimeDepotArchive.CountNamespaceItems(this.Namespaces.Zip)
        this.LastCount := -1
        this.StablePolls := 0
        this.Deadline := A_TickCount + 30000
        SetTimer(this._poll_timer, 20)
    }

    _PollExtraction() {
        if this.Done {
            SetTimer(this._poll_timer, 0)
            return
        }
        try {
            count := RimeDepotArchive.CountNamespaceItems(this.Namespaces.Destination)
            if count = this.LastCount {
                this.StablePolls += 1
            } else {
                this.LastCount := count
                this.StablePolls := 1
            }
            if count >= this.ExpectedCount && this.StablePolls >= 3 {
                this._Complete()
                return
            }
            if A_TickCount >= this.Deadline {
                throw RimeDepotError("Timed out extracting the package archive.", "RimeDepotArchive")
            }
        } catch as err {
            this._Fail(err)
        }
    }

    _Complete() {
        if this.Done {
            return
        }
        this.Done := true
        SetTimer(this._poll_timer, 0)
        this._DeleteArchive()
        if this.Callback {
            try {
                this.Callback.Call(true, RimeDepotArchive.FindPackageRoot(this.StagingRoot))
            } catch as err {
                OutputDebug("RimeDepot archive callback failed: " . err.Message)
            }
        }
    }

    _Fail(error) {
        if this.Done {
            return
        }
        this.Done := true
        SetTimer(this._poll_timer, 0)
        this._DeleteArchive()
        if this.Callback {
            try {
                this.Callback.Call(false, error)
            } catch as err {
                OutputDebug("RimeDepot archive callback failed: " . err.Message)
            }
        }
    }

    _DeleteArchive() {
        if FileExist(this.ArchivePath) {
            try FileDelete(this.ArchivePath)
        }
    }
}
