/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Requires AutoHotkey v2.0
#SingleInstance Off

#Include ..\RimeDepot.ahk
#Include ..\RimeDepotGui.ahk

try {
    RimeDepotCoreProbeMain()
} catch as err {
    RimeDepotCoreProbeReportError(err)
    ExitApp(1)
}

RimeDepotCoreProbeMain() {
    RimeDepotCoreProbeTest("JSON", RimeDepotCoreProbeJson.Bind())
    RimeDepotCoreProbeTest("YAML", RimeDepotCoreProbeYaml.Bind())
    RimeDepotCoreProbeTest("target and security", RimeDepotCoreProbeTarget.Bind())
    RimeDepotCoreProbeTest("structured targets and archive URLs", RimeDepotCoreProbeTargetMatrix.Bind())
    RimeDepotCoreProbeTest("safe relative paths and ZIP names", RimeDepotCoreProbeSafeRelativePaths.Bind())
    RimeDepotCoreProbeTest("config precedence", RimeDepotCoreProbeConfig.Bind())
    RimeDepotCoreProbeTest("GUI settings INI round-trip", RimeDepotCoreProbeGuiSettings.Bind())
    RimeDepotCoreProbeTest("catalog async and cache fallback", RimeDepotCoreProbeCatalog.Bind())
    RimeDepotCoreProbeTest("normalized catalog snapshot and commit gate", RimeDepotCoreProbeSnapshotGate.Bind())
    RimeDepotCoreProbeTest("raw GitHub commit probe URL safety", RimeDepotCoreProbeSnapshotProbeMatrix.Bind())
    RimeDepotCoreProbeTest("RPPI synchronous request token", RimeDepotCoreProbeRppiSyncRequest.Bind())
    RimeDepotCoreProbeTest("official RPPI categories and recipes", RimeDepotCoreProbeOfficialRppi.Bind())
    RimeDepotCoreProbeTest("git safety", RimeDepotCoreProbeGit.Bind())
    RimeDepotCoreProbeTest("git argv quoting", RimeDepotCoreProbeGitQuoting.Bind())
    RimeDepotCoreProbeTest("git SHA command plan", RimeDepotCoreProbeGitSha.Bind())
    RimeDepotCoreProbeTest("local git --version process", RimeDepotCoreProbeGitVersion.Bind())
    RimeDepotCoreProbeTest("recipe safety", RimeDepotCoreProbeRecipe.Bind())
    RimeDepotCoreProbeTest("recipe apply", RimeDepotCoreProbeRecipeApply.Bind())
    RimeDepotCoreProbeTest("non-recursive file selection", RimeDepotCoreProbeNonRecursiveFiles.Bind())
    RimeDepotCoreProbeTest("direct owner/repository InstallTarget", RimeDepotCoreProbeInstallTarget.Bind())
    RimeDepotCoreProbeTest("direct target URL/ref contract", RimeDepotCoreProbeDirectTargetContract.Bind())
    RimeDepotCoreProbeTest("catalog installs remain archive-only", RimeDepotCoreProbeCatalogArchiveOnly.Bind())
    RimeDepotCoreProbeTest("catalog target ref overrides preserve source", RimeDepotCoreProbeCatalogTargetOverrides.Bind())
    RimeDepotCoreProbeTest("archive ref URL matrix", RimeDepotCoreProbeArchiveUrls.Bind())
    RimeDepotCoreProbeTest("archive async and cancellation", RimeDepotCoreProbeArchive.Bind())
    RimeDepotCoreProbeTest("archive binary type guard", RimeDepotCoreProbeArchiveBinaryGuard.Bind())
    RimeDepotCoreProbeTest("cache generation integrity", RimeDepotCoreProbeCacheIntegrity.Bind())
    RimeDepotCoreProbeTest("HTTP request lifecycle", RimeDepotCoreProbeHttpLifecycle.Bind())
    RimeDepotCoreProbeTest("HTTP binary response normalization", RimeDepotCoreProbeHttpBinary.Bind())
    FileAppend("RimeDepot core probe passed`n", "*")
    ExitApp(0)
}

RimeDepotCoreProbeTest(name, callback) {
    try {
        callback.Call()
        FileAppend("PASS " . name . "`n", "*")
    } catch as err {
        FileAppend("FAIL " . name . ": " . err.Message . "`n", "*")
        throw err
    }
}

RimeDepotCoreProbeJson() {
    value := RimeDepotJson.Parse('{"a":[true,false,null,"x\n"],"n":-1.25e2}')
    RimeDepotCoreProbeAssert(value["a"][1] = true, "JSON true value was not parsed.")
    RimeDepotCoreProbeAssert(value["a"][2] = false, "JSON false value was not parsed.")
    RimeDepotCoreProbeAssert(value["a"][3] = "", "JSON null value was not normalized.")
    RimeDepotCoreProbeAssert(value["n"] = -125, "JSON number was not parsed.")
    text := RimeDepotJson.Stringify(value)
    RimeDepotCoreProbeAssert(IsObject(RimeDepotJson.Parse(text)), "JSON writer output was not readable.")
}

RimeDepotCoreProbeYaml() {
    value := RimeDepotYaml.Parse("entries:`n  foo:`n    repo: owner/foo`n    labels: [one, two]`n  bar:`n    repo: owner/bar`nrecipe: |`n  line one`n  line two`n")
    RimeDepotCoreProbeAssert(value["entries"]["foo"]["repo"] = "owner/foo", "YAML mapping failed.")
    RimeDepotCoreProbeAssert(value["entries"]["foo"]["labels"][2] = "two", "YAML flow array failed.")
    RimeDepotCoreProbeAssert(InStr(value["recipe"], "line two") > 0, "YAML block string failed.")
}

RimeDepotCoreProbeTarget() {
    target := RimeDepotTarget.Parse("owner/repo@v1:basic:mode=fast")
    RimeDepotCoreProbeAssert(target.Name = "owner/repo", "Target name was not parsed.")
    RimeDepotCoreProbeAssert(target.Ref = "v1" && target.Recipe = "basic", "Target ref or recipe was not parsed.")
    RimeDepotCoreProbeAssert(target.Parameters["mode"] = "fast", "Target parameter was not parsed.")
    RimeDepotCoreProbeThrows(RimeDepotTargetError, RimeDepotTarget.Parse.Bind("owner/repo:bad:1unsafe=x"),
        "Unsafe target parameter was accepted.")
    RimeDepotCoreProbeThrows(RimeDepotSecurityError, RimeDepotUtil.SafeRelativePath.Bind("..\\escape"),
        "Parent path was accepted.")
}

RimeDepotCoreProbeTargetMatrix() {
    local parameters := Map("mode", "fast"), target, zip_target, ssh_target, git_target, entry, values
    local sha_entry, branch_entry, archive_variant, archive_target, invalid_ref_target
    target := RimeDepotTarget(Map(
        "repo", "https://github.com/owner/repository",
        "ref_kind", "tag",
        "ref", "v1.2",
        "recipe", "custom",
        "parameters", parameters
    ))
    RimeDepotCoreProbeAssert(target.Repo = "https://github.com/owner/repository"
        && target.Ref = "v1.2" && target.RefKind = "tag" && target.Tag = "v1.2"
        && target.Recipe = "custom" && target.Parameters["mode"] = "fast",
        "Structured target fields were not retained.")

    zip_target := RimeDepotTarget("https://downloads.example.invalid/package.zip?token=one")
    RimeDepotCoreProbeAssert(zip_target.Repo = zip_target.ArchiveUrl
        && InStr(zip_target.ArchiveUrl, "package.zip?token=one") > 0,
        "An explicit archive URL was not retained as both source and archive.")
    ssh_target := RimeDepotTarget("ssh://git@example.invalid/owner/repository.git")
    RimeDepotCoreProbeAssert(ssh_target.Repo = "ssh://git@example.invalid/owner/repository.git"
        && ssh_target.RawBase = ssh_target.Repo,
        "An SSH repository URL was split by the compact target parser.")
    git_target := RimeDepotTarget("git@github.com:owner/repository.git")
    RimeDepotCoreProbeAssert(git_target.Repo = "git@github.com:owner/repository.git"
        && git_target.RawBase = git_target.Repo
        && RimeDepotGitClient.RepoUrl(git_target.Repo) = git_target.Repo,
        "A git@host:repo target was split or rejected by Git URL normalization.")

    sha_entry := RimeDepotCatalogEntry(Map("id", "hex-ref", "repo", "owner/hex-ref", "ref", "deadbee"))
    branch_entry := RimeDepotCatalogEntry(Map(
        "id", "named-ref", "repo", "owner/named-ref", "ref", "release-candidate"
    ))
    RimeDepotCoreProbeAssert(sha_entry.Sha = "deadbee" && sha_entry.RefKind = "sha"
        && branch_entry.Branch = "release-candidate" && branch_entry.RefKind = "branch",
        "A catalog ref without ref_kind did not infer SHA versus branch correctly.")
    for _, archive_variant in [
        "https://downloads.example.invalid/package.zip#part",
        "https://downloads.example.invalid/package.zip?token=one#part",
        "https://downloads.example.invalid/package.zip?token=one"
    ] {
        archive_target := RimeDepotTarget(archive_variant)
        RimeDepotCoreProbeAssert(archive_target.ArchiveUrl = archive_variant
            && RimeDepotArchive.GitHubArchiveUrl(archive_variant) = archive_variant,
            "An explicit archive URL with query/fragment suffix was rewritten: " . archive_variant)
        RimeDepotCoreProbeThrows(RimeDepotUnsupportedError,
            RimeDepotGitClient.RepoUrl.Bind(archive_variant),
            "Git mode accepted an explicit archive URL with query/fragment suffix: " . archive_variant)
    }
    for _, invalid_ref_target in [
        Map("repo", "owner/repository", "ref_kind", "branch"),
        Map("repo", "owner/repository", "ref_kind", "tag"),
        Map("repo", "owner/repository", "ref_kind", "sha")
    ] {
        RimeDepotCoreProbeThrows(RimeDepotTargetError,
            RimeDepotTarget.Parse.Bind(invalid_ref_target),
            "A structured target accepted ref_kind without a ref value.")
    }

    entry := RimeDepotCatalogEntry(Map(
        "id", "demo", "repo", "owner/demo", "url", "https://github.com/owner/demo",
        "archiveUrl", "https://downloads.example.invalid/demo.zip"
    ))
    values := entry.ToMap()
    RimeDepotCoreProbeAssert(values["url"] = entry.Url && values["archiveUrl"] = entry.ArchiveUrl,
        "CatalogEntry.ToMap did not expose URL and archive metadata.")
}

RimeDepotCoreProbeSafeRelativePaths() {
    local valid := ["schema0.yaml", "openfly-f098123", "openfly-f098123/"]
    local invalid := [
        "",
        "..",
        ".",
        "/abs",
        Chr(92) . Chr(92) . "UNC" . Chr(92) . "share",
        "C:" . Chr(92) . "drive",
        "folder:name"
    ]
    local root := A_Temp . "\\RimeDepotCoreProbe-safe-paths-" . A_TickCount . "-"
        . DllCall("GetCurrentProcessId", "UInt")
    local directory_path := root . "\\openfly-directory.zip", nul_path := root . "\\nul-name.zip"
    local malformed_path := root . "\\malformed-central-directory.zip"
    local directory_name := RimeDepotCoreProbeAsciiBytes("openfly-f098123/")
    local nul_name := RimeDepotCoreProbeAsciiBytes("openfly-f098123")
    local value, normalized, caught, err, byte
    nul_name.Push(0)
    for _, byte in RimeDepotCoreProbeAsciiBytes(".schema") {
        nul_name.Push(byte)
    }
    for _, value in valid {
        normalized := RimeDepotUtil.SafeRelativePath(value)
        RimeDepotCoreProbeAssert(normalized = StrReplace(value, "/", "\"),
            "A valid relative path was not normalized: " . value)
    }
    for _, value in invalid {
        caught := false
        try {
            RimeDepotUtil.SafeRelativePath(value)
        } catch as err {
            caught := true
            RimeDepotCoreProbeAssert(err is RimeDepotSecurityError,
                "An unsafe relative path raised the wrong error type: " . value)
        }
        RimeDepotCoreProbeAssert(caught, "An unsafe relative path was accepted: " . value)
    }
    ; Chr(0) is constructible, but the v2 InStr implementation treats it as
    ; an empty needle.  ZIP names therefore get a raw-byte NUL check before
    ; StrGet decodes them.
    try {
        RimeDepotArchive.WriteBinary(directory_path,
            RimeDepotCoreProbeZipCentralDirectory(directory_name))
        RimeDepotCoreProbeAssert(RimeDepotArchive.ValidateZip(directory_path),
            "A directory ZIP name containing digit zero and a trailing slash was rejected.")

        RimeDepotArchive.WriteBinary(nul_path, RimeDepotCoreProbeZipCentralDirectory(nul_name))
        caught := false
        try {
            RimeDepotArchive.ValidateZip(nul_path)
        } catch as err {
            caught := true
            RimeDepotCoreProbeAssert(err is RimeDepotSecurityError
                && InStr(err.Message, "NUL") > 0,
                "A ZIP filename NUL raised the wrong error type or message.")
        }
        RimeDepotCoreProbeAssert(caught, "A ZIP filename containing a NUL byte was accepted.")

        ; Keep the central-directory boundary smaller than the entry's
        ; declared name.  The bytes after directory_end are the EOCD record;
        ; they must never be interpreted as part of the entry header/name.
        RimeDepotArchive.WriteBinary(malformed_path, RimeDepotCoreProbeMalformedZip())
        caught := false
        try {
            RimeDepotArchive.ValidateZip(malformed_path)
        } catch as err {
            caught := true
            RimeDepotCoreProbeAssert(err is RimeDepotSecurityError
                && InStr(err.Message, "central directory") > 0,
                "A ZIP central-directory overrun raised the wrong error type or message.")
        }
        RimeDepotCoreProbeAssert(caught,
            "A ZIP entry was allowed to read its name beyond the central-directory boundary.")
    } finally {
        if DirExist(root) {
            try RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeAsciiBytes(value) {
    local bytes := [], index
    Loop StrLen(value) {
        index := A_Index
        bytes.Push(Ord(SubStr(value, index, 1)))
    }
    return bytes
}

RimeDepotCoreProbeZipCentralDirectory(name_bytes) {
    local directory_size := 46 + name_bytes.Length, eocd_offset := directory_size
    local data := Buffer(directory_size + 22, 0), index, byte
    NumPut("UInt", 0x02014B50, data, 0)
    NumPut("UShort", name_bytes.Length, data, 28)
    for index, byte in name_bytes {
        NumPut("UChar", byte, data, 46 + index - 1)
    }
    NumPut("UInt", 0x06054B50, data, eocd_offset)
    NumPut("UShort", 1, data, eocd_offset + 10)
    NumPut("UInt", directory_size, data, eocd_offset + 12)
    return data
}

RimeDepotCoreProbeMalformedZip() {
    local directory_size := 46, eocd_offset := directory_size, data := Buffer(directory_size + 22, 0)
    NumPut("UInt", 0x02014B50, data, 0)
    ; The single name byte would be the first EOCD byte, outside the declared
    ; central directory.  A file-size-only check incorrectly accepts this.
    NumPut("UShort", 1, data, 28)
    NumPut("UInt", 0x06054B50, data, eocd_offset)
    NumPut("UShort", 1, data, eocd_offset + 10)
    NumPut("UInt", directory_size, data, eocd_offset + 12)
    return data
}

RimeDepotCoreProbeConfig() {
    ini_path := A_Temp . "\\RimeDepotCoreProbe-" . A_TickCount . ".ini"
    FileAppend("[RimeDepot]`nCachePath=ini-cache`nRimeDirectory=ini-rime`nUseGit=1`nGitPath=ini-git.exe`n", ini_path)
    try {
        config := RimeDepotConfig.Load(Map(
            "CachePath", "api-cache",
            "UseGit", false,
            "GitPath", "api-git.exe"
        ), ini_path)
        RimeDepotCoreProbeAssert(config.CachePath = "api-cache", "API did not override INI CachePath.")
        RimeDepotCoreProbeAssert(config.RimeDirectory = "ini-rime", "INI RimeDirectory was not loaded.")
        RimeDepotCoreProbeAssert(!config.UseGit, "API did not override INI UseGit.")
        RimeDepotCoreProbeAssert(config.GitPath = "api-git.exe", "API did not override INI GitPath.")
    } finally {
        if FileExist(ini_path) {
            FileDelete(ini_path)
        }
    }
}

RimeDepotCoreProbeGuiSettings() {
    local root, cache_path, rime_path, settings_path, url, values, service, gui, loaded, result
    root := A_Temp . "\RimeDepotGuiSettings-" . A_TickCount . "-"
        . DllCall("GetCurrentProcessId", "UInt") . "-" . Random(100000, 999999)
    cache_path := root . "\cache"
    rime_path := root . "\rime"
    settings_path := root . "\settings.ini"
    url := "https://example.invalid/index.json"
    values := Map(
        "CachePath", cache_path,
        "RimeDirectory", rime_path,
        "RppiIndexUrl", url,
        "Proxy", "http://127.0.0.1:7890",
        "UseGit", true,
        "GitPath", "C:\Tools\git.exe"
    )
    gui := 0
    try {
        service := RimeDepotService(Map(
            "CachePath", cache_path,
            "RimeDirectory", rime_path,
            "RppiIndexUrl", url
        ), "", Map("Http", RimeDepotCoreProbeTransport(Map())))
        gui := RimeDepotGui(service, RimeDepotGuiSettings(values), settings_path)
        ; Invoke the same bound callback installed on the Save button, without
        ; showing a window or dispatching a native click.
        RimeDepotCoreProbeAssert(gui.save_settings_button.OnEvent,
            "GUI Save button was not created.")
        result := gui.SaveSettings.Bind(gui).Call(gui.save_settings_button, 0)
        RimeDepotCoreProbeAssert(result, "GUI Save button callback failed: " . gui.status_text.Value)
        loaded := RimeDepotGuiSettings.Load(settings_path)
        RimeDepotCoreProbeAssert(loaded.cache_path = cache_path
            && loaded.rime_directory = rime_path
            && loaded.rppi_index_url = url
            && loaded.proxy = values["Proxy"]
            && loaded.use_git
            && loaded.git_path = values["GitPath"],
            "GUI Save button did not round-trip all six settings fields.")
    } finally {
        if IsObject(gui) {
            try gui.Dispose()
        }
        if FileExist(settings_path) {
            try FileDelete(settings_path)
        }
        if DirExist(root) {
            try RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeCatalog() {
    local loaded_count, fallback_count
    cache_path := A_Temp . "\\RimeDepotCoreProbe-cache-" . A_TickCount
    root_url := "https://example.invalid/index.json"
    child_url := "https://example.invalid/child.json"
    first_transport := RimeDepotCoreProbeTransport(Map(
        root_url, RimeDepotHttpResponse(root_url, 200,
            '{"entries":{"foo":{"repo":"owner/foo","dependencies":["bar"]},"bar":{"repo":"owner/bar"}},"indexes":["child.json"]}',
            Map("ETag", "probe")),
        child_url, RimeDepotHttpResponse(child_url, 200, '{"entries":{"child":{"repo":"owner/child"}}}')
    ))
    try {
        service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", first_transport))
        callbacks := RimeDepotCoreProbeCallbacks()
        job := service.LoadCatalog(callbacks)
        RimeDepotCoreProbeWait(job)
        error_text := job.Error ? job.Error.Message : ""
        RimeDepotCoreProbeAssert(job.Status = "completed", "Catalog load did not complete (status=" . job.Status . ", error=" . error_text . ").")
        RimeDepotCoreProbeAssert(service.GetEntry("foo").Dependencies.Length = 1, "Catalog dependency was not loaded.")
        RimeDepotCoreProbeAssert(service.GetEntry("child").Repo = "owner/child", "Linked catalog was not loaded.")
        loaded_count := service.Catalog.ToArray().Length

        fallback_transport := RimeDepotCoreProbeTransport(Map(
            root_url, RimeDepotHttpResponse(root_url, 0, "", Map(), Error("offline")),
            child_url, RimeDepotHttpResponse(child_url, 0, "", Map(), Error("offline"))
        ))
        fallback_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", fallback_transport))
        fallback_job := fallback_service.LoadCatalog(callbacks)
        RimeDepotCoreProbeWait(fallback_job)
        RimeDepotCoreProbeAssert(fallback_job.Status = "completed", "Cached catalog fallback did not complete.")
        RimeDepotCoreProbeAssert(fallback_service.Catalog.Warnings.Length > 0, "Stale cache warning was not recorded.")
        fallback_count := fallback_service.Catalog.ToArray().Length
        RimeDepotCoreProbeAssert(fallback_count = loaded_count
            && fallback_service.GetEntry("foo").Dependencies.Length = 1
            && fallback_service.GetEntry("bar").Repo = "owner/bar"
            && fallback_service.GetEntry("child").Repo = "owner/child",
            "Cached catalog fallback changed the complete fixture entry set.")
    } finally {
        if DirExist(cache_path) {
            RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeSnapshotGate() {
    local cache_path, root_url, child_url, sha_one, sha_two, root_body, child_body
    local api_url, transport, service, job, snapshot, second_transport, second_service, second_job
    local failure_transport, failure_service, failure_job, changed_transport, changed_service, changed_job
    local refresh_transport, refresh_service, refresh_job, forty_root, forty_transport, forty_service, forty_job
    local calls, warning_count, entry, observer
    cache_path := A_Temp . "\\RimeDepotCoreProbe-snapshot-" . A_TickCount
    root_url := "https://raw.githubusercontent.com/rime/rppi/HEAD/index.json"
    child_url := "https://raw.githubusercontent.com/rime/rppi/HEAD/child/index.json"
    api_url := "https://api.github.com/repos/rime/rppi/commits?per_page=1"
    sha_one := "0123456789abcdef0123456789abcdef01234567"
    sha_two := "fedcba9876543210fedcba9876543210fedcba98"
    root_body := '{"entries":{"foo":{"repo":"owner/foo","dependencies":["bar"]},"bar":{"repo":"owner/bar","reverseDependencies":["owner/stroke"]}},"indexes":["child/index.json"]}'
    child_body := '{"entries":{"child":{"repo":"owner/child"}}}'
    try {
        transport := RimeDepotCoreProbeSnapshotTransport(Map(
            api_url, [RimeDepotHttpResponse(api_url, 200, '[{"sha":"' . sha_one . '"}]', Map("ETag", "api-v1"))],
            root_url, [RimeDepotHttpResponse(root_url, 200, root_body, Map("ETag", "raw-v1"))],
            child_url, [RimeDepotHttpResponse(child_url, 200, child_body, Map("ETag", "child-v1"))]
        ))
        service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url,
            "Proxy", "http://proxy.invalid:7890"), "", Map("Http", transport))
        observer := RimeDepotCoreProbeSnapshotObserver()
        job := service.LoadCatalog(RimeDepotCoreProbeCallbacks(
            ObjBindMethod(observer, "Progress"), ObjBindMethod(observer, "Complete"), ObjBindMethod(observer, "Error")))
        RimeDepotCoreProbeWait(job)
        RimeDepotCoreProbeAssert(job.Status = "completed" && observer.CompleteCalls = 1 && observer.ErrorCalls = 0,
            "Initial official raw catalog load did not complete exactly once.")
        RimeDepotCoreProbeAssert(transport.Calls.Length = 3 && transport.Calls[1]["Url"] = api_url
            && transport.Calls[2]["Url"] = root_url && transport.Calls[3]["Url"] = child_url,
            "Initial commit gate did not issue exactly one API probe followed by raw source loads.")
        RimeDepotCoreProbeAssert(transport.Calls[1]["Options"]["Proxy"] = "http://proxy.invalid:7890"
            && transport.Calls[1]["Options"]["Headers"]["Accept"] = "application/vnd.github+json"
            && transport.Calls[1]["Options"]["Headers"]["X-GitHub-Api-Version"] = "2022-11-28"
            && transport.Calls[1]["Options"]["Headers"]["User-Agent"] = "RimeDepot",
            "Commit probe did not preserve proxy or required GitHub headers.")
        snapshot := RimeDepotRppiCache(cache_path).ReadSnapshot(root_url)
        RimeDepotCoreProbeAssert(snapshot && snapshot["VersionSha"] = sha_one && snapshot["Eligible"]
            && snapshot["Metadata"]["complete"] = true,
            "Initial normalized catalog snapshot was not committed as a complete eligible generation.")
        entry := service.GetEntry("bar")
        RimeDepotCoreProbeAssert(entry.ReverseDependencies.Length = 1 && entry.ReverseDependencies[1] = "owner/stroke"
            && service.GetEntry("foo").ReverseDependencies.Length = 0,
            "RPPI reverse-lookup dependencies were not preserved as metadata.")

        second_transport := RimeDepotCoreProbeSnapshotTransport(Map(
            api_url, [RimeDepotHttpResponse(api_url, 304, "", Map("ETag", "api-v1"))]
        ))
        second_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", second_transport))
        second_job := second_service.LoadCatalog()
        RimeDepotCoreProbeWait(second_job)
        RimeDepotCoreProbeAssert(second_job.Status = "completed" && second_transport.Calls.Length = 1
            && second_transport.Calls[1]["Url"] = api_url,
            "Same-SHA LoadCatalog did not use one API probe and zero raw source requests.")
        RimeDepotCoreProbeAssert(second_transport.Calls[1]["Options"]["Headers"]["If-None-Match"] = "api-v1",
            "Commit probe did not send the cached API ETag.")
        RimeDepotCoreProbeAssert(second_service.GetEntry("bar").ReverseDependencies.Length = 1
            && second_service.GetEntry("bar").ReverseDependencies[1] = "owner/stroke"
            && second_service.GetEntry("foo").ReverseDependencies.Length = 0,
            "Snapshot restore did not preserve RPPI reverse-lookup dependencies.")

        failure_transport := RimeDepotCoreProbeSnapshotTransport(Map(
            api_url, [RimeDepotHttpResponse(api_url, 503, '{"message":"offline"}', Map())]
        ))
        failure_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", failure_transport))
        failure_job := failure_service.LoadCatalog()
        RimeDepotCoreProbeWait(failure_job)
        warning_count := failure_service.Catalog.Warnings.Length
        RimeDepotCoreProbeAssert(failure_job.Status = "completed" && failure_transport.Calls.Length = 1
            && warning_count > 0 && failure_service.GetEntry("foo").Dependencies.Length = 1,
            "API failure did not restore the valid snapshot with a warning.")
        RimeDepotCoreProbeAssert(RimeDepotRppiCache(cache_path).ReadSnapshot(root_url)["VersionSha"] = sha_one,
            "API failure changed the last complete snapshot.")

        changed_transport := RimeDepotCoreProbeSnapshotTransport(Map(
            api_url, [RimeDepotHttpResponse(api_url, 200, '[{"sha":"' . sha_two . '"}]', Map("ETag", "api-v2"))],
            root_url, [RimeDepotHttpResponse(root_url, 200, StrReplace(root_body, "owner/foo", "owner/foo-v2"), Map())],
            child_url, [RimeDepotHttpResponse(child_url, 200, child_body, Map())]
        ))
        changed_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", changed_transport))
        changed_job := changed_service.LoadCatalog()
        RimeDepotCoreProbeWait(changed_job)
        RimeDepotCoreProbeAssert(changed_job.Status = "completed" && changed_transport.Calls.Length = 3
            && RimeDepotRppiCache(cache_path).ReadSnapshot(root_url)["VersionSha"] = sha_two
            && changed_service.GetEntry("foo").Repo = "owner/foo-v2",
            "Changed commit SHA did not trigger a complete reload and new snapshot.")

        refresh_transport := RimeDepotCoreProbeSnapshotTransport(Map(
            root_url, [RimeDepotHttpResponse(root_url, 200, root_body, Map())],
            child_url, [RimeDepotHttpResponse(child_url, 200, child_body, Map())]
        ))
        refresh_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", refresh_transport))
        refresh_job := refresh_service.RefreshCatalog()
        RimeDepotCoreProbeWait(refresh_job)
        RimeDepotCoreProbeAssert(refresh_job.Status = "completed" && refresh_transport.Calls.Length = 2
            && refresh_transport.Calls[1]["Url"] = root_url && refresh_transport.Calls[2]["Url"] = child_url,
            "RefreshCatalog did not perform a complete raw source load without an API probe.")

        forty_root := "https://raw.githubusercontent.com/rime/rppi/" . sha_one . "/index.json"
        forty_transport := RimeDepotCoreProbeSnapshotTransport(Map(
            forty_root, [RimeDepotHttpResponse(forty_root, 200, '{"entries":{"fixed":{"repo":"owner/fixed"}}}', Map())]
        ))
        forty_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", forty_root), "",
            Map("Http", forty_transport))
        forty_job := forty_service.LoadCatalog()
        RimeDepotCoreProbeWait(forty_job)
        RimeDepotCoreProbeAssert(forty_job.Status = "completed" && forty_transport.Calls.Length = 1
            && forty_transport.Calls[1]["Url"] = forty_root,
            "A 40-hex raw ref unexpectedly made a commit API request.")
    } finally {
        if DirExist(cache_path) {
            try RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeSnapshotProbeMatrix() {
    local identity, named, slash, sha, cache_path, root_url, child_url, api_url, root_body, child_body
    local transport, service, job, snapshot, failing_cache, changed_transport, changed_service, changed_job
    local raw_paths, snapshot_paths, snapshot_metadata, second_transport, second_service, second_job
    local forty_root, forty_transport, forty_service
    local forty_job, forty_second_transport, forty_second_service, forty_second_job
    local invalid_document, invalid_entry, rejected
    sha := "0123456789abcdef0123456789abcdef01234567"
    identity := RimeDepotRppiVersionProbe.ParseRawGithubUrl(
        "https://raw.githubusercontent.com/rime/rppi/HEAD/index.json")
    RimeDepotCoreProbeAssert(identity && identity["owner"] = "rime" && identity["repo"] = "rppi"
        && identity["ref"] = "HEAD" && RimeDepotRppiVersionProbe.BuildApiUrl(identity)
            = "https://api.github.com/repos/rime/rppi/commits?per_page=1",
        "HEAD raw URL was not mapped to the default-branch commit endpoint.")
    named := RimeDepotRppiVersionProbe.ParseRawGithubUrl(
        "https://raw.githubusercontent.com/rime/rppi/release-candidate/index.json")
    RimeDepotCoreProbeAssert(named && RimeDepotRppiVersionProbe.BuildApiUrl(named)
        = "https://api.github.com/repos/rime/rppi/commits/release-candidate",
        "Named raw ref was not mapped to one encoded commit endpoint.")
    slash := Map("owner", "rime", "repo", "rppi", "ref", "feature/release")
    RimeDepotCoreProbeAssert(RimeDepotRppiVersionProbe.BuildApiUrl(slash)
        = "https://api.github.com/repos/rime/rppi/commits/feature%2Frelease",
        "Slash-bearing API ref was not encoded as one path segment.")
    RimeDepotCoreProbeAssert(!RimeDepotRppiVersionProbe.ParseRawGithubUrl(
        "http://raw.githubusercontent.com/rime/rppi/HEAD/index.json")
        && !RimeDepotRppiVersionProbe.ParseRawGithubUrl(
            "https://raw.githubusercontent.com/rime/rppi/HEAD/index.json?x=1")
        && !RimeDepotRppiVersionProbe.ParseRawGithubUrl(
            "https://raw.githubusercontent.com/rime/rppi/HEAD/../index.json")
        && !RimeDepotRppiVersionProbe.ParseRawGithubUrl(
            "https://raw.githubusercontent.com/rime/rppi/HEAD/%69ndex.json")
        && !RimeDepotRppiVersionProbe.ParseRawGithubUrl(
            "https://raw.githubusercontent.com/rime/rppi/HEAD/index" . Chr(92) . "child.json"),
        "Unsafe or non-exact raw URLs were accepted by the commit gate.")
    RimeDepotCoreProbeAssert(RimeDepotRppiVersionProbe.IsFullSha(sha)
        && !RimeDepotRppiVersionProbe.IsFullSha(SubStr(sha, 1, 39)),
        "Commit gate did not distinguish an immutable full SHA from a short ref.")

    cache_path := A_Temp . "\\RimeDepotCoreProbe-snapshot-boundaries-" . A_TickCount
    root_url := "https://raw.githubusercontent.com/rime/rppi/HEAD/index.json"
    child_url := "https://raw.githubusercontent.com/rime/rppi/HEAD/child/index.json"
    api_url := "https://api.github.com/repos/rime/rppi/commits?per_page=1"
    root_body := '{"entries":{"foo":{"repo":"owner/foo","dependencies":["bar"]},"bar":{"repo":"owner/bar"}},"indexes":["child/index.json"]}'
    child_body := '{"entries":{"child":{"repo":"owner/child"}}}'
    try {
        transport := RimeDepotCoreProbeSnapshotTransport(Map(
            api_url, [RimeDepotHttpResponse(api_url, 200, '[{"sha":"' . sha . '"}]')],
            root_url, [RimeDepotHttpResponse(root_url, 200, root_body)],
            child_url, [RimeDepotHttpResponse(child_url, 200, child_body)]
        ))
        service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", transport))
        job := service.LoadCatalog()
        RimeDepotCoreProbeWait(job)
        snapshot := RimeDepotRppiCache(cache_path).ReadSnapshot(root_url)
        RimeDepotCoreProbeAssert(job.Status = "completed" && snapshot && snapshot["Eligible"],
            "Snapshot boundary fixture did not create a valid snapshot.")
        snapshot_paths := RimeDepotRppiCache(cache_path)._SnapshotPaths(root_url)
        snapshot_metadata := snapshot["Metadata"]
        snapshot_metadata["complete"] := false
        RimeDepotUtil.AtomicWrite(snapshot_paths.Meta, RimeDepotJson.Stringify(snapshot_metadata))
        RimeDepotCoreProbeAssert(!RimeDepotRppiCache(cache_path).ReadSnapshot(root_url),
            "An incomplete normalized snapshot pointer was accepted.")
        snapshot_metadata["complete"] := true
        RimeDepotUtil.AtomicWrite(snapshot_paths.Meta, RimeDepotJson.Stringify(snapshot_metadata))
        snapshot := RimeDepotRppiCache(cache_path).ReadSnapshot(root_url)
        RimeDepotCoreProbeAssert(snapshot, "The complete normalized snapshot was not restored after the strict-marker check.")

        ; A body can have valid JSON, hashes, and generation paths while its
        ; dependency graph is still unusable.  Semantic validation must reject
        ; that generation before it can replace the committed pointer.
        invalid_document := RimeDepotJson.Parse(RimeDepotJson.Stringify(snapshot["Document"]))
        for _, invalid_entry in invalid_document["entries"] {
            if RimeDepotUtil.GetString(invalid_entry, ["id"], "") = "foo" {
                invalid_entry["dependencies"] := ["missing"]
                break
            }
        }
        rejected := false
        try {
            RimeDepotRppiCache(cache_path).WriteSnapshot(root_url, invalid_document, sha)
        } catch as err {
            rejected := true
        }
        RimeDepotCoreProbeAssert(rejected
            && RimeDepotRppiCache(cache_path).ReadSnapshot(root_url)["VersionSha"] = sha,
            "A semantically invalid snapshot was accepted or replaced the valid generation.")

        failing_cache := RimeDepotRppiCache(cache_path, RimeDepotCoreProbeCacheWriter())
        try {
            failing_cache.WriteSnapshot(root_url, snapshot["Document"],
                "fedcba9876543210fedcba9876543210fedcba98")
            throw Error("Expected snapshot metadata commit failure was not raised.")
        } catch as err {
            if InStr(err.Message, "Expected snapshot metadata") {
                throw err
            }
        }
        RimeDepotCoreProbeAssert(RimeDepotRppiCache(cache_path).ReadSnapshot(root_url)["VersionSha"] = sha,
            "A failed snapshot generation replaced the previous complete pointer.")

        ; Remove only the raw generation files.  The complete normalized
        ; snapshot must still be preserved if a changed revision cannot reload.
        raw_paths := RimeDepotRppiCache(cache_path)._Paths(root_url)
        if FileExist(raw_paths.Meta) {
            FileDelete(raw_paths.Meta)
        }
        if FileExist(raw_paths.Body) {
            FileDelete(raw_paths.Body)
        }
        changed_transport := RimeDepotCoreProbeSnapshotTransport(Map(
            api_url, [RimeDepotHttpResponse(api_url, 200,
                '[{"sha":"fedcba9876543210fedcba9876543210fedcba98"}]')],
            root_url, [RimeDepotHttpResponse(root_url, 503, "", Map())]
        ))
        changed_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", changed_transport))
        changed_job := changed_service.LoadCatalog()
        RimeDepotCoreProbeWait(changed_job)
        RimeDepotCoreProbeAssert(changed_job.Status = "completed"
            && changed_service.Catalog.Warnings.Length > 0
            && changed_service.GetEntry("foo").Repo = "owner/foo"
            && RimeDepotRppiCache(cache_path).ReadSnapshot(root_url)["VersionSha"] = sha,
            "A failed changed-revision reload did not complete from the old snapshot with a warning.")

        forty_root := "https://raw.githubusercontent.com/rime/rppi/" . sha . "/index.json"
        forty_transport := RimeDepotCoreProbeSnapshotTransport(Map(
            forty_root, [RimeDepotHttpResponse(forty_root, 200, '{"entries":{"fixed":{"repo":"owner/fixed"}}}')]
        ))
        forty_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", forty_root), "",
            Map("Http", forty_transport))
        forty_job := forty_service.LoadCatalog()
        RimeDepotCoreProbeWait(forty_job)
        forty_second_transport := RimeDepotCoreProbeSnapshotTransport(Map())
        forty_second_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", forty_root), "",
            Map("Http", forty_second_transport))
        forty_second_job := forty_second_service.LoadCatalog()
        RimeDepotCoreProbeWait(forty_second_job)
        RimeDepotCoreProbeAssert(forty_job.Status = "completed" && forty_second_job.Status = "completed"
            && forty_transport.Calls.Length = 1 && forty_second_transport.Calls.Length = 0
            && forty_second_service.GetEntry("fixed").Repo = "owner/fixed",
            "An immutable raw SHA did not enable a zero-request snapshot restore.")
    } finally {
        if DirExist(cache_path) {
            try RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeRppiSyncRequest() {
    local cache_path, root_url, response, transport, job, observer, operation
    cache_path := A_Temp . "\\RimeDepotCoreProbe-rppi-sync-" . A_TickCount
    root_url := "https://example.invalid/synchronous-index.json"
    response := RimeDepotHttpResponse(root_url, 200,
        '{"entries":{"sync":{"repo":"owner/sync"}}}', Map())
    transport := RimeDepotCoreProbeSyncTransport(Map(root_url, response))
    try {
        job := RimeDepotJob("sync-rppi")
        job.Start()
        observer := RimeDepotCoreProbeSnapshotObserver()
        operation := RimeDepotRppiLoadOperation(transport, RimeDepotRppiCache(cache_path), root_url,
            Map(), job, ObjBindMethod(observer, "Operation"))
        operation.Start()
        RimeDepotCoreProbeWaitSignal(observer)
        RimeDepotCoreProbeAssert(observer.OperationCalls = 1 && !observer.OperationError
            && operation.ActiveToken = 0 && !operation.ActiveRequest
            && transport.Calls.Length = 1 && transport.LastRequest && transport.LastRequest.CancelCalls = 0,
            "Synchronous or duplicate RPPI callbacks left a stale request handle or completed twice.")
    } finally {
        if DirExist(cache_path) {
            try RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeOfficialRppi() {
    local cache_path, root_url, child_url, transport, service, job, entry
    cache_path := A_Temp . "\\RimeDepotCoreProbe-rppi-official-" . A_TickCount
    root_url := "https://example.invalid/index.json"
    child_url := "https://example.invalid/recipes/index.json"
    transport := RimeDepotCoreProbeTransport(Map(
        root_url, RimeDepotHttpResponse(root_url, 200,
            '{"categories":[{"key":"recipes","name":"Schemes"}]}', Map()),
        child_url, RimeDepotHttpResponse(child_url, 200,
            '{"recipes":[{"id":"demo","name":"Demo scheme","repo":"owner/demo","schemas":["demo.schema"]}]}', Map())
    ))
    try {
        service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", transport))
        job := service.LoadCatalog(RimeDepotCoreProbeCallbacks())
        RimeDepotCoreProbeWait(job)
        RimeDepotCoreProbeAssert(job.Status = "completed", "Official RPPI fixture did not complete.")
        RimeDepotCoreProbeAssert(service.Catalog.ToArray().Length >= 1,
            "Official RPPI categories/recipes fixture produced no catalog entries.")
        entry := service.GetEntry("demo")
        RimeDepotCoreProbeAssert(entry.Name = "Demo scheme", "Official RPPI recipe name was not retained.")
        RimeDepotCoreProbeAssert(entry.CategoryPath = "Schemes",
            "Official RPPI category display name was not retained in the category path.")
        RimeDepotCoreProbeAssert(entry.IndexUrl = child_url, "Child RPPI index URL was not retained.")
    } finally {
        if DirExist(cache_path) {
            RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeGit() {
    RimeDepotCoreProbeAssert(RimeDepotGitRunner.ValidateExecutable("C:\\Program Files\\Git\\cmd\\git.exe"),
        "Valid git executable was rejected.")
    RimeDepotCoreProbeThrows(RimeDepotSecurityError, RimeDepotGitRunner.ValidateExecutable.Bind("cmd.exe"),
        "Shell executable was accepted as GitPath.")
    RimeDepotCoreProbeThrows(RimeDepotSecurityError, RimeDepotGitRunner.ValidateExecutable.Bind("git.exe & whoami"),
        "Command-injected GitPath was accepted.")
}

RimeDepotCoreProbeGitQuoting() {
    local ordinary, trailing, embedded
    ordinary := RimeDepotGitRunner.QuoteArgument("C:\Program Files\Git\bin\git.exe")
    RimeDepotCoreProbeAssert(ordinary = Chr(34) . "C:\Program Files\Git\bin\git.exe" . Chr(34),
        "Git quoting changed ordinary path backslashes.")
    trailing := RimeDepotGitRunner.QuoteArgument("C:\git\")
    RimeDepotCoreProbeAssert(trailing = Chr(34) . "C:\git" . Chr(92) . Chr(92) . Chr(34),
        "Git quoting did not double a trailing backslash before the closing quote.")
    embedded := RimeDepotGitRunner.QuoteArgument('a"b')
    RimeDepotCoreProbeAssert(embedded = Chr(34) . "a" . Chr(92) . Chr(34) . "b" . Chr(34),
        "Git quoting did not escape an embedded quote.")
}

RimeDepotCoreProbeGitSha() {
    local cache_path, destination, sha, config, launcher, runner, client, job, outcome, operation, commands
    local command, built
    cache_path := A_Temp . "\\RimeDepotCoreProbe-git-sha-" . A_TickCount
    destination := RimeDepotUtil.NormalizePath(cache_path . "\\owner-repository")
    sha := "0123456789abcdef0123456789abcdef01234567"
    try {
        config := RimeDepotConfig(Map("CachePath", cache_path))
        launcher := RimeDepotCoreProbeGitLauncher()
        runner := RimeDepotGitRunner("git.exe", launcher)
        client := RimeDepotGitClient(config, runner)
        job := RimeDepotJob("git-sha")
        job.Start()
        outcome := RimeDepotCoreProbeOutcome()
        operation := client.FetchAsync("owner/repository", destination, sha, job,
            ObjBindMethod(outcome, "Git"))
        RimeDepotCoreProbeAssert(outcome.Done && outcome.Success,
            "The fake SHA Git state machine did not complete successfully.")
        commands := launcher.Commands
        RimeDepotCoreProbeAssert(commands.Length = 4,
            "SHA fetch planned an unexpected number of Git commands.")
        command := commands[1].Arguments
        RimeDepotCoreProbeAssert(command.Length = 2 && command[1] = "init" && command[2] = destination,
            "SHA fetch did not begin with git init.")
        command := commands[2].Arguments
        RimeDepotCoreProbeAssert(command.Length = 6 && command[1] = "-C" && command[2] = destination
            && command[3] = "remote" && command[4] = "add" && command[5] = "origin"
            && command[6] = "https://github.com/owner/repository.git",
            "SHA fetch did not add the origin with direct Git arguments.")
        command := commands[3].Arguments
        RimeDepotCoreProbeAssert(command.Length = 7 && command[3] = "fetch" && command[4] = "--depth"
            && command[5] = "1" && command[6] = "origin" && command[7] = sha,
            "SHA fetch did not fetch the requested object directly.")
        command := commands[4].Arguments
        RimeDepotCoreProbeAssert(command.Length = 6 && command[3] = "checkout" && command[4] = "--force"
            && command[5] = "--detach" && command[6] = "FETCH_HEAD",
            "SHA fetch did not checkout FETCH_HEAD in detached mode.")
        RimeDepotCoreProbeAssert(!RimeDepotCoreProbeGitHasToken(commands, "clone"),
            "SHA fetch incorrectly used clone before fetching the full SHA.")
        built := RimeDepotGitRunner.BuildCommand("git.exe", ["fetch", "origin", "a&b"])
        RimeDepotCoreProbeAssert(!InStr(built, "cmd.exe") && InStr(built, '"a&b"') > 0,
            "Git command planning did not preserve direct executable argument quoting.")
    } finally {
        if DirExist(cache_path) {
            RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeGitVersion() {
    local config, git_path, runner, outcome, job, process
    config := RimeDepotConfig()
    git_path := config.ResolveGitPath()
    if git_path = "git.exe" {
        FileAppend("SKIP git --version: git.exe was not found on PATH`n", "*")
        return
    }
    runner := RimeDepotGitRunner(git_path)
    outcome := RimeDepotCoreProbeOutcome()
    job := RimeDepotJob("git-version")
    job.Start()
    process := runner.RunAsync(["--version"], A_WorkingDir, ObjBindMethod(outcome, "Git"), job)
    try {
        RimeDepotCoreProbeWaitSignal(outcome, 5000)
        RimeDepotCoreProbeAssert(outcome.Success && outcome.Value = 0,
            "The local git --version process did not exit successfully.")
        RimeDepotCoreProbeAssert(process.Status = "completed" && !process.Handle,
            "The local git process did not finish and release its process handle.")
    } finally {
        if !job.IsDone() {
            job.Complete(outcome.Value)
        }
    }
}

RimeDepotCoreProbeGitHasToken(commands, token) {
    local command, argument
    for _, command in commands {
        for _, argument in command.Arguments {
            if StrLower(String(argument)) = StrLower(token) {
                return true
            }
        }
    }
    return false
}

RimeDepotCoreProbeRecipe() {
    local plum_fixture, plum_recipe
    recipe := RimeDepotRecipe.Parse(Map(
        "rx", "demo",
        "install_files", ["*.yaml"],
        "patch_files", Map("default.custom.yaml", "patch")
    ), "demo")
    RimeDepotCoreProbeAssert(recipe.Name = "demo", "Recipe name was not retained.")
    RimeDepotCoreProbeThrows(RimeDepotUnsupportedError, RimeDepotRecipe.Parse.Bind(Map("command", "echo hi")),
        "Executable recipe key was accepted.")
    plum_fixture := "recipe:`n  Rx: morse`n  description: >-`n    A nested recipe fixture`ninstall_files: >-`n  morse.schema.yaml`n  lua/morse/morse.lua`n  lua/morse/morse_processor.lua`n  lua/morse/morse_translator.lua`n  lua/morse/morse_filter.lua`n"
    plum_recipe := RimeDepotRecipe.Parse(plum_fixture, "morse")
    RimeDepotCoreProbeAssert(plum_recipe.Rx = "morse", "Plum nested recipe metadata was not parsed.")
    RimeDepotCoreProbeAssert(plum_recipe.InstallFiles.Length = 5, "Plum folded install list was not split.")
}

RimeDepotCoreProbeRecipeApply() {
    local root, source_root, destination_root, url, fixture, recipe, transport, client, job, outcome, operation
    local installed_path, patch_path, installed_text, patch_text
    root := RimeDepotUtil.NormalizePath(A_Temp . "\\RimeDepotCoreProbe-recipe-" . A_TickCount)
    source_root := RimeDepotUtil.JoinPath(root, "source")
    destination_root := RimeDepotUtil.JoinPath(root, "destination")
    url := "https://example.invalid/demo.txt"
    fixture := '{"recipe":{"rx":"demo","description":"fixture recipe","args":{"name":{"default":"Alice"},"channel":"stable"}},"download_files":[{"url":"https://example.invalid/demo.txt","filename":"${name:-fallback}.txt"}],"install_files":["*.txt"],"patch_files":{"config.yaml":{"name":"${name:-fallback}","files":["${channel}","literal"],"nested":{"enabled":true}}}}'
    try {
        recipe := RimeDepotRecipe.Parse(fixture, "fixture")
        RimeDepotCoreProbeAssert(recipe.Args.Has("name"), "Recipe args metadata was not parsed.")
        RimeDepotCoreProbeAssert(RimeDepotRecipe.Expand("${missing:-fallback}", Map()) = "fallback",
            "Recipe default parameter syntax was not expanded.")
        transport := RimeDepotCoreProbeTransport(Map(
            url, RimeDepotHttpResponse(url, 200, "downloaded recipe data`n", Map())
        ))
        client := RimeDepotHttpClient(transport)
        job := RimeDepotJob("recipe-apply")
        job.Start()
        outcome := RimeDepotCoreProbeOutcome()
        operation := recipe.ApplyAsync(client, source_root, destination_root, Map(), job,
            ObjBindMethod(outcome, "Recipe"))
        RimeDepotCoreProbeWaitSignal(outcome, 3000)
        RimeDepotCoreProbeAssert(outcome.Success, "Recipe Apply fixture failed.")
        installed_path := RimeDepotUtil.JoinPath(destination_root, "Alice.txt")
        patch_path := RimeDepotUtil.JoinPath(destination_root, "config.yaml")
        RimeDepotCoreProbeAssert(FileExist(installed_path), "Recipe Apply did not install the downloaded file.")
        installed_text := FileRead(installed_path, "UTF-8")
        RimeDepotCoreProbeAssert(InStr(installed_text, "downloaded recipe data") > 0,
            "Recipe Apply installed the wrong file content.")
        RimeDepotCoreProbeAssert(FileExist(patch_path), "Recipe Apply did not create the patch file.")
        patch_text := FileRead(patch_path, "UTF-8")
        RimeDepotCoreProbeAssert(InStr(patch_text, "Alice") > 0 && InStr(patch_text, "stable") > 0,
            "Recipe Apply did not expand args/defaults in nested patch data.")
        RimeDepotCoreProbeAssert(InStr(patch_text, '"nested"') > 0 && InStr(patch_text, '"files"') > 0,
            "Recipe Apply did not serialize nested mapping/list patch data.")
        RimeDepotCoreProbeAssert(InStr(patch_text, "`n  {") > 0
            && InStr(patch_text, "`n    " . Chr(34) . "nested" . Chr(34)) > 0,
            "Recipe patch data was not indented below __patch.")
        RimeDepotCoreProbeAssert(InStr(patch_text, "__patch:") > 0, "Recipe patch marker was not written.")
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeNonRecursiveFiles() {
    local root, source_root, nested_source, package_root, opencc, nested_opencc, destination_root
    local files, config, installer, operation, job, top_file, nested_file
    root := RimeDepotUtil.NormalizePath(A_Temp . "\\RimeDepotCoreProbe-nonrecursive-" . A_TickCount)
    source_root := RimeDepotUtil.JoinPath(root, "source")
    nested_source := RimeDepotUtil.JoinPath(source_root, "nested")
    package_root := RimeDepotUtil.JoinPath(root, "package")
    opencc := RimeDepotUtil.JoinPath(package_root, "opencc")
    nested_opencc := RimeDepotUtil.JoinPath(opencc, "nested")
    destination_root := RimeDepotUtil.JoinPath(root, "destination")
    try {
        RimeDepotUtil.EnsureDirectory(nested_source)
        top_file := RimeDepotUtil.JoinPath(source_root, "top.yaml")
        nested_file := RimeDepotUtil.JoinPath(nested_source, "nested.yaml")
        FileAppend("top", top_file)
        FileAppend("nested", nested_file)
        files := RimeDepotRecipe.GlobFiles(source_root, "*.yaml")
        RimeDepotCoreProbeAssert(files.Length = 1 && files[1].Relative = "top.yaml",
            "Recipe install_files glob still recurses into subdirectories.")

        RimeDepotUtil.EnsureDirectory(nested_opencc)
        FileAppend("top", RimeDepotUtil.JoinPath(opencc, "top.json"))
        FileAppend("nested", RimeDepotUtil.JoinPath(nested_opencc, "nested.json"))
        config := RimeDepotConfig(Map("CachePath", root, "RimeDirectory", RimeDepotUtil.JoinPath(root, "rime")))
        installer := RimeDepotInstaller(config, 0)
        job := RimeDepotJob("default-files")
        operation := RimeDepotInstallerOperation(installer, 0, 0, Map(), job, 0)
        operation.InstallRoot := destination_root
        operation._InstallDefault(package_root)
        RimeDepotCoreProbeAssert(FileExist(RimeDepotUtil.JoinPath(
                RimeDepotUtil.JoinPath(destination_root, "opencc"), "top.json"))
            && !FileExist(RimeDepotUtil.JoinPath(
                RimeDepotUtil.JoinPath(RimeDepotUtil.JoinPath(destination_root, "opencc"), "nested"), "nested.json")),
            "Default OpenCC installation still recurses into subdirectories.")
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeInstallTarget() {
    local root, cache_path, rime_path, service, job, error_text
    root := RimeDepotUtil.NormalizePath(A_Temp . "\\RimeDepotCoreProbe-direct-install-" . A_TickCount)
    cache_path := RimeDepotUtil.JoinPath(root, "cache")
    rime_path := RimeDepotUtil.JoinPath(root, "rime")
    try {
        service := RimeDepotService(Map(
            "CachePath", cache_path,
            "RimeDirectory", rime_path,
            "RppiIndexUrl", "https://example.invalid/index.json"
        ), "", Map("Http", RimeDepotCoreProbeTransport(Map())))
        job := service.InstallTarget("owner/repository", Map("UseGit", false))
        RimeDepotCoreProbeAssert(job is RimeDepotJob && job.Kind = "install",
            "Direct InstallTarget did not create an installation job.")
        RimeDepotCoreProbeAssert(service.Catalog is RimeDepotCatalog && service.Catalog.ToArray().Length = 1,
            "Direct InstallTarget did not create a temporary catalog entry.")
        RimeDepotCoreProbeAssert(job.Status = "running" && !job.Error,
            "Direct InstallTarget failed before its asynchronous job was built.")
        RimeDepotCoreProbeAssert(job.Cancel(), "Direct InstallTarget job could not be cancelled.")
        error_text := job.Error ? job.Error.Message : ""
        RimeDepotCoreProbeAssert(job.Status = "cancelled",
            "Direct InstallTarget cancellation was not observed (status=" . job.Status . ", error=" . error_text . ").")
        Sleep(100)
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeDirectTargetContract() {
    local root, cache_path, rime_path, service, target, job, entry, launcher, git_runner, git_service, git_job
    local git_root, git_cache, git_rime, command
    root := RimeDepotUtil.NormalizePath(A_Temp . "\\RimeDepotCoreProbe-direct-contract-" . A_TickCount
        . "-" . DllCall("GetCurrentProcessId", "UInt"))
    cache_path := RimeDepotUtil.JoinPath(root, "cache")
    rime_path := RimeDepotUtil.JoinPath(root, "rime")
    git_root := root . "-git"
    git_cache := RimeDepotUtil.JoinPath(git_root, "cache")
    git_rime := RimeDepotUtil.JoinPath(git_root, "rime")
    try {
        service := RimeDepotService(Map(
            "CachePath", cache_path,
            "RimeDirectory", rime_path,
            "RppiIndexUrl", "https://example.invalid/index.json"
        ), "", Map("Http", RimeDepotCoreProbeTransport(Map())))
        target := Map(
            "repo", "https://downloads.example.invalid/openfly.zip",
            "ref_kind", "tag",
            "ref", "v1",
            "recipe", "custom",
            "parameters", Map("mode", "fast")
        )
        job := service.InstallTarget(target, Map("UseGit", false))
        entry := service.Catalog.Resolve("https://downloads.example.invalid/openfly.zip")
        RimeDepotCoreProbeAssert(entry.Repo = target["repo"] && entry.ArchiveUrl = target["repo"]
            && entry.Tag = "v1" && entry.RefKind = "tag" && entry.Recipe = "custom",
            "Direct target metadata was not copied to the temporary catalog entry.")
        RimeDepotCoreProbeAssert(job is RimeDepotJob && job.Cancel(),
            "Direct archive target could not be cancelled.")

        launcher := RimeDepotCoreProbeGitLauncher()
        git_runner := RimeDepotGitRunner("git.exe", launcher)
        git_service := RimeDepotService(Map(
            "CachePath", git_cache,
            "RimeDirectory", git_rime,
            "RppiIndexUrl", "https://example.invalid/index.json"
        ), "", Map("Http", RimeDepotCoreProbeTransport(Map()), "GitRunner", git_runner))
        git_job := git_service.InstallTarget(Map(
            "repo", "owner/direct",
            "ref_kind", "branch",
            "ref", "feature/direct",
            "recipe", "custom",
            "parameters", Map("mode", "fast")
        ), Map("UseGit", true))
        Sleep(100)
        RimeDepotCoreProbeAssert(launcher.Commands.Length >= 1,
            "Direct UseGit=true did not create a Git operation.")
        command := launcher.Commands[1].Arguments
        RimeDepotCoreProbeAssert(command.Length >= 6 && command[1] = "clone"
            && command[4] = "--branch" && command[5] = "feature/direct"
            && command[6] = "https://github.com/owner/direct.git",
            "Direct Git target did not preserve the structured repository/ref fields.")
        if !git_job.IsDone() {
            git_job.Cancel()
        }
    } finally {
        if DirExist(root) {
            try RimeDepotUtil.DeleteTree(root)
        }
        if DirExist(git_root) {
            try RimeDepotUtil.DeleteTree(git_root)
        }
    }
}

RimeDepotCoreProbeCatalogArchiveOnly() {
    local root, cache_path, rime_path, transport, launcher, service, catalog, entry, dependency, job, calls
    root := RimeDepotUtil.NormalizePath(A_Temp . "\\RimeDepotCoreProbe-catalog-archive-only-" . A_TickCount
        . "-" . DllCall("GetCurrentProcessId", "UInt"))
    cache_path := RimeDepotUtil.JoinPath(root, "cache")
    rime_path := RimeDepotUtil.JoinPath(root, "rime")
    try {
        transport := RimeDepotCoreProbeTransport(Map())
        launcher := RimeDepotCoreProbeGitLauncher()
        service := RimeDepotService(Map(
            "CachePath", cache_path,
            "RimeDirectory", rime_path,
            "UseGit", true,
            "RppiIndexUrl", "https://example.invalid/index.json"
        ), "", Map("Http", transport, "GitRunner", launcher))
        catalog := RimeDepotCatalog()
        dependency := catalog.Add(Map("id", "base", "name", "Base", "repo", "owner/base"), "base")
        entry := catalog.Add(Map("id", "demo", "name", "Demo", "repo", "owner/demo"), "demo")
        entry.Dependencies := [dependency.Id]
        service.Catalog := catalog
        job := service.InstallTarget(entry, Map("UseGit", true))
        Sleep(100)
        RimeDepotCoreProbeAssert(job is RimeDepotJob,
            "CatalogEntry InstallTarget did not return a RimeDepotJob.")
        calls := transport.Calls
        RimeDepotCoreProbeAssert(calls.Length >= 1
            && calls[1] = "https://github.com/owner/base/archive/HEAD.zip",
            "The archive-only catalog fixture did not build its dependency plan.")
        RimeDepotCoreProbeAssert(launcher.Commands.Length = 0,
            "CatalogEntry dependency plan created a Git operation despite archive-only routing.")
        RimeDepotCoreProbeAssert(job.Status = "failed" || job.Status = "cancelled",
            "Archive-only catalog fixture did not reach the HTTP failure path.")
    } finally {
        if DirExist(root) {
            try RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeCatalogTargetOverrides() {
    local root, cache_path, rime_path, transport, service, catalog, entry, job, calls
    root := RimeDepotUtil.NormalizePath(A_Temp . "\\RimeDepotCoreProbe-catalog-target-" . A_TickCount
        . "-" . DllCall("GetCurrentProcessId", "UInt"))
    cache_path := RimeDepotUtil.JoinPath(root, "cache")
    rime_path := RimeDepotUtil.JoinPath(root, "rime")
    try {
        transport := RimeDepotCoreProbeTransport(Map())
        service := RimeDepotService(Map(
            "CachePath", cache_path,
            "RimeDirectory", rime_path,
            "RppiIndexUrl", "https://example.invalid/index.json"
        ), "", Map("Http", transport))
        catalog := RimeDepotCatalog()
        entry := catalog.Add(Map(
            "id", "Openfly",
            "name", "Openfly",
            "repo", "owner/openfly",
            "branch", "catalog-main",
            "ref_kind", "branch"
        ), "Openfly")
        service.Catalog := catalog

        ; A bare catalog id must retain the catalog's branch/ref when no
        ; explicit target ref was supplied.
        job := service.InstallTarget("Openfly", Map("UseGit", false))
        Sleep(100)
        calls := transport.Calls
        RimeDepotCoreProbeAssert(calls.Length >= 1
            && calls[1] = "https://github.com/owner/openfly/archive/refs/heads/catalog-main.zip",
            "A bare catalog target cleared the catalog branch/ref.")

        ; The package id resolves to the catalog entry, while the compact ref
        ; remains a direct target override.  Its parsed Repo is not an
        ; explicitly supplied source and must not replace owner/openfly.
        job := service.InstallTarget("Openfly@feature/direct", Map("UseGit", false))
        Sleep(100)
        calls := transport.Calls
        RimeDepotCoreProbeAssert(calls.Length >= 2,
            "A catalog target override did not reach the archive transport.")
        RimeDepotCoreProbeAssert(calls[2] = "https://github.com/owner/openfly/archive/refs/heads/feature%2Fdirect.zip",
            "A catalog target override replaced the catalog repository with its package id.")
        RimeDepotCoreProbeAssert(job.Status = "failed" || job.Status = "cancelled",
            "The catalog target archive fixture did not reach its expected HTTP failure path.")
    } finally {
        if DirExist(root) {
            try RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeArchiveUrls() {
    local branch_url, tag_url, sha_url, encoded_url
    branch_url := RimeDepotArchive.GitHubArchiveUrl("owner/repository", "feature/space-name", "branch")
    tag_url := RimeDepotArchive.GitHubArchiveUrl("https://github.com/owner/repository", "v1.2", "tag")
    sha_url := RimeDepotArchive.GitHubArchiveUrl("owner/repository", "0123456789abcdef0123456789abcdef01234567", "sha")
    encoded_url := "https://github.com/owner/repository/archive/refs/heads/feature%2Fspace-name.zip"
    RimeDepotCoreProbeAssert(branch_url = encoded_url,
        "Branch archive URL did not encode a slash as a single path byte.")
    RimeDepotCoreProbeAssert(RimeDepotArchive.UrlEncodePath("feature/space name") = "feature%2Fspace%20name",
        "Archive path encoding did not encode slash and space as UTF-8 path bytes.")
    RimeDepotCoreProbeAssert(RimeDepotArchive.UrlEncodePath("feature/中文") = "feature%2F%E4%B8%AD%E6%96%87",
        "Archive path encoding did not preserve UTF-8 bytes for a non-ASCII ref.")
    RimeDepotCoreProbeAssert(tag_url = "https://github.com/owner/repository/archive/refs/tags/v1.2.zip",
        "Tag archive URL used the wrong GitHub endpoint.")
    RimeDepotCoreProbeAssert(sha_url = "https://github.com/owner/repository/archive/0123456789abcdef0123456789abcdef01234567.zip",
        "SHA archive URL used the wrong GitHub endpoint.")
    RimeDepotCoreProbeAssert(RimeDepotArchive.GitHubArchiveUrl("owner/repository")
        = "https://github.com/owner/repository/archive/HEAD.zip",
        "Default archive URL did not use GitHub's HEAD endpoint.")
    RimeDepotCoreProbeAssert(RimeDepotArchive.GitHubArchiveUrl("https://downloads.example.invalid/package.zip")
        = "https://downloads.example.invalid/package.zip",
        "An explicit archive URL was rewritten.")
    RimeDepotCoreProbeThrows(RimeDepotUnsupportedError,
        RimeDepotArchive.GitHubArchiveUrl.Bind("https://gitlab.example.invalid/owner/repository"),
        "A non-GitHub repository URL was accepted by archive mode.")
}

RimeDepotCoreProbeArchive() {
    local root, staging_root, archive_body, leaf, zip_child, zip_folder, zip_namespace, destination_namespace
    local shell, transport, job, outcome, operation, start_time, cancel_root, cancel_staging, cancel_destination
    local cancel_shell, cancel_transport, cancel_job, cancel_outcome, cancel_operation
    root := A_Temp . "\\RimeDepotCoreProbe-archive-" . A_TickCount
    staging_root := root . "\\staging"
    cancel_root := root . "\\cancel"
    cancel_staging := cancel_root . "\\staging"
    archive_body := Buffer(22, 0)
    NumPut("UInt", 0x06054B50, archive_body, 0)
    try {
        leaf := RimeDepotCoreProbeArchiveItem(false)
        zip_child := RimeDepotCoreProbeArchiveNamespace([leaf])
        zip_folder := RimeDepotCoreProbeArchiveItem(true, zip_child)
        zip_namespace := RimeDepotCoreProbeArchiveNamespace([zip_folder])
        destination_namespace := RimeDepotCoreProbeArchiveNamespace([], zip_namespace.Items)
        shell := RimeDepotCoreProbeArchiveShell(zip_namespace, destination_namespace)
        transport := RimeDepotCoreProbeArchiveTransport(archive_body)
        job := RimeDepotJob("archive")
        job.Start()
        outcome := RimeDepotCoreProbeOutcome()
        RimeDepotCoreProbeAssert(RimeDepotArchive.CountNamespaceItems(zip_namespace) = 2,
            "Archive namespace counting did not recurse into nested folders.")
        start_time := A_TickCount
        operation := RimeDepotArchive.DownloadAndExtractAsync(transport, "https://example.invalid/archive.zip",
            staging_root, job, ObjBindMethod(outcome, "Archive"), "", ObjBindMethod(shell, "Open"))
        RimeDepotCoreProbeAssert(A_TickCount - start_time < 500,
            "Archive Start blocked while scheduling extraction.")
        RimeDepotCoreProbeAssert(!outcome.Done, "Archive completion happened synchronously on Start.")
        RimeDepotCoreProbeWaitSignal(outcome, 3000)
        RimeDepotCoreProbeAssert(outcome.Success, "Archive async extraction fixture failed.")
        RimeDepotCoreProbeAssert(operation.ExpectedCount = 2 && destination_namespace.CopyCalls = 1,
            "Archive extraction did not use recursive stable polling after CopyHere.")

        cancel_destination := RimeDepotCoreProbeArchiveNamespace([])
        cancel_shell := RimeDepotCoreProbeArchiveShell(zip_namespace, cancel_destination)
        cancel_transport := RimeDepotCoreProbeArchiveTransport(archive_body)
        cancel_job := RimeDepotJob("archive-cancel")
        cancel_job.Start()
        cancel_outcome := RimeDepotCoreProbeOutcome()
        cancel_operation := RimeDepotArchive.DownloadAndExtractAsync(cancel_transport,
            "https://example.invalid/cancel.zip", cancel_staging, cancel_job,
            ObjBindMethod(cancel_outcome, "Archive"), "", ObjBindMethod(cancel_shell, "Open"))
        RimeDepotCoreProbeAssert(!cancel_outcome.Done, "Archive cancel fixture completed before cancellation.")
        RimeDepotCoreProbeAssert(cancel_operation.Cancel(), "Archive cancellation was not accepted.")
        Sleep(100)
        RimeDepotCoreProbeAssert(cancel_operation.Done && !cancel_outcome.Done,
            "Archive cancellation did not stop the deferred callback.")
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeArchiveBinaryGuard() {
    local root := A_Temp . "\\RimeDepotCoreProbe-archive-binary-" . A_TickCount . "-"
        . DllCall("GetCurrentProcessId", "UInt")
    local path := root . "\\archive.bin", invalid := {Size: 4}, caught := false
    local body := Buffer(4, 0), file, readback
    NumPut("UChar", 0x00, body, 0)
    NumPut("UChar", 0x7F, body, 1)
    NumPut("UChar", 0x80, body, 2)
    NumPut("UChar", 0xFF, body, 3)
    try {
        try {
            RimeDepotArchive.WriteBinary(path, invalid)
        } catch as err {
            caught := true
            RimeDepotCoreProbeAssert(err is RimeDepotError
                && InStr(err.Message, "did not contain binary data") > 0,
                "An invalid archive response raised the wrong error type or message.")
        }
        RimeDepotCoreProbeAssert(caught, "A non-Buffer object with Size was accepted as archive data.")
        RimeDepotCoreProbeAssert(!FileExist(path), "The rejected archive response created an output file.")

        RimeDepotArchive.WriteBinary(path, body)
        RimeDepotCoreProbeAssert(FileExist(path) && FileGetSize(path) = body.Size,
            "A valid Buffer was not written to the archive staging path.")
        file := FileOpen(path, "r")
        if !file {
            throw Error("The archive binary fixture could not be reopened.")
        }
        try {
            readback := Buffer(body.Size, 0)
            file.RawRead(readback)
        } finally {
            file.Close()
        }
        RimeDepotCoreProbeAssert(NumGet(readback, 0, "UChar") = 0x00
            && NumGet(readback, 1, "UChar") = 0x7F
            && NumGet(readback, 2, "UChar") = 0x80
            && NumGet(readback, 3, "UChar") = 0xFF,
            "Archive WriteBinary changed the Buffer bytes.")
    } finally {
        if DirExist(root) {
            try RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeCacheIntegrity() {
    local root, url, body_one, body_two, body_three, cache, response_one, response_two, response_three
    local cached, paths, metadata_one, metadata_two, failing_cache, writer, tampered_metadata, body_path
    local legacy_url, legacy_body, legacy_paths, legacy
    root := A_Temp . "\\RimeDepotCoreProbe-cache-generation-" . A_TickCount
    url := "https://example.invalid/cache.json"
    body_one := '{"entries":{"cached":{"repo":"owner/cached-v1"}}}'
    body_two := '{"entries":{"cached":{"repo":"owner/cached-v2"}}}'
    body_three := '{"entries":{"cached":{"repo":"owner/cached-v3"}}}'
    try {
        cache := RimeDepotRppiCache(root)
        response_one := RimeDepotHttpResponse(url, 200, body_one, Map("ETag", "one"))
        cached := cache.Write(url, body_one, response_one)
        RimeDepotCoreProbeAssert(cached && cached.FromCache && cached.Body = body_one,
            "RPPI cache first generation was not readable.")
        paths := cache._Paths(url)
        metadata_one := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
        RimeDepotCoreProbeAssert(metadata_one.Has("generation") && metadata_one["generation"] != "",
            "RPPI cache metadata has no generation.")
        RimeDepotCoreProbeAssert(metadata_one.Has("BodyFile")
            && metadata_one["BodyFile"] = RegExReplace(metadata_one["BodyFile"], ".*[\\/]", ""),
            "RPPI cache metadata has no safe generation body pointer.")
        RimeDepotCoreProbeAssert(metadata_one.Has("bodyHash")
            && metadata_one["bodyHash"] = RimeDepotRppiCache.Hash(body_one),
            "RPPI cache metadata has no matching body hash.")

        response_two := RimeDepotHttpResponse(url, 200, body_two, Map("ETag", "two"))
        cached := cache.Write(url, body_two, response_two)
        metadata_two := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
        RimeDepotCoreProbeAssert(cached && cached.Body = body_two && cached.ETag = "two",
            "RPPI cache did not read its newest generation.")
        RimeDepotCoreProbeAssert(metadata_two["generation"] != metadata_one["generation"]
            && metadata_two["BodyFile"] != metadata_one["BodyFile"],
            "RPPI cache generations did not advance.")

        ; A failure after the candidate body write but before metadata commit
        ; must leave the previous committed pointer and body readable.
        writer := RimeDepotCoreProbeCacheWriter()
        failing_cache := RimeDepotRppiCache(root, writer)
        response_three := RimeDepotHttpResponse(url, 200, body_three, Map("ETag", "three"))
        RimeDepotCoreProbeThrows(Error, failing_cache.Write.Bind(url, body_three, response_three),
            "RPPI cache accepted a simulated metadata commit failure.")
        cached := cache.Read(url)
        RimeDepotCoreProbeAssert(cached && cached.Body = body_two && cached.ETag = "two",
            "RPPI cache lost the last committed generation after a failed commit.")

        ; A pointer naming another key is not allowed to escape this cache's
        ; generation namespace, and a body hash mismatch is rejected too.
        tampered_metadata := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
        tampered_metadata["BodyFile"] := "index-foreign-generation.json"
        RimeDepotUtil.AtomicWrite(paths.Meta, RimeDepotJson.Stringify(tampered_metadata))
        RimeDepotCoreProbeAssert(!cache.Read(url), "RPPI cache accepted a foreign generation pointer.")
        RimeDepotUtil.AtomicWrite(paths.Meta, RimeDepotJson.Stringify(metadata_two))
        body_path := RimeDepotUtil.JoinPath(cache.Root, metadata_two["BodyFile"])
        RimeDepotUtil.AtomicWrite(body_path, body_two . "tampered")
        RimeDepotCoreProbeAssert(!cache.Read(url), "RPPI cache accepted a body/hash mismatch.")

        ; Preserve compatibility with the pre-pointer fixed body format.
        legacy_url := "https://example.invalid/legacy-cache.json"
        legacy_body := '{"entries":{"legacy":{"repo":"owner/legacy"}}}'
        legacy_paths := cache._Paths(legacy_url)
        RimeDepotUtil.AtomicWrite(legacy_paths.Body, legacy_body)
        RimeDepotUtil.AtomicWrite(legacy_paths.Meta, RimeDepotJson.Stringify(Map(
            "url", legacy_url,
            "generation", "legacy",
            "bodyHash", RimeDepotRppiCache.Hash(legacy_body)
        )))
        legacy := cache.Read(legacy_url)
        RimeDepotCoreProbeAssert(legacy && legacy.Body = legacy_body,
            "RPPI cache no longer accepts the legacy fixed-body format.")
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeHttpLifecycle() {
    local client, outcome, request, request2, request3, calls_after_fail, calls_after_cancel
    local poll_request, poll_fake, poll_outcome, error_request, error_fake, error_outcome
    local cancel_request, cancel_fake, cancel_outcome
    client := RimeDepotHttpClient()
    outcome := RimeDepotCoreProbeOutcome()

    request := RimeDepotHttpRequest(client, "https://example.invalid/complete", ObjBindMethod(outcome, "Http"))
    request.Request := Map("fake", true)
    client._requests[request.Id] := request
    request._Complete(RimeDepotHttpResponse(request.Url, 200, "ok", Map()))
    RimeDepotCoreProbeAssert(request.Status = "completed",
        "Completed HTTP request did not reach its terminal state.")
    RimeDepotCoreProbeAssert(!client._requests.Has(request.Id) && outcome.Calls = 1,
        "Completed HTTP request was not forgotten or delivered once.")

    request2 := RimeDepotHttpRequest(client, "https://example.invalid/fail", ObjBindMethod(outcome, "Http"))
    request2.Request := Map("fake", true)
    client._requests[request2.Id] := request2
    request2.Fail(Error("fixture failure"))
    RimeDepotCoreProbeAssert(request2.Status = "failed" && !client._requests.Has(request2.Id),
        "Failed HTTP request did not reach terminal cleanup.")
    calls_after_fail := outcome.Calls
    request2._Complete(RimeDepotHttpResponse(request2.Url, 200, "late", Map()))
    RimeDepotCoreProbeAssert(outcome.Calls = calls_after_fail,
        "A late HTTP completion invoked a failed request callback twice.")

    request3 := RimeDepotHttpRequest(client, "https://example.invalid/cancel", ObjBindMethod(outcome, "Http"))
    request3.Request := Map("fake", true)
    client._requests[request3.Id] := request3
    RimeDepotCoreProbeAssert(request3.Cancel(), "HTTP cancellation was not accepted.")
    RimeDepotCoreProbeAssert(request3.Status = "cancelled" && !client._requests.Has(request3.Id),
        "Cancelled HTTP request did not reach terminal cleanup.")
    calls_after_cancel := outcome.Calls
    request3._Complete(RimeDepotHttpResponse(request3.Url, 200, "late", Map()))
    RimeDepotCoreProbeAssert(outcome.Calls = calls_after_cancel,
        "A late HTTP completion invoked a cancelled request callback.")

    ; The production request path uses non-blocking WaitForResponse(0)
    ; polling.  Exercise pending -> complete transitions and timer cleanup
    ; without creating a WinHTTP object or any callback connection.
    poll_outcome := RimeDepotCoreProbeOutcome()
    poll_request := RimeDepotHttpRequest(client, "https://example.invalid/poll",
        ObjBindMethod(poll_outcome, "Http"))
    poll_fake := RimeDepotCoreProbeHttpPollRequest([false, true], 200, "polled", "X-Test: ok`r`n")
    poll_request.Request := poll_fake
    poll_request.Status := "running"
    poll_request._start_tick := A_TickCount
    poll_request._timeout := 5000
    poll_request._timer_active := true
    client._requests[poll_request.Id] := poll_request
    poll_request._Poll()
    RimeDepotCoreProbeAssert(poll_fake.WaitCalls = 1 && poll_request.Status = "running"
        && poll_request._timer_active, "HTTP polling did not retain a pending request.")
    poll_request._Poll()
    RimeDepotCoreProbeAssert(poll_request.Status = "completed" && !poll_request._timer_active
        && poll_outcome.Calls = 1 && poll_outcome.Success && poll_outcome.Value.Body = "polled",
        "HTTP polling did not complete and release its timer.")
    poll_request._Poll()
    RimeDepotCoreProbeAssert(poll_outcome.Calls = 1, "A late HTTP poll delivered twice.")

    error_outcome := RimeDepotCoreProbeOutcome()
    error_request := RimeDepotHttpRequest(client, "https://example.invalid/poll-error",
        ObjBindMethod(error_outcome, "Http"))
    error_fake := RimeDepotCoreProbeHttpPollRequest([Error("poll fixture failure")])
    error_request.Request := error_fake
    error_request.Status := "running"
    error_request._start_tick := A_TickCount
    error_request._timeout := 5000
    error_request._timer_active := true
    client._requests[error_request.Id] := error_request
    error_request._Poll()
    RimeDepotCoreProbeAssert(error_request.Status = "failed" && !error_request._timer_active
        && error_outcome.Calls = 1 && !error_outcome.Success,
        "HTTP polling error did not complete exactly once.")
    error_request._Poll()
    RimeDepotCoreProbeAssert(error_outcome.Calls = 1, "A late failed HTTP poll delivered twice.")

    cancel_outcome := RimeDepotCoreProbeOutcome()
    cancel_request := RimeDepotHttpRequest(client, "https://example.invalid/poll-cancel",
        ObjBindMethod(cancel_outcome, "Http"))
    cancel_fake := RimeDepotCoreProbeHttpPollRequest([false])
    cancel_request.Request := cancel_fake
    cancel_request.Status := "running"
    cancel_request._start_tick := A_TickCount
    cancel_request._timeout := 5000
    cancel_request._timer_active := true
    client._requests[cancel_request.Id] := cancel_request
    RimeDepotCoreProbeAssert(cancel_request.Cancel(), "HTTP polling cancellation was not accepted.")
    RimeDepotCoreProbeAssert(cancel_fake.AbortCalls = 1 && cancel_request.Status = "cancelled"
        && !cancel_request._timer_active && cancel_outcome.Calls = 0
        && !client._requests.Has(cancel_request.Id),
        "HTTP polling cancellation did not abort and clean up its timer.")
    cancel_request._Poll()
    RimeDepotCoreProbeAssert(cancel_outcome.Calls = 0, "A late cancelled HTTP poll delivered a callback.")
}

RimeDepotCoreProbeHttpBinary() {
    local client := RimeDepotHttpClient(), outcome := RimeDepotCoreProbeOutcome()
    local request := RimeDepotHttpRequest(client, "https://example.invalid/binary",
        ObjBindMethod(outcome, "Http"), Map("Binary", true))
    local body := ComObjArray(0x11, 4), lower_bound := body.MinIndex(), normalized
    local existing := Buffer(1), existing_normalized, wrong_type, wrong_normalized
    local empty := 0, empty_normalized, reject_root := A_Temp . "\\RimeDepotCoreProbe-http-binary-"
        . A_TickCount . "-" . DllCall("GetCurrentProcessId", "UInt")
    local reject_path := reject_root . "\\wrong-type.bin", rejected := false
    try {
        existing_normalized := RimeDepotHttpNormalizeBinary(existing)
        RimeDepotCoreProbeAssert(existing_normalized is Buffer
            && ObjPtr(existing_normalized) = ObjPtr(existing),
            "An existing Buffer was copied instead of returned unchanged.")

        body[lower_bound] := 0x00
        body[lower_bound + 1] := 0x7F
        body[lower_bound + 2] := 0x80
        body[lower_bound + 3] := 0xFF
        request.Request := RimeDepotCoreProbeHttpPollRequest([true], 200, "unused", "X-Binary: yes`r`n")
        request.Request.ResponseBody := body
        request.Status := "running"
        request._start_tick := A_TickCount
        request._timeout := 5000
        request._timer_active := true
        client._requests[request.Id] := request

        request._Poll()
        normalized := outcome.Value.Body
        RimeDepotCoreProbeAssert(outcome.Calls = 1 && outcome.Success,
            "Binary HTTP fixture did not complete successfully.")
        RimeDepotCoreProbeAssert(normalized is Buffer && normalized.Size = 4,
            "A COM byte array was not normalized to a four-byte Buffer.")
        RimeDepotCoreProbeAssert(NumGet(normalized, 0, "UChar") = 0x00
            && NumGet(normalized, 1, "UChar") = 0x7F
            && NumGet(normalized, 2, "UChar") = 0x80
            && NumGet(normalized, 3, "UChar") = 0xFF,
            "Binary HTTP normalization changed the first or last byte.")

        wrong_type := ComObjArray(0x12, 2)
        wrong_normalized := RimeDepotHttpNormalizeBinary(wrong_type)
        RimeDepotCoreProbeAssert(ObjPtr(wrong_normalized) = ObjPtr(wrong_type),
            "An unsupported COM array type was unexpectedly converted.")
        try {
            RimeDepotArchive.WriteBinary(reject_path, wrong_normalized)
        } catch as err {
            rejected := true
            RimeDepotCoreProbeAssert(err is RimeDepotError,
                "An unsupported COM array type raised the wrong archive error type.")
        }
        RimeDepotCoreProbeAssert(rejected,
            "An unsupported COM array type was accepted by the archive boundary.")

        try {
            empty := ComObjArray(0x11, 0)
        } catch as err {
            FileAppend("INFO: zero-length ComObjArray is unsupported: " . err.Message . "`n", "*")
        }
        if IsObject(empty) {
            empty_normalized := RimeDepotHttpNormalizeBinary(empty)
            RimeDepotCoreProbeAssert(empty_normalized is Buffer && empty_normalized.Size = 0,
                "A zero-length COM byte array was not normalized to Buffer(0).")
        }
    } finally {
        if DirExist(reject_root) {
            try RimeDepotUtil.DeleteTree(reject_root)
        }
    }
}

RimeDepotCoreProbeWait(job) {
    deadline := A_TickCount + 5000
    while !job.IsDone() && A_TickCount < deadline {
        Sleep(20)
    }
    RimeDepotCoreProbeAssert(job.IsDone(), "Asynchronous job did not finish before timeout (status=" . job.Status . ").")
}

RimeDepotCoreProbeAssert(condition, message) {
    if !condition {
        throw Error(message)
    }
}

RimeDepotCoreProbeThrows(error_type, callback, message) {
    caught := false
    try {
        callback.Call()
    } catch as err {
        caught := true
    }
    RimeDepotCoreProbeAssert(caught, message)
}

RimeDepotCoreProbeReportError(err) {
    message := "Uncaught exception: " . err.Message . "`n"
    if HasProp(err, "What") {
        message .= "  at " . err.What . "`n"
    }
    if HasProp(err, "File") {
        message .= "  Location: " . err.File
        if HasProp(err, "Line") {
            message .= ":" . err.Line
        }
        message .= "`n"
    }
    if HasProp(err, "Stack") {
        message .= "Stack:`n" . err.Stack . "`n"
    }
    FileAppend(message, "*")
}

RimeDepotCoreProbeWaitSignal(signal, timeout := 3000) {
    local deadline := A_TickCount + timeout
    while !signal.Done && A_TickCount < deadline {
        Sleep(20)
    }
    RimeDepotCoreProbeAssert(signal.Done, "Asynchronous fixture did not finish before timeout.")
}

class RimeDepotCoreProbeCallbacks extends RimeDepotCallbacks {
}

class RimeDepotCoreProbeTransport {
    __New(responses) {
        this.Responses := responses
        this.Calls := []
    }

    Get(url, options := 0, job := 0) {
        this.Calls.Push(url)
        if this.Responses.Has(url) {
            response := this.Responses[url]
            return RimeDepotHttpResponse(response.Url, response.Status, response.Body, response.Headers, response.Error)
        }
        return RimeDepotHttpResponse(url, 404, "", Map())
    }
}

class RimeDepotCoreProbeSnapshotTransport {
    __New(responses) {
        this.Responses := responses
        this.Calls := []
    }

    Get(url, options := 0, job := 0) {
        local response, queue, headers, copied
        headers := Map()
        if IsObject(options) {
            copied := RimeDepotUtil.GetValue(options, ["Headers", "headers"], 0)
            if IsObject(copied) {
                for key, value in copied {
                    headers[key] := value
                }
            }
        }
        this.Calls.Push(Map("Url", url, "Options", options, "Headers", headers))
        if !this.Responses.Has(url) {
            return RimeDepotHttpResponse(url, 404, "", Map())
        }
        queue := this.Responses[url]
        if !(queue is Array) || queue.Length = 0 {
            return RimeDepotHttpResponse(url, 404, "", Map())
        }
        response := queue.Length > 1 ? queue.RemoveAt(1) : queue[1]
        return RimeDepotHttpResponse(response.Url, response.Status, response.Body, response.Headers, response.Error)
    }
}

class RimeDepotCoreProbeSyncRequest {
    __New() {
        this.CancelCalls := 0
    }

    Cancel() {
        this.CancelCalls += 1
        return true
    }
}

class RimeDepotCoreProbeSyncTransport {
    __New(responses) {
        this.Responses := responses
        this.Calls := []
        this.LastRequest := 0
    }

    GetAsync(url, callback, options := 0, job := 0) {
        local response, request
        this.Calls.Push(url)
        if this.Responses.Has(url) {
            response := this.Responses[url]
            response := RimeDepotHttpResponse(response.Url, response.Status, response.Body,
                response.Headers, response.Error)
        } else {
            response := RimeDepotHttpResponse(url, 404, "", Map())
        }
        ; Deliberately deliver twice before returning the request handle.  The
        ; loader must accept only the first response and must not retain this
        ; already-completed handle for later cancellation.
        callback.Call(response)
        callback.Call(response)
        request := RimeDepotCoreProbeSyncRequest()
        this.LastRequest := request
        return request
    }
}

class RimeDepotCoreProbeOutcome {
    __New() {
        this.Done := false
        this.Success := false
        this.Value := 0
        this.Error := 0
        this.Calls := 0
    }

    Git(success, value := "", error := 0) {
        this.Calls += 1
        this.Done := true
        this.Success := !!success
        this.Value := value
        this.Error := error
    }

    Recipe(success, value := "", error := 0) {
        this.Calls += 1
        this.Done := true
        this.Success := !!success
        this.Value := value
        this.Error := error
    }

    Archive(success, value := "", error := 0) {
        this.Calls += 1
        this.Done := true
        this.Success := !!success
        this.Value := value
        this.Error := error
    }

    Http(response) {
        this.Calls += 1
        this.Done := true
        this.Success := response && response.Ok()
        this.Value := response
    }
}

class RimeDepotCoreProbeSnapshotObserver {
    __New() {
        this.ProgressCalls := 0
        this.CompleteCalls := 0
        this.ErrorCalls := 0
        this.Done := false
        this.OperationCalls := 0
        this.OperationError := 0
    }

    Progress(job, value) {
        this.ProgressCalls += 1
    }

    Complete(job, value) {
        this.CompleteCalls += 1
    }

    Error(job, value) {
        this.ErrorCalls += 1
    }

    Operation(catalog, error, warnings) {
        this.OperationCalls += 1
        this.OperationError := error
        this.Done := true
    }
}

class RimeDepotCoreProbeGitLauncher {
    __New() {
        this.Commands := []
    }

    RunAsync(path, arguments, working_directory, callback, job := 0) {
        local copied, argument, process
        copied := []
        for _, argument in arguments {
            copied.Push(String(argument))
        }
        this.Commands.Push({Path: path, Arguments: copied, WorkingDirectory: working_directory})
        process := RimeDepotCoreProbeFakeProcess()
        callback.Call(true, 0, 0)
        return process
    }
}

class RimeDepotCoreProbeFakeProcess {
    __New() {
        this.Cancelled := false
    }

    Cancel() {
        this.Cancelled := true
        return true
    }
}

class RimeDepotCoreProbeArchiveTransport {
    __New(body) {
        this.Body := body
    }

    GetAsync(url, callback, options := 0, job := 0) {
        request := RimeDepotCoreProbeArchiveRequest(callback,
            RimeDepotHttpResponse(url, 200, this.Body, Map()))
        return request.Start()
    }
}

class RimeDepotCoreProbeArchiveRequest {
    __New(callback, response) {
        this.Callback := callback
        this.Response := response
        this.Cancelled := false
        this.Delivered := false
        this._timer := ObjBindMethod(this, "_Deliver")
    }

    Start() {
        SetTimer(this._timer, -1)
        return this
    }

    Cancel() {
        if this.Cancelled || this.Delivered {
            return false
        }
        this.Cancelled := true
        SetTimer(this._timer, 0)
        return true
    }

    _Deliver() {
        if this.Cancelled || this.Delivered {
            return
        }
        this.Delivered := true
        this.Callback.Call(this.Response)
    }
}

class RimeDepotCoreProbeArchiveItem {
    __New(is_folder, folder := 0) {
        this.IsFolder := !!is_folder
        this.GetFolder := folder
    }
}

class RimeDepotCoreProbeArchiveNamespace {
    __New(items, copied_items := 0) {
        this.Items := items
        this.CopiedItems := copied_items
        this.CopyCalls := 0
    }

    CopyHere(items, flags) {
        this.CopyCalls += 1
        this.Items := this.CopiedItems ? this.CopiedItems : items
    }
}

class RimeDepotCoreProbeArchiveShell {
    __New(zip, destination) {
        this.Zip := zip
        this.Destination := destination
    }

    Open(path, destination) {
        return Map("Zip", this.Zip, "Destination", this.Destination)
    }
}

class RimeDepotCoreProbeCacheWriter {
    Call(path, content) {
        if InStr(StrLower(path), ".meta.json") {
            throw Error("simulated metadata commit failure")
        }
        RimeDepotUtil.AtomicWrite(path, content)
    }
}

class RimeDepotCoreProbeHttpPollRequest {
    __New(results, status := 200, body := "ok", headers := "") {
        this.Results := results
        this.Status := status
        this.ResponseText := body
        this.ResponseBody := body
        this.Headers := headers
        this.WaitCalls := 0
        this.AbortCalls := 0
    }

    WaitForResponse(timeout) {
        local result
        this.WaitCalls += 1
        if !this.Results.Length {
            return true
        }
        result := this.Results.RemoveAt(1)
        if IsObject(result) {
            throw result
        }
        return !!result
    }

    GetAllResponseHeaders() {
        return this.Headers
    }

    Abort() {
        this.AbortCalls += 1
    }
}
