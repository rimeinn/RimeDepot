/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

; Public include.  Each implementation module also declares its own direct
; dependencies so tests and small hosts can include a narrower module.
#Include RimeDepotTypes.ahk
#Include RimeDepotConfig.ahk
#Include RimeDepotJson.ahk
#Include RimeDepotYaml.ahk
#Include RimeDepotHttp.ahk
#Include RimeDepotRppi.ahk
#Include RimeDepotTarget.ahk
#Include RimeDepotGithub.ahk
#Include RimeDepotDirect.ahk
#Include RimeDepotRecipe.ahk
#Include RimeDepotArchive.ahk
#Include RimeDepotGit.ahk
#Include RimeDepotInstaller.ahk
#Include RimeDepotService.ahk
