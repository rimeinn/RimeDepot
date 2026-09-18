/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#Include RimeDepot.ahk

/**
 * The settings model used by the standalone RimeDepot window.
 *
 * The six keys in ToMap() intentionally use the same spelling as the INI
 * example.  The GUI keeps lower-case fields for normal AHK property style,
 * while this boundary makes it straightforward for a service or a test
 * double to consume a settings map without depending on the GUI.
 */
class RimeDepotGuiSettings {
    static SECTION := "RimeDepot"
    static KEYS := ["CachePath", "RimeDirectory", "RppiIndexUrl", "Proxy", "UseGit", "GitPath"]
    static DEFAULT_RPPI_INDEX_URL := "https://raw.githubusercontent.com/rime/rppi/HEAD/index.json"

    __New(values := 0) {
        this.cache_path := A_WorkingDir . "\cache"
        this.rime_directory := A_AppData . "\Rime"
        this.rppi_index_url := RimeDepotGuiSettings.DEFAULT_RPPI_INDEX_URL
        this.proxy := ""
        this.use_git := false
        this.git_path := ""
        if values {
            this.Apply(values)
        }
    }

    static Load(path) {
        local settings := this(), value
        if !path || !FileExist(path) {
            return settings
        }
        value := IniRead(path, this.SECTION, "CachePath", settings.cache_path)
        if value != "" {
            settings.cache_path := RimeDepotGuiExpandEnvironment(value)
        }
        value := IniRead(path, this.SECTION, "RimeDirectory", settings.rime_directory)
        if value != "" {
            settings.rime_directory := RimeDepotGuiExpandEnvironment(value)
        }
        value := IniRead(path, this.SECTION, "RppiIndexUrl", settings.rppi_index_url)
        if value != "" {
            settings.rppi_index_url := value
        }
        settings.proxy := IniRead(path, this.SECTION, "Proxy", settings.proxy)
        settings.use_git := RimeDepotGuiToBoolean(
            IniRead(path, this.SECTION, "UseGit", settings.use_git ? "1" : "0")
        )
        settings.git_path := RimeDepotGuiExpandEnvironment(IniRead(path, this.SECTION, "GitPath", settings.git_path))
        return settings
    }

    Apply(values) {
        local value
        value := RimeDepotGuiGetValue(values, ["CachePath", "cache_path"], "")
        if value != "" {
            this.cache_path := RimeDepotGuiExpandEnvironment(value)
        }
        value := RimeDepotGuiGetValue(values, ["RimeDirectory", "rime_directory"], "")
        if value != "" {
            this.rime_directory := RimeDepotGuiExpandEnvironment(value)
        }
        value := RimeDepotGuiGetValue(values, ["RppiIndexUrl", "rppi_index_url"], "")
        if value != "" {
            this.rppi_index_url := String(value)
        }
        this.proxy := String(RimeDepotGuiGetValue(values, ["Proxy", "proxy"], this.proxy))
        this.use_git := RimeDepotGuiToBoolean(
            RimeDepotGuiGetValue(values, ["UseGit", "use_git"], this.use_git)
        )
        this.git_path := RimeDepotGuiExpandEnvironment(
            RimeDepotGuiGetValue(values, ["GitPath", "git_path"], this.git_path)
        )
    }

    ToMap() {
        return Map(
            "CachePath", this.cache_path,
            "RimeDirectory", this.rime_directory,
            "RppiIndexUrl", this.rppi_index_url,
            "Proxy", this.proxy,
            "UseGit", this.use_git,
            "GitPath", this.git_path
        )
    }

    AsMap() {
        return this.ToMap()
    }

    Save(path) {
        local directory, key, value
        if !path {
            throw ValueError("An INI path is required.")
        }
        SplitPath(path, , &directory)
        if directory && !DirExist(directory) {
            DirCreate(directory)
        }
        for key in RimeDepotGuiSettings.KEYS {
            switch key {
                case "CachePath": value := this.cache_path
                case "RimeDirectory": value := this.rime_directory
                case "RppiIndexUrl": value := this.rppi_index_url
                case "Proxy": value := this.proxy
                case "UseGit": value := this.use_git ? "1" : "0"
                case "GitPath": value := this.git_path
            }
            IniWrite(value, path, RimeDepotGuiSettings.SECTION, key)
        }
    }
}

/**
 * A small, deliberately dependency-light browser for the RPPI catalog.
 *
 * The service is injected so the window remains independent of its host and
 * is easy to exercise with a fake service.  Service calls are made only through
 * the asynchronous RimeDepotJob contract; no network or Git operation runs
 * on the GUI event callback.
 */
class RimeDepotGui extends Gui {
    static WINDOW_WIDTH := 1080
    static RPPI_HEIGHT := 760
    static DIRECT_HEIGHT := 420
    static PBS_MARQUEE := 0x08
    static PBM_SETMARQUEE := 0x040A
    static GWL_STYLE := -16
    ; Keep the old name as a compatibility alias for small hosts which used
    ; the original fixed-height constant.  Show() now chooses by mode.
    static WINDOW_HEIGHT := RimeDepotGui.RPPI_HEIGHT

    __New(service, settings := 0, settings_path := "") {
        if settings is String && settings_path = "" {
            settings_path := settings
            settings := 0
        }
        local initial_settings := settings ? settings : RimeDepotGuiSettings()
        super.__New("+MinSize800x420", "RimeDepot — Rime package catalog")
        this.service := service
        this.settings := initial_settings is RimeDepotGuiSettings
            ? initial_settings
            : RimeDepotGuiSettings(initial_settings)
        this.settings_path := settings_path ? settings_path : A_ScriptDir . "\RimeDepot.ini"
        this.active_job := 0
        this.active_kind := ""
        this.mode := "rppi"
        this.callbacks := 0
        this.operation_token := 0
        this.catalog_entries := []
        this.visible_entries := Map()
        this.category_paths := [""]
        this.busy := false
        this.disposed := false
        this._shown := false
        this._hidden := false
        this.progress_mode := "determinate"
        this.initial_load_started := false
        this.initial_load_callback := this.StartInitialLoad.Bind(this)
        this.progress_callback := 0
        this.complete_callback := 0
        this.error_callback := 0

        this.CreateControls()
        this.LoadSettingsIntoControls()
        this.ApplyServiceSettings()
        this.SetMode("rppi")
        this.OnEvent("Close", this.OnClose.Bind(this))
        this.OnEvent("Escape", this.OnClose.Bind(this))
    }

    CreateControls() {
        this.SetFont("s10", "Microsoft YaHei UI")
        this.MarginX := 12
        this.MarginY := 12

        this.settings_group := this.AddGroupBox("x12 y10 w1056 h170", "Settings")
        this.AddText("x28 y38 w76 h24 +0x200", "Cache path")
        this.cache_path_edit := this.AddEdit("x110 y34 w278 h26")
        this.cache_browse_button := this.AddButton("x394 y34 w78 h26", "Browse…")
        this.cache_browse_button.OnEvent("Click", this.BrowseCachePath.Bind(this))

        this.AddText("x488 y38 w104 h24 +0x200", "Rime directory")
        this.rime_directory_edit := this.AddEdit("x594 y34 w338 h26")
        this.rime_browse_button := this.AddButton("x938 y34 w78 h26", "Browse…")
        this.rime_browse_button.OnEvent("Click", this.BrowseRimeDirectory.Bind(this))

        this.AddText("x28 y78 w76 h24 +0x200", "RPPI URL")
        this.rppi_index_url_edit := this.AddEdit("x110 y74 w520 h26")
        this.AddText("x648 y78 w68 h24 +0x200", "Proxy")
        this.proxy_edit := this.AddEdit("x720 y74 w296 h26")

        this.use_git_checkbox := this.AddCheckbox("x28 y114 w120 h26", "Use Git (direct)")
        this.use_git_checkbox.OnEvent("Click", this.OnUseGitChanged.Bind(this))
        this.AddText("x152 y118 w68 h24 +0x200", "Git path")
        this.git_path_edit := this.AddEdit("x224 y114 w406 h26")
        this.git_path_browse_button := this.AddButton("x638 y114 w78 h26", "Browse…")
        this.git_path_browse_button.OnEvent("Click", this.BrowseGitPath.Bind(this))
        this.git_path_hint := this.AddText("x724 y118 w206 h24 cGray", "Empty uses git from PATH.")

        this.save_settings_button := this.AddButton("x938 y112 w78 h28 +0x2000", "Save")
        this.save_settings_button.OnEvent("Click", this.SaveSettings.Bind(this))

        this.mode_label := this.AddText("x28 y150 w76 h24 +0x200", "Mode")
        this.mode_selector := this.AddDropDownList("x110 y146 w210 R2 Choose1", ["RPPI catalog", "Direct install"])
        this.mode_selector.OnEvent("Change", this.OnModeChanged.Bind(this))
        this.mode_dropdown := this.mode_selector

        this.search_label := this.AddText("x22 y198 w54 h24 +0x200", "Search")
        this.search_edit := this.AddEdit("x78 y194 w280 h26")
        this.search_edit.OnEvent("Change", this.OnFilterChanged.Bind(this))
        this.category_label := this.AddText("x378 y198 w66 h24 +0x200", "Category")
        this.category_filter := this.AddDropDownList("x448 y194 w210 R10 Choose1", ["All categories"])
        this.category_filter.OnEvent("Change", this.OnFilterChanged.Bind(this))
        this.refresh_button := this.AddButton("x774 y194 w94 h28 +0x2000", "Refresh index")
        this.refresh_button.OnEvent("Click", this.RefreshCatalog.Bind(this))
        this.install_button := this.AddButton("x876 y194 w94 h28 +0x2000 Disabled", "Install")
        this.install_button.OnEvent("Click", this.InstallSelected.Bind(this))
        this.cancel_button := this.AddButton("x978 y194 w78 h28 +0x2000 Disabled", "Cancel")
        this.cancel_button.OnEvent("Click", this.CancelActiveJob.Bind(this))

        this.catalog_list := this.AddListView(
            "x22 y230 w1036 h264 -Multi Grid",
            ["Category", "Scheme", "Schemas", "Repository", "Branch/ref", "License"]
        )
        this.catalog_list.ModifyCol(1, 150)
        this.catalog_list.ModifyCol(2, 190)
        this.catalog_list.ModifyCol(3, 185)
        this.catalog_list.ModifyCol(4, 250)
        this.catalog_list.ModifyCol(5, 110)
        this.catalog_list.ModifyCol(6, 110)
        this.catalog_list.OnEvent("ItemSelect", this.OnCatalogSelection.Bind(this))
        this.catalog_list.OnEvent("DoubleClick", this.InstallSelected.Bind(this))

        this.details_group := this.AddGroupBox("x12 y504 w1056 h176", "Selected scheme")
        this.detail_title := this.AddText("x28 y530 w1020 h24", "Select a catalog entry to see its details.")
        this.detail_summary := this.AddText("x28 y556 w1020 h24 cGray", "")
        this.detail_schemas := this.AddText("x28 y584 w1020 h22", "Schemas: ")
        this.detail_dependencies := this.AddText("x28 y608 w1020 h22", "Dependencies: ")
        this.detail_reverse_dependencies := this.AddText("x28 y632 w1020 h22", "Reverse-lookup dependencies: ")
        this.detail_labels := this.AddText("x28 y656 w760 h22", "Labels: ")
        this.detail_license := this.AddText("x802 y656 w236 h22", "License: ")

        this.direct_group := this.AddGroupBox("x12 y184 w1056 h136", "Direct source")
        this.direct_source_label := this.AddText("x22 y214 w54 h24 +0x200", "Source")
        this.direct_source_edit := this.AddEdit("x78 y210 w780 h26")
        this.direct_source_edit.OnEvent("Change", this.OnDirectInputChanged.Bind(this))
        this.direct_ref_label := this.AddText("x22 y254 w54 h24 +0x200", "Ref")
        this.direct_ref_edit := this.AddEdit("x78 y250 w780 h26")
        this.direct_hint := this.AddText(
            "x22 y282 w1034 h24 cGray",
            "Paste a GitHub repository or recipe URL. Ref is optional; repository installs check only root recipe.yaml."
        )
        this.direct_repo_edit := this.direct_source_edit
        this.direct_source := this.direct_source_edit
        this.direct_ref := this.direct_ref_edit
        this.direct_install_button := this.install_button

        this.rppi_controls := [
            this.search_label, this.search_edit, this.category_label, this.category_filter,
            this.refresh_button, this.catalog_list, this.details_group, this.detail_title,
            this.detail_summary, this.detail_schemas, this.detail_dependencies,
            this.detail_reverse_dependencies, this.detail_labels, this.detail_license
        ]
        this.rppi_interactive_controls := [
            this.search_edit, this.category_filter, this.refresh_button, this.catalog_list
        ]
        this.direct_controls := [
            this.direct_group, this.direct_source_label, this.direct_source_edit,
            this.direct_ref_label, this.direct_ref_edit, this.direct_hint
        ]

        this.status_text := this.AddText("x22 y692 w700 h22 cGray", "Ready.")
        this.progress_bar := this.AddProgress("x730 y694 w328 h18", 0)
        this.progress_bar.Value := 0
    }

    Show(options := "") {
        local show_options := Trim(String(options))
        local hidden := !!RegExMatch(show_options, "i)(^|[ \t])Hide($|[ \t])")
        local has_width := !!RegExMatch(show_options, "i)(^|[ \t])w(?:idth)?\s*[-+]?\d")
        local has_height := !!RegExMatch(show_options, "i)(^|[ \t])h(?:eight)?\s*[-+]?\d")
        if !has_width && !this._shown {
            show_options .= (show_options = "" ? "" : " ") . "w" . RimeDepotGui.WINDOW_WIDTH
        }
        if !has_height {
            show_options .= (show_options = "" ? "" : " ") . "h" . this.ModeWindowHeight()
        }
        this._shown := true
        this._hidden := hidden
        super.Show(show_options)
        if !hidden {
            this._hidden := false
        }
        if !this.initial_load_started {
            this.initial_load_started := true
            SetTimer(this.initial_load_callback, -1)
        }
    }

    Hide() {
        this._hidden := true
        return super.Hide()
    }

    ModeWindowHeight() {
        return this.mode = "direct" ? RimeDepotGui.DIRECT_HEIGHT : RimeDepotGui.RPPI_HEIGHT
    }

    BeginProgress() {
        this.progress_bar.Value := 0
        this.SetProgressMarquee(true)
    }

    SetProgressIndeterminate() {
        if !this.ProgressIsMarquee() {
            this.progress_bar.Value := 0
        }
        this.SetProgressMarquee(true)
    }

    SetProgressDeterminate(percent) {
        this.SetProgressMarquee(false)
        this.progress_bar.Value := percent
    }

    CompleteProgress() {
        this.SetProgressMarquee(false)
        this.progress_bar.Value := 100
    }

    ResetProgress() {
        this.SetProgressMarquee(false)
        this.progress_bar.Value := 0
    }

    ProgressIsMarquee() {
        return !!(this.GetProgressStyle(this.progress_bar.Hwnd) & RimeDepotGui.PBS_MARQUEE)
    }

    SetProgressMarquee(enabled) {
        local hwnd := this.progress_bar.Hwnd, style, result
        if !hwnd {
            this.progress_mode := "determinate"
            return false
        }
        style := this.GetProgressStyle(hwnd)
        if enabled {
            if !(style & RimeDepotGui.PBS_MARQUEE) {
                this.SetProgressStyle(hwnd, style | RimeDepotGui.PBS_MARQUEE)
            }
            style := this.GetProgressStyle(hwnd)
            if !(style & RimeDepotGui.PBS_MARQUEE) {
                this.progress_mode := "determinate"
                return false
            }
            result := DllCall("SendMessageW", "Ptr", hwnd, "UInt", RimeDepotGui.PBM_SETMARQUEE,
                "Ptr", 1, "Ptr", 30, "Ptr")
            style := this.GetProgressStyle(hwnd)
            if !result || !(style & RimeDepotGui.PBS_MARQUEE) {
                if style & RimeDepotGui.PBS_MARQUEE {
                    this.SetProgressStyle(hwnd, style & ~RimeDepotGui.PBS_MARQUEE)
                }
                this.progress_mode := "determinate"
                return false
            }
            this.progress_mode := "marquee"
            return true
        }
        DllCall("SendMessageW", "Ptr", hwnd, "UInt", RimeDepotGui.PBM_SETMARQUEE,
            "Ptr", 0, "Ptr", 0, "Ptr")
        if style & RimeDepotGui.PBS_MARQUEE {
            this.SetProgressStyle(hwnd, style & ~RimeDepotGui.PBS_MARQUEE)
        }
        style := this.GetProgressStyle(hwnd)
        this.progress_mode := style & RimeDepotGui.PBS_MARQUEE ? "marquee" : "determinate"
        return !(style & RimeDepotGui.PBS_MARQUEE)
    }

    GetProgressStyle(hwnd) {
        if A_PtrSize = 8 {
            return DllCall("GetWindowLongPtrW", "Ptr", hwnd, "Int", RimeDepotGui.GWL_STYLE, "Ptr")
        }
        return DllCall("GetWindowLongW", "Ptr", hwnd, "Int", RimeDepotGui.GWL_STYLE, "Int")
    }

    SetProgressStyle(hwnd, style) {
        if A_PtrSize = 8 {
            DllCall("SetWindowLongPtrW", "Ptr", hwnd, "Int", RimeDepotGui.GWL_STYLE, "Ptr", style, "Ptr")
        } else {
            DllCall("SetWindowLongW", "Ptr", hwnd, "Int", RimeDepotGui.GWL_STYLE, "Int", style, "Int")
        }
        DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0,
            "UInt", 0x27)
        DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)
    }

    StartInitialLoad(*) {
        if !this.disposed {
            this.StartCatalogLoad(false)
        }
    }

    LoadSettingsIntoControls() {
        this.cache_path_edit.Value := this.settings.cache_path
        this.rime_directory_edit.Value := this.settings.rime_directory
        this.rppi_index_url_edit.Value := this.settings.rppi_index_url
        this.proxy_edit.Value := this.settings.proxy
        this.use_git_checkbox.Value := this.settings.use_git ? 1 : 0
        this.git_path_edit.Value := this.settings.git_path
        this.UpdateGitPathState()
    }

    ReadSettingsFromControls() {
        this.settings.cache_path := Trim(this.cache_path_edit.Value)
        this.settings.rime_directory := Trim(this.rime_directory_edit.Value)
        this.settings.rppi_index_url := Trim(this.rppi_index_url_edit.Value)
        this.settings.proxy := Trim(this.proxy_edit.Value)
        this.settings.use_git := !!this.use_git_checkbox.Value
        this.settings.git_path := Trim(this.git_path_edit.Value)
    }

    SaveSettings(*) {
        if this.busy {
            return false
        }
        try {
            this.ReadSettingsFromControls()
            this.settings.Save(this.settings_path)
            this.ApplyServiceSettings()
            this.SetStatus("Settings saved to " . this.settings_path . ".")
            return true
        } catch as err {
            this.SetStatus("Could not save settings: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    ApplyServiceSettings() {
        local values := this.settings.ToMap(), config
        if !IsObject(this.service) {
            return
        }
        config := RimeDepotConfig(values)
        if HasMethod(this.service, "SetConfig") {
            this.service.SetConfig(config)
        } else if HasMethod(this.service, "Configure") {
            this.service.Configure(config)
        } else if HasProp(this.service, "Config") {
            try this.service.Config := config
        } else if HasProp(this.service, "config") {
            try this.service.config := config
        }
    }

    BrowseCachePath(*) {
        this.BrowseDirectory(this.cache_path_edit, "Select the RimeDepot cache directory")
    }

    BrowseRimeDirectory(*) {
        this.BrowseDirectory(this.rime_directory_edit, "Select the Rime user-data directory")
    }

    BrowseDirectory(edit, prompt) {
        local selected
        try {
            selected := DirSelect(edit.Value, 0, prompt)
            if selected {
                edit.Value := selected
            }
        } catch as err {
            this.SetStatus("Could not open the folder picker: " . RimeDepotGuiErrorText(err), true)
        }
    }

    BrowseGitPath(*) {
        local selected
        try {
            selected := FileSelect(3, A_WinDir, "Select the Git executable", "Executable (*.exe)")
            if selected {
                this.git_path_edit.Value := selected
            }
        } catch as err {
            this.SetStatus("Could not open the Git picker: " . RimeDepotGuiErrorText(err), true)
        }
    }

    OnUseGitChanged(*) {
        this.UpdateGitPathState()
    }

    OnModeChanged(ctrl, index := 0, *) {
        local selected
        if !IsObject(ctrl) {
            return false
        }
        selected := IsNumber(index) && index >= 1 && index <= 2 ? index : ctrl.Value
        return this.SetMode(selected = 2 ? "direct" : "rppi")
    }

    SetMode(mode) {
        local direct := mode = 2 || StrLower(String(mode)) = "direct"
        if this.busy && ((direct && this.mode != "direct") || (!direct && this.mode != "rppi")) {
            return false
        }
        this.mode := direct ? "direct" : "rppi"
        if IsObject(this.mode_selector) && this.mode_selector.Value != (direct ? 2 : 1) {
            this.mode_selector.Choose(direct ? 2 : 1)
        }
        for _, control in this.rppi_controls {
            control.Visible := !direct
        }
        for _, control in this.direct_controls {
            control.Visible := direct
        }
        this.ApplyModeLayout(direct)
        this.install_button.Text := direct ? "Install direct" : "Install"
        if direct {
            this.install_button.Enabled := !this.busy && Trim(this.direct_source_edit.Value) != ""
        } else {
            this.SyncCatalogSelection()
        }
        this.UpdateGitPathState()
        return true
    }

    ApplyModeLayout(direct) {
        local action_y := direct ? 210 : 194, status_y := direct ? 374 : 692
        this.install_button.Move(876, action_y, 94, 28)
        this.cancel_button.Move(978, action_y, 78, 28)
        this.status_text.Move(22, status_y, 700, 22)
        this.progress_bar.Move(730, status_y + 2, 328, 18)
        if this._shown {
            local hidden_options := this._hidden ? "Hide " : ""
            super.Show(Trim(hidden_options . Format("h{}", this.ModeWindowHeight())))
        }
    }

    SyncCatalogSelection() {
        local row := this.catalog_list.GetNext(0)
        if row > 0 && this.visible_entries.Has(row) {
            this.ShowDetails(this.visible_entries[row])
        } else {
            this.ClearDetails()
        }
        this.install_button.Enabled := !this.busy && row > 0
    }

    UpdateGitPathState() {
        local enabled := !this.busy && !!this.use_git_checkbox.Value
        this.git_path_edit.Enabled := enabled
        this.git_path_browse_button.Enabled := enabled
    }

    OnDirectInputChanged(*) {
        if this.mode = "direct" {
            this.install_button.Enabled := !this.busy && Trim(this.direct_source_edit.Value) != ""
        }
    }

    RefreshCatalog(*) {
        if this.mode != "rppi" {
            return false
        }
        this.StartCatalogLoad(true)
    }

    StartCatalogLoad(force_refresh) {
        local token, callbacks
        if this.disposed || this.busy {
            return false
        }
        if !IsObject(this.service) {
            this.SetStatus("No RimeDepot service is configured.", true)
            return false
        }
        this.ReadSettingsFromControls()
        try {
            this.ApplyServiceSettings()
            this.operation_token += 1
            token := this.operation_token
            this.active_kind := "catalog"
            this.BeginProgress()
            this.SetStatus(force_refresh ? "Refreshing RPPI index…" : "Loading RPPI index…")
            callbacks := this.CreateCallbacks(token, "catalog")
            this.callbacks := callbacks
            this.SetBusy(true)
            this.active_job := force_refresh
                ? this.service.RefreshCatalog(callbacks)
                : this.service.LoadCatalog(callbacks)
            if !IsObject(this.active_job) {
                throw Error("The catalog operation did not return a RimeDepotJob.")
            }
            ; A service/test transport may complete synchronously before the
            ; call returns.  The completion/error callback then runs while
            ; active_job still points at the previous operation; re-check the
            ; returned job here so the completed object cannot remain stuck in
            ; the GUI's active state.
            if HasMethod(this.active_job, "IsDone") && this.active_job.IsDone() {
                this.FinishOperation(token)
            }
            return true
        } catch as err {
            this.ResetProgress()
            this.FinishOperation(token ?? this.operation_token)
            this.SetStatus("Could not start catalog operation: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    CreateCallbacks(token, kind := "catalog") {
        this.progress_callback := this.OnProgress.Bind(this, token)
        this.complete_callback := kind = "install"
            ? this.OnInstallComplete.Bind(this, token) : this.OnCatalogComplete.Bind(this, token)
        this.error_callback := this.OnOperationError.Bind(this, token)
        return RimeDepotCallbacks(this.progress_callback, this.complete_callback, this.error_callback)
    }

    InstallSelected(*) {
        if this.mode = "direct" {
            return this.InstallDirect()
        }
        local row := this.catalog_list.GetNext(0), entry, token, callbacks
        if this.disposed || this.busy || row < 1 || !this.visible_entries.Has(row) {
            return false
        }
        entry := this.visible_entries[row]
        try {
            this.ReadSettingsFromControls()
            this.ApplyServiceSettings()
            this.operation_token += 1
            token := this.operation_token
            this.active_kind := "install"
            this.BeginProgress()
            this.SetStatus("Installing " . RimeDepotGuiEntryText(entry, ["name", "Name"], "selected scheme") . "…")
            callbacks := this.CreateCallbacks(token, "install")
            this.callbacks := callbacks
            this.SetBusy(true)
            this.active_job := this.service.InstallEntry(entry, callbacks)
            if !IsObject(this.active_job) {
                throw Error("The install operation did not return a RimeDepotJob.")
            }
            if HasMethod(this.active_job, "IsDone") && this.active_job.IsDone() {
                this.FinishOperation(token)
            }
            return true
        } catch as err {
            this.ResetProgress()
            this.FinishOperation(token ?? this.operation_token)
            this.SetStatus("Could not start installation: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    InstallDirect(*) {
        local source := Trim(this.direct_source_edit.Value), ref := Trim(this.direct_ref_edit.Value)
        local request, token, callbacks
        if this.disposed || this.busy {
            return false
        }
        if source = "" {
            this.SetStatus("Direct source is required.", true)
            return false
        }
        request := Map(
            "locator", source,
            "ref", ref,
            "transport", this.use_git_checkbox.Value ? "git" : "archive"
        )
        try {
            RimeDepotDirectInstallRequest(request)
            this.ReadSettingsFromControls()
            this.ApplyServiceSettings()
            this.operation_token += 1
            token := this.operation_token
            this.active_kind := "install"
            this.BeginProgress()
            this.SetStatus("Installing direct source…")
            callbacks := this.CreateCallbacks(token, "install")
            this.callbacks := callbacks
            this.SetBusy(true)
            this.active_job := this.service.InstallDirect(request, callbacks)
            if !IsObject(this.active_job) {
                throw Error("The direct install operation did not return a RimeDepotJob.")
            }
            if HasMethod(this.active_job, "IsDone") && this.active_job.IsDone() {
                this.FinishOperation(token)
            }
            return true
        } catch as err {
            this.ResetProgress()
            this.FinishOperation(token ?? this.operation_token)
            this.SetStatus("Could not start direct installation: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    CancelActiveJob(*) {
        local job := this.active_job
        if !this.busy || !IsObject(job) {
            return false
        }
        try {
            if HasMethod(job, "Cancel") {
                job.Cancel()
            } else if HasMethod(job, "cancel") {
                job.cancel()
            } else {
                throw Error("The active RimeDepotJob cannot be cancelled.")
            }
            ; A cancellation implementation may synchronously report its
            ; terminal error/complete callback.  Do not overwrite that final
            ; state with a pending message after the callback has released
            ; the active job.
            if this.busy && IsObject(this.active_job) && this.active_job = job && (!HasMethod(job, "IsDone") || !job.IsDone()) {
                this.SetStatus("Cancellation requested…")
            }
            return true
        } catch as err {
            this.SetStatus("Could not cancel operation: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    CreateOperationCallbacks(token) {
        return this.CreateCallbacks(token)
    }

    OnProgress(token, job_or_progress := 0, progress_or_message := "", extra*) {
        local progress, message, percent, text
        if this.disposed || token != this.operation_token || !this.busy {
            return
        }
        if RimeDepotGuiLooksLikeJob(job_or_progress) {
            progress := progress_or_message
            message := extra.Length ? extra[1] : ""
        } else {
            progress := job_or_progress
            message := progress_or_message
        }
        percent := RimeDepotGuiProgressPercent(progress)
        if percent >= 0 {
            this.SetProgressDeterminate(percent)
        } else {
            this.SetProgressIndeterminate()
        }
        text := RimeDepotGuiProgressText(progress, message)
        if text != "" {
            this.SetStatus(text)
        }
    }

    OnCatalogComplete(token, job_or_result := 0, result_or_extra := 0, extra*) {
        local result, result_extra, entries, warning, count, value
        if this.disposed || token != this.operation_token {
            return
        }
        if RimeDepotGuiLooksLikeJob(job_or_result) {
            result := result_or_extra
            result_extra := extra
        } else {
            result := job_or_result
            result_extra := [result_or_extra]
            for _, value in extra {
                result_extra.Push(value)
            }
        }
        entries := RimeDepotGuiExtractCatalog(result, result_extra)
        this.catalog_entries := entries
        this.UpdateCategoryFilter()
        this.RefreshCatalogView()
        warning := RimeDepotGuiCatalogWarning(result, result_extra)
        count := entries.Length
        this.CompleteProgress()
        this.FinishOperation(token)
        if warning != "" {
            this.SetStatus("Loaded " . count . " scheme(s). Warning: " . warning, true)
        } else {
            this.SetStatus("Loaded " . count . " scheme(s).")
        }
    }

    OnInstallComplete(token, job_or_result := 0, result_or_extra := 0, extra*) {
        local result, entries, count
        if this.disposed || token != this.operation_token {
            return
        }
        result := RimeDepotGuiLooksLikeJob(job_or_result) ? result_or_extra : job_or_result
        entries := RimeDepotGuiGetValue(result, ["entries", "Entries"], 0)
        count := entries is Array ? entries.Length : 0
        this.CompleteProgress()
        this.FinishOperation(token)
        this.SetStatus(count > 0 ? "Installed " . count . " package(s)." : "Installation completed.")
    }

    OnOperationError(token, job_or_error := 0, error_or_extra := 0, extra*) {
        local error_value, text
        if RimeDepotGuiLooksLikeJob(job_or_error) {
            error_value := error_or_extra
        } else {
            error_value := job_or_error
        }
        text := RimeDepotGuiErrorText(error_value)
        if text = "" {
            text := RimeDepotGuiErrorText(extra.Length ? extra[1] : "The RimeDepot operation failed.")
        }
        if this.disposed || token != this.operation_token {
            return
        }
        this.ResetProgress()
        this.FinishOperation(token)
        this.SetStatus("Operation failed: " . text, true)
    }

    FinishOperation(token) {
        local callback_object := this.callbacks
        if token != this.operation_token {
            return
        }
        this.active_job := 0
        this.active_kind := ""
        this.callbacks := 0
        this.SetProgressMarquee(false)
        this.SetBusy(false)
        if IsObject(callback_object) && HasMethod(callback_object, "Dispose") {
            try callback_object.Dispose()
        }
    }

    SetBusy(busy) {
        local enabled := !busy
        this.busy := !!busy
        this.cache_path_edit.Enabled := enabled
        this.cache_browse_button.Enabled := enabled
        this.rime_directory_edit.Enabled := enabled
        this.rime_browse_button.Enabled := enabled
        this.rppi_index_url_edit.Enabled := enabled
        this.proxy_edit.Enabled := enabled
        this.use_git_checkbox.Enabled := enabled
        this.mode_selector.Enabled := enabled
        this.save_settings_button.Enabled := enabled
        this.install_button.Enabled := enabled && (this.mode = "direct"
            ? Trim(this.direct_source_edit.Value) != "" : this.catalog_list.GetNext(0) > 0)
        this.cancel_button.Enabled := !!busy
        for _, control in this.rppi_interactive_controls {
            control.Enabled := enabled
        }
        for _, control in this.direct_controls {
            control.Enabled := enabled
        }
        this.UpdateGitPathState()
    }

    OnFilterChanged(*) {
        if !this.disposed && !this.busy {
            this.RefreshCatalogView()
        }
    }

    SelectedCategoryPath() {
        local index := this.category_filter.Value
        if index < 1 || index > this.category_paths.Length {
            return ""
        }
        return this.category_paths[index]
    }

    CanonicalCategoryPath(value) {
        local parts, canonical := "", part
        value := Trim(String(value))
        if value = "" {
            return "Uncategorized"
        }
        parts := StrSplit(value, " / ")
        for _, part in parts {
            part := Trim(part)
            if part = "" {
                continue
            }
            canonical := canonical = "" ? part : canonical . " / " . part
        }
        return canonical = "" ? "Uncategorized" : canonical
    }

    CategoryPathForEntry(entry) {
        return this.CanonicalCategoryPath(RimeDepotGuiEntryText(
            entry,
            ["category_path", "CategoryPath", "category", "Category"],
            "Uncategorized"
        ))
    }

    CategoryLeafName(path) {
        local parts := StrSplit(path, " / ")
        return parts[parts.Length]
    }

    CategoryParentPath(path) {
        local parts := StrSplit(path, " / "), parent := "", index
        if parts.Length <= 1 {
            return ""
        }
        Loop parts.Length - 1 {
            index := A_Index
            parent := parent = "" ? parts[index] : parent . " / " . parts[index]
        }
        return parent
    }

    CategoryDisplayText(path, leaf_counts := 0) {
        local parts := StrSplit(path, " / "), leaf := parts[parts.Length], indent := "", suffix
        Loop parts.Length - 1 {
            indent .= "    "
        }
        if path = "All categories" {
            leaf .= " (category)"
        } else if IsObject(leaf_counts) && leaf_counts.Has(leaf) && leaf_counts[leaf] > 1 {
            suffix := this.CategoryParentPath(path)
            leaf .= " (" . (suffix != "" ? suffix : "top level") . ")"
        }
        return indent . leaf
    }

    UpdateCategoryFilter() {
        local selected := this.SelectedCategoryPath()
        local categories, paths, category_tree, category_node, category_child
        local parts, part, path, index, selected_index := 1, leaf_counts := Map()
        category_tree := Map("path", "", "children", Map(), "order", [])
        for entry in this.catalog_entries {
            category := this.CategoryPathForEntry(entry)
            parts := StrSplit(category, " / ")
            category_node := category_tree
            for _, part in parts {
                if part = "" {
                    continue
                }
                if !category_node["children"].Has(part) {
                    path := category_node["path"] = "" ? part : category_node["path"] . " / " . part
                    category_child := Map("path", path, "children", Map(), "order", [])
                    category_node["children"][part] := category_child
                    category_node["order"].Push(part)
                }
                category_node := category_node["children"][part]
            }
        }
        paths := [""]
        this.AppendCategoryTreePreorder(category_tree, paths)
        this.category_paths := paths
        categories := ["All categories"]
        for index, path in paths {
            if index = 1 {
                continue
            }
            category := this.CategoryLeafName(path)
            leaf_counts[category] := leaf_counts.Has(category) ? leaf_counts[category] + 1 : 1
        }
        for index, path in paths {
            if index > 1 {
                categories.Push(this.CategoryDisplayText(path, leaf_counts))
            }
        }
        this.category_filter.Delete()
        this.category_filter.Add(categories)
        if selected != "" {
            for index, path in paths {
                if path = selected {
                    selected_index := index
                    break
                }
            }
        }
        this.category_filter.Choose(selected_index)
    }

    AppendCategoryTreePreorder(root, paths) {
        local stack := [Map("node", root, "index", 1)]
        local frame, node, child_name, child
        while stack.Length {
            frame := stack[stack.Length]
            node := frame["node"]
            if frame["index"] > node["order"].Length {
                stack.Pop()
                continue
            }
            child_name := node["order"][frame["index"]]
            frame["index"] += 1
            child := node["children"][child_name]
            paths.Push(child["path"])
            stack.Push(Map("node", child, "index", 1))
        }
    }

    RefreshCatalogView(*) {
        local query := StrLower(Trim(this.search_edit.Value)), category := this.SelectedCategoryPath()
        local entry, row, values, name, entry_category
        this.catalog_list.Delete()
        this.visible_entries := Map()
        for entry in this.catalog_entries {
            name := RimeDepotGuiEntryText(entry, ["name"], "")
            entry_category := this.CategoryPathForEntry(entry)
            if category != "" && entry_category != category
                && SubStr(entry_category, 1, StrLen(category) + 3) != category . " / " {
                continue
            }
            if query != "" && !InStr(StrLower(
                name . " " . entry_category . " " . RimeDepotGuiEntryText(entry, ["repo", "Repo", "repository", "Repository"], "")
                    . " " . RimeDepotGuiEntryText(entry, ["schemas", "Schemas"], "")
            ), query) {
                continue
            }
            values := [
                entry_category,
                name,
                RimeDepotGuiEntryText(entry, ["schemas", "Schemas"], ""),
                RimeDepotGuiEntryText(entry, ["repo", "Repo", "repository", "Repository"], ""),
                RimeDepotGuiEntryRef(entry),
                RimeDepotGuiEntryText(entry, ["license", "License", "licence", "Licence"], "")
            ]
            row := this.catalog_list.Add("", values*)
            this.visible_entries[row] := entry
        }
        this.install_button.Enabled := !this.busy && this.catalog_list.GetNext(0) > 0
        this.ClearDetails()
    }

    OnCatalogSelection(ctrl, row, selected) {
        local current_row := ctrl.GetNext(0)
        if current_row > 0 && this.visible_entries.Has(current_row) {
            this.ShowDetails(this.visible_entries[current_row])
        } else {
            this.ClearDetails()
        }
        this.install_button.Enabled := !this.busy && this.catalog_list.GetNext(0) > 0
    }

    ShowDetails(entry) {
        local category := this.CategoryPathForEntry(entry)
        local name := RimeDepotGuiEntryText(entry, ["name", "Name"], "")
        local repo := RimeDepotGuiEntryText(entry, ["repo", "Repo", "repository", "Repository"], "")
        local branch := RimeDepotGuiEntryRef(entry)
        this.detail_title.Value := name != "" ? name : "Selected scheme"
        this.detail_summary.Value := "Category: " . category . "    Repository: " . repo . "    Branch/ref: " . branch
        this.detail_schemas.Value := "Schemas: " . RimeDepotGuiEntryText(entry, ["schemas", "Schemas"], "(none)")
        this.detail_dependencies.Value := "Dependencies: "
            . RimeDepotGuiEntryText(entry, ["dependencies", "Dependencies"], "(none)")
        this.detail_reverse_dependencies.Value := "Reverse-lookup dependencies: "
            . RimeDepotGuiEntryText(
                entry,
                ["reverseDependencies", "ReverseDependencies", "reverse_dependencies"],
                "(none)"
            )
        this.detail_labels.Value := "Labels: " . RimeDepotGuiEntryText(entry, ["labels", "Labels"], "(none)")
        this.detail_license.Value := "License: "
            . RimeDepotGuiEntryText(entry, ["license", "License"], "(unspecified)")
    }

    ClearDetails() {
        this.detail_title.Value := this.catalog_entries.Length ? "Select a catalog entry to see its details." : "No catalog entries."
        this.detail_summary.Value := ""
        this.detail_schemas.Value := "Schemas: "
        this.detail_dependencies.Value := "Dependencies: "
        this.detail_reverse_dependencies.Value := "Reverse-lookup dependencies: "
        this.detail_labels.Value := "Labels: "
        this.detail_license.Value := "License: "
    }

    SetStatus(text, warning := false) {
        this.status_text.Value := text
        try this.status_text.Opt(warning ? "cB00020" : "cGray")
    }

    OnClose(*) {
        this.Dispose()
        return true
    }

    Dispose() {
        local callback_object
        if this.disposed {
            return
        }
        this.disposed := true
        SetTimer(this.initial_load_callback, 0)
        this.ResetProgress()
        if IsObject(this.active_job) {
            try {
                if HasMethod(this.active_job, "Cancel") {
                    this.active_job.Cancel()
                }
            }
        }
        this.active_job := 0
        callback_object := this.callbacks
        this.callbacks := 0
        if IsObject(callback_object) && HasMethod(callback_object, "Dispose") {
            try callback_object.Dispose()
        }
        this.progress_callback := 0
        this.complete_callback := 0
        this.error_callback := 0
        try this.Destroy()
    }
}

RimeDepotGuiToBoolean(value) {
    if IsObject(value) {
        return !!value
    }
    return value = true || value = 1 || StrLower(Trim(String(value))) = "true"
        || StrLower(Trim(String(value))) = "yes"
}

RimeDepotGuiExpandEnvironment(value) {
    local match, name, replacement
    value := String(value)
    while RegExMatch(value, "%([^%]+)%", &match) {
        name := match[1]
        replacement := EnvGet(name)
        if replacement = "" {
            break
        }
        value := StrReplace(value, match[0], replacement)
    }
    return value
}

RimeDepotGuiGetValue(value, keys, fallback := "") {
    local key
    if !IsObject(value) {
        return fallback
    }
    if !(keys is Array) {
        keys := [keys]
    }
    for key in keys {
        if value is Map {
            if value.Has(key) {
                return value[key]
            }
        } else if HasProp(value, key) {
            return value.%key%
        }
    }
    return fallback
}

RimeDepotGuiEntryText(entry, keys, fallback := "") {
    local value := RimeDepotGuiGetValue(entry, keys, ""), raw
    if value = "" {
        raw := RimeDepotGuiGetValue(entry, ["Raw", "raw"], 0)
        value := RimeDepotGuiGetValue(raw, keys, "")
    }
    return RimeDepotGuiFormatValue(value, fallback)
}

RimeDepotGuiEntryRef(entry) {
    local value := RimeDepotGuiEntryText(entry, ["branch", "Branch"], "")
    if value = "" {
        value := RimeDepotGuiEntryText(entry, ["ref", "Ref", "branch_ref", "branchRef"], "")
    }
    if value = "" {
        value := RimeDepotGuiEntryText(entry, ["tag", "Tag"], "")
    }
    if value = "" {
        value := RimeDepotGuiEntryText(entry, ["sha", "Sha", "SHA", "commit", "revision"], "")
    }
    return value
}

RimeDepotGuiFormatValue(value, fallback := "") {
    local parts, item, key
    if !IsObject(value) {
        return value = "" ? fallback : String(value)
    }
    if value is Array {
        parts := []
        for item in value {
            parts.Push(RimeDepotGuiFormatValue(item, ""))
        }
        return parts.Length ? RimeDepotGuiJoin(parts, ", ") : fallback
    }
    if value is Map {
        for key in ["name", "id", "value", "path"] {
            if value.Has(key) {
                return RimeDepotGuiFormatValue(value[key], fallback)
            }
        }
    }
    try {
        return String(value)
    } catch {
        return fallback
    }
}

RimeDepotGuiJoin(values, separator) {
    local result := "", index, value
    for index, value in values {
        if index > 1 {
            result .= separator
        }
        result .= value
    }
    return result
}

RimeDepotGuiProgressPercent(progress) {
    local value
    if IsObject(progress) {
        value := RimeDepotGuiGetValue(progress, ["percent", "percentage"], "")
        if value = "" {
            value := RimeDepotGuiGetValue(progress, ["progress", "fraction"], "")
        }
    } else {
        value := progress
    }
    if value = "" || !IsNumber(value) {
        return -1
    }
    value := Number(value)
    if value >= 0 && value <= 1 {
        value *= 100
    }
    return Max(0, Min(100, value))
}

RimeDepotGuiProgressText(progress, message := "") {
    local text := message, phase, state, url
    if IsObject(progress) {
        text := RimeDepotGuiGetValue(progress, ["message", "status", "text"], text)
        if text = "" {
            phase := RimeDepotGuiGetValue(progress, ["phase", "Phase"], "")
            state := RimeDepotGuiGetValue(progress, ["state", "State"], "")
            url := RimeDepotGuiGetValue(progress, ["url", "Url", "URL"], "")
            text := phase . (phase != "" && state != "" ? ": " : "") . state
            if url != "" {
                text .= " — " . url
            }
        }
    }
    return RimeDepotGuiFormatValue(text, "")
}

RimeDepotGuiExtractCatalog(result, extra) {
    local entries, candidate
    if result is Array {
        return result
    }
    if IsObject(result) && HasMethod(result, "ToArray") {
        try {
            entries := result.ToArray()
            if entries is Array {
                return entries
            }
        }
    }
    candidate := RimeDepotGuiGetValue(result, ["entries", "Entries", "catalog", "Catalog"], 0)
    if candidate is Array {
        return candidate
    }
    for candidate in extra {
        if candidate is Array {
            return candidate
        }
        if IsObject(candidate) && HasMethod(candidate, "ToArray") {
            try {
                entries := candidate.ToArray()
                if entries is Array {
                    return entries
                }
            }
        }
        entries := RimeDepotGuiGetValue(candidate, ["entries", "Entries", "catalog", "Catalog"], 0)
        if entries is Array {
            return entries
        }
    }
    return []
}

RimeDepotGuiCatalogWarning(result, extra) {
    local warning, from_cache, candidate, values
    candidate := result
    warning := RimeDepotGuiGetValue(candidate, ["warning", "Warning", "warnings", "Warnings", "cache_warning"], "")
    if warning != "" {
        return RimeDepotGuiFormatValue(warning, "")
    }
    from_cache := RimeDepotGuiGetValue(
        candidate,
        ["cache_fallback", "cacheFallback", "from_cache", "FromCache", "used_cache", "usedCache"],
        false
    )
    if RimeDepotGuiToBoolean(from_cache) {
        return "using the local cache because the index could not be fetched"
    }
    for _, candidate in extra {
        warning := RimeDepotGuiGetValue(
            candidate,
            ["warning", "Warning", "warnings", "Warnings", "cache_warning"],
            ""
        )
        if warning != "" {
            return RimeDepotGuiFormatValue(warning, "")
        }
        from_cache := RimeDepotGuiGetValue(
            candidate,
            ["cache_fallback", "cacheFallback", "from_cache", "FromCache", "used_cache", "usedCache"],
            false
        )
        if RimeDepotGuiToBoolean(from_cache) {
            return "using the local cache because the index could not be fetched"
        }
        if candidate is Array {
            values := candidate
            for _, item in values {
                warning := RimeDepotGuiGetValue(
                    item,
                    ["warning", "Warning", "message", "Message"],
                    ""
                )
                if warning != "" {
                    return RimeDepotGuiFormatValue(warning, "")
                }
            }
        }
    }
    return ""
}

RimeDepotGuiLooksLikeJob(value) {
    if !IsObject(value) {
        return false
    }
    if value is RimeDepotJob {
        return true
    }
    return HasMethod(value, "IsDone") && HasMethod(value, "Cancel")
}

RimeDepotGuiErrorText(error_value) {
    local message
    if !IsObject(error_value) {
        return error_value = "" ? "" : String(error_value)
    }
    message := RimeDepotGuiGetValue(error_value, ["message", "Message", "error"], "")
    return message != "" ? String(message) : Type(error_value)
}
