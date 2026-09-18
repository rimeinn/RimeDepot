/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk
#Include RimeDepotGithub.ahk

/** User intent for one direct installation, before fetching its source. */
class RimeDepotDirectInstallRequest {
    __New(value) {
        local locator, explicit_ref := "", explicit_kind := "auto", explicit_recipe := "", parsed
        this.Locator := ""
        this.Provider := ""
        this.Repository := ""
        this.Ref := ""
        this.RefKind := "default"
        this.RecipePath := ""
        this.ArchiveUrl := ""
        this.Transport := "auto"
        this.Parameters := Map()

        if value is RimeDepotDirectInstallRequest {
            ; Reparse copies so a caller cannot bypass validation by mutating
            ; a previously constructed request object.
            value := value.ToMap()
        }
        if IsObject(value) {
            locator := RimeDepotUtil.GetString(value, ["locator", "source", "repository"], "")
            explicit_ref := RimeDepotUtil.GetString(value, ["ref"], "")
            explicit_kind := StrLower(RimeDepotUtil.GetString(value, ["ref_kind", "refKind"], "auto"))
            explicit_recipe := RimeDepotUtil.GetString(value, ["recipe_path", "recipePath"], "")
            this.Transport := StrLower(RimeDepotUtil.GetString(value, ["transport"], "auto"))
            parameters := RimeDepotUtil.GetValue(value, ["parameters"], 0)
            if IsObject(parameters) && !(parameters is Array) {
                this.Parameters := parameters
            }
        } else {
            locator := String(value)
        }
        locator := Trim(locator)
        if locator = "" {
            throw RimeDepotTargetError("A direct-install locator is required.")
        }
        this.Locator := locator
        parsed := RimeDepotGithubLocator.Parse(locator, explicit_ref)
        if parsed {
            this._ApplyParsed(parsed)
        } else {
            this._ParseGeneric(locator)
        }
        this._ApplyExplicit(explicit_ref, explicit_kind, explicit_recipe)
        this._Validate()
    }

    _ApplyParsed(parsed) {
        this.Provider := parsed["provider"]
        this.Repository := parsed["repository"]
        this.Ref := parsed["ref"]
        this.RefKind := parsed["ref_kind"]
        this.RecipePath := parsed["recipe_path"]
        this.ArchiveUrl := parsed["archive_url"]
    }

    _ParseGeneric(locator) {
        if locator ~= "i)^https?://[^\s]+\.zip(?:[?#][^\s]*)?$" {
            this.Provider := "archive"
            this.Repository := locator
            this.ArchiveUrl := locator
            return
        }
        if locator ~= "i)^[^/\\\s]+/[^/\\\s]+$" {
            this.Provider := "github"
            this.Repository := RegExReplace(locator, "i)\.git$", "")
            return
        }
        if locator ~= "i)^(?:https?://|ssh://|git@[^:]+:)[^\s]+$" {
            this.Provider := "git"
            this.Repository := locator
            return
        }
        throw RimeDepotTargetError(
            "A direct-install locator must be owner/repository, a supported GitHub URL, or a repository/archive URL."
        )
    }

    _ApplyExplicit(ref, ref_kind, recipe_path) {
        if ref != "" {
            if this.Ref != "" && this.Ref != ref {
                throw RimeDepotTargetError("The explicit ref conflicts with the source locator.")
            }
            this.Ref := ref
        }
        if ref_kind != "" && ref_kind != "auto" {
            if this.RefKind != "default" && this.RefKind != "auto" && this.RefKind != ref_kind {
                throw RimeDepotTargetError("The explicit ref kind conflicts with the source locator.")
            }
            this.RefKind := ref_kind
        } else if this.Ref != "" && this.RefKind = "default" {
            this.RefKind := "auto"
        }
        if recipe_path != "" {
            recipe_path := RimeDepotGithubLocator.ValidateRecipePath(recipe_path)
            if this.RecipePath != "" && this.RecipePath != recipe_path {
                throw RimeDepotTargetError("The explicit recipe path conflicts with the source locator.")
            }
            this.RecipePath := recipe_path
        }
    }

    _Validate() {
        if this.Ref = "" {
            if this.RefKind != "default" && this.RefKind != "auto" {
                throw RimeDepotTargetError("A ref kind requires a ref value.")
            }
            this.RefKind := "default"
        } else {
            if this.RefKind = "default" {
                this.RefKind := "auto"
            }
            if !RimeDepotDirectInstallRequest.IsRefKind(this.RefKind) {
                throw RimeDepotTargetError("Unsupported direct-install ref kind: " . this.RefKind)
            }
            RimeDepotUtil.ValidateRef(this.Ref, this.RefKind = "sha")
        }
        if this.Transport != "auto" && this.Transport != "archive" && this.Transport != "git" {
            throw RimeDepotTargetError("Unsupported direct-install transport: " . this.Transport)
        }
        if this.ArchiveUrl != "" && this.Ref != "" {
            throw RimeDepotTargetError("An explicit archive URL cannot be combined with a ref.")
        }
        if this.ArchiveUrl != "" && this.Transport = "git" {
            throw RimeDepotUnsupportedError("Git transport cannot install an explicit archive URL.")
        }
    }

    ToMap() {
        return Map(
            "locator", this.Locator,
            "provider", this.Provider,
            "repository", this.Repository,
            "ref", this.Ref,
            "ref_kind", this.RefKind,
            "recipe_path", this.RecipePath,
            "archive_url", this.ArchiveUrl,
            "transport", this.Transport,
            "parameters", this.Parameters
        )
    }

    static IsRefKind(value) {
        return value = "auto" || value = "branch" || value = "tag" || value = "sha"
    }
}
