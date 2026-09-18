/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk

/** Parse supported GitHub repository and recipe locators without network access. */
class RimeDepotGithubLocator {
    static Parse(value, ref_hint := "") {
        local locator := Trim(String(value)), clean, match
        if locator = "" {
            throw RimeDepotTargetError("A direct-install locator is required.")
        }
        if locator ~= "i)^https://github\.com/" {
            clean := RegExReplace(locator, "[?#].*$", "")
            if !RegExMatch(clean, "i)^https://github\.com/([^/]+)/([^/]+)(?:/(.*))?$", &match) {
                throw RimeDepotTargetError("Unsupported GitHub locator: " . locator)
            }
            return this._ParseGithub(match[1], match[2], match[3], ref_hint, locator)
        }
        if locator ~= "i)^https://raw\.githubusercontent\.com/" {
            clean := RegExReplace(locator, "[?#].*$", "")
            if !RegExMatch(clean, "i)^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(.*)$", &match) {
                throw RimeDepotTargetError("Unsupported raw GitHub locator: " . locator)
            }
            return this._ParseRaw(match[1], match[2], match[3], ref_hint, locator)
        }
        return 0
    }

    static _ParseGithub(owner, repository, path, ref_hint, locator) {
        local repo := this._Repository(owner, repository), ref := "", ref_kind := "default", recipe_path := ""
        local match
        path := this.UrlDecode(path)
        if path = "" {
            return this._Result(locator, repo, ref, ref_kind, recipe_path)
        }
        if RegExMatch(path, "i)^tree/(.+)$", &match) {
            ref := match[1]
            ref_kind := "auto"
        } else if RegExMatch(path, "i)^commit/([0-9a-f]{7,40})$", &match) {
            ref := match[1]
            ref_kind := "sha"
        } else if RegExMatch(path, "i)^(?:blob|raw)/(.+)$", &match) {
            parts := this._SplitRefAndRecipe(match[1], ref_hint)
            ref := parts[1]
            recipe_path := parts[2]
            ref_kind := ref ~= "i)^[0-9a-f]{7,40}$" ? "sha" : "auto"
        } else {
            throw RimeDepotTargetError(
                "A GitHub direct-install URL must identify a repository, tree, commit, or recipe file: " . locator
            )
        }
        RimeDepotUtil.ValidateRef(ref, ref_kind = "sha")
        return this._Result(locator, repo, ref, ref_kind, recipe_path)
    }

    static _ParseRaw(owner, repository, path, ref_hint, locator) {
        local repo := this._Repository(owner, repository), ref_kind := "auto", match, parts
        path := this.UrlDecode(path)
        if RegExMatch(path, "i)^refs/heads/(.+)$", &match) {
            path := match[1]
            ref_kind := "branch"
        } else if RegExMatch(path, "i)^refs/tags/(.+)$", &match) {
            path := match[1]
            ref_kind := "tag"
        }
        parts := this._SplitRefAndRecipe(path, ref_hint)
        if ref_kind = "auto" && parts[1] ~= "i)^[0-9a-f]{7,40}$" {
            ref_kind := "sha"
        }
        RimeDepotUtil.ValidateRef(parts[1], ref_kind = "sha")
        return this._Result(locator, repo, parts[1], ref_kind, parts[2])
    }

    static _SplitRefAndRecipe(value, ref_hint := "") {
        local separator
        if ref_hint != "" {
            if SubStr(value, 1, StrLen(ref_hint) + 1) != ref_hint . "/" {
                throw RimeDepotTargetError("The explicit ref does not match the recipe URL.")
            }
            return [ref_hint, this.ValidateRecipePath(SubStr(value, StrLen(ref_hint) + 2))]
        }
        separator := InStr(value, "/")
        if !separator {
            throw RimeDepotTargetError("A GitHub recipe URL does not contain a recipe path.")
        }
        return [SubStr(value, 1, separator - 1), this.ValidateRecipePath(SubStr(value, separator + 1))]
    }

    static _Repository(owner, repository) {
        owner := this.UrlDecode(owner)
        repository := RegExReplace(this.UrlDecode(repository), "i)\.git$", "")
        if owner = "" || repository = "" || owner ~= "[\\/:]" || repository ~= "[\\/:]" {
            throw RimeDepotTargetError("Unsafe GitHub repository name: " . owner . "/" . repository)
        }
        return owner . "/" . repository
    }

    static ValidateRecipePath(value) {
        local path := StrReplace(String(value), "\", "/"), safe
        if !RegExMatch(path, "i)(^|/)(?:recipe|[^/]+\.recipe)\.yaml$") {
            throw RimeDepotTargetError("A recipe locator must end in recipe.yaml or *.recipe.yaml: " . path)
        }
        safe := RimeDepotUtil.SafeRelativePath(path)
        return StrReplace(safe, "\", "/")
    }

    static RecipeId(path) {
        path := this.ValidateRecipePath(path)
        if StrLower(path) = "recipe.yaml" || StrLower(RegExReplace(path, ".*/", "")) = "recipe.yaml" {
            return ""
        }
        return RegExReplace(path, "i)\.recipe\.yaml$", "")
    }

    static UrlDecode(value) {
        local result := "", position := 1, length := StrLen(value), bytes, count, byte
        local hex
        while position <= length {
            if SubStr(value, position, 1) != "%" {
                result .= SubStr(value, position, 1)
                position += 1
                continue
            }
            bytes := Buffer(length, 0)
            count := 0
            while position + 2 <= length && SubStr(value, position, 1) = "%" {
                hex := SubStr(value, position + 1, 2)
                if !(hex ~= "i)^[0-9a-f]{2}$") {
                    throw RimeDepotTargetError("Invalid percent escape in GitHub locator.")
                }
                byte := Integer("0x" . hex)
                NumPut("UChar", byte, bytes, count)
                count += 1
                position += 3
            }
            result .= StrGet(bytes, count, "UTF-8")
        }
        return result
    }

    static _Result(locator, repository, ref, ref_kind, recipe_path) {
        return Map(
            "locator", locator,
            "provider", "github",
            "repository", repository,
            "ref", ref,
            "ref_kind", ref_kind,
            "recipe_path", recipe_path,
            "archive_url", ""
        )
    }
}
