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

#Include ..\support\TestCommon.ahk
#Include ..\..\RimeDepotGui.ahk

try {
    RimeDepotGuiSmokeMain()
} catch as err {
    RimeDepotGuiSmokeReportError(err)
    ExitApp(1)
}

RimeDepotGuiSmokeMain() {
    RunTest("RimeDepot GUI constructs with injected service", RimeDepotGuiSmokeConstruction.Bind())
    RunTest("RimeDepot GUI loads a fake catalog asynchronously", RimeDepotGuiSmokeCatalog.Bind())
    RunTest("RimeDepot GUI handles synchronous catalog completion and error", RimeDepotGuiSmokeCatalogSynchronous.Bind())
    RunTest("RimeDepot GUI keeps details for the current selection", RimeDepotGuiSmokeSelection.Bind())
    RunTest("RimeDepot GUI switches RPPI and direct modes", RimeDepotGuiSmokeModes.Bind())
    RunTest("RimeDepot GUI builds hierarchical category filters", RimeDepotGuiSmokeCategories.Bind())
    RunTest("RimeDepot GUI keeps category branches contiguous", RimeDepotGuiSmokeCategoryOrder.Bind())
    RunTest("RimeDepot GUI disambiguates duplicate category leaves", RimeDepotGuiSmokeCategoryNames.Bind())
    RunTest("RimeDepot GUI applies mode geometry and DDL row options", RimeDepotGuiSmokeGeometry.Bind())
    RunTest("RimeDepot GUI preserves filter state while busy", RimeDepotGuiSmokeBusy.Bind())
    RunTest("RimeDepot GUI uses native determinate and marquee progress", RimeDepotGuiSmokeProgress.Bind())
    ExitApp(0)
}

RimeDepotGuiSmokeConstruction() {
    local settings := RimeDepotGuiSettings(Map(
        "CachePath", "C:\\Temp\\RimeDepot-cache",
        "RimeDirectory", "C:\\Temp\\Rime",
        "RppiIndexUrl", "https://example.invalid/index.yaml",
        "Proxy", "",
        "UseGit", false,
        "GitPath", ""
    ))
    local gui := RimeDepotGui(RimeDepotGuiFakeService(), settings, A_Temp . "\\RimeDepot-GuiSmoke.ini")
    try {
        AssertTrue(IsObject(gui.catalog_list), "The catalog ListView was not created.")
        AssertTrue(IsObject(gui.cache_path_edit), "The cache-path editor was not created.")
        AssertTrue(!gui.use_git_checkbox.Value, "Git must be disabled by default in this fixture.")
        AssertTrue(!gui.git_path_edit.Enabled, "Git path must be disabled when Git is disabled.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeCatalog() {
    local service := RimeDepotGuiFakeService()
    local gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke.ini")
    local start_time := A_TickCount
    try {
        AssertTrue(gui.StartCatalogLoad(false), "The fake catalog job did not start.")
        while gui.busy && A_TickCount - start_time < 2000 {
            Sleep(20)
        }
        AssertTrue(!gui.busy, "The fake catalog job did not complete.")
        AssertEqual(1, gui.catalog_entries.Length, "The GUI did not receive the fake catalog entry.")
        AssertEqual("Fake scheme", gui.catalog_list.GetText(1, 2), "The catalog row has the wrong scheme name.")
        gui.catalog_list.Modify(1, "Select")
        ; A hidden ListView does not dispatch ItemSelect consistently on all
        ; Windows versions; invoke the same handler explicitly for a
        ; deterministic smoke check without showing a GUI.
        gui.OnCatalogSelection(gui.catalog_list, 1, true)
        Sleep(20)
        AssertTrue(
            InStr(gui.detail_dependencies.Value, "base") > 0,
            "The dependency detail was not populated."
        )
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeCatalogSynchronous() {
    local service, gui
    service := RimeDepotGuiFakeService(true)
    gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke-sync.ini")
    try {
        ; The callback runs before LoadCatalog() returns.  StartCatalogLoad()
        ; must re-check the returned job and clear active_job after assignment.
        AssertTrue(gui.StartCatalogLoad(false), "The synchronous catalog job did not start.")
        AssertTrue(!gui.busy && !IsObject(gui.active_job),
            "Synchronous catalog completion left the GUI busy or active_job set.")
        AssertEqual(1, gui.catalog_entries.Length,
            "Synchronous catalog completion did not update the catalog.")
    } finally {
        gui.Dispose()
    }

    service := RimeDepotGuiFakeService(true, true)
    gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke-sync-error.ini")
    try {
        AssertTrue(gui.StartCatalogLoad(false), "The synchronous error job did not start.")
        AssertTrue(!gui.busy && !IsObject(gui.active_job),
            "Synchronous catalog error left the GUI busy or active_job set.")
        AssertTrue(InStr(gui.status_text.Value, "Operation failed") > 0,
            "Synchronous catalog error was not shown in the status control.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeSelection() {
    local service := RimeDepotGuiFakeService()
    local gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke.ini")
    local first := {
        category_path: "demo",
        name: "First scheme",
        repo: "owner/first",
        schemas: ["first.schema"],
        dependencies: ["first-base"],
        reverseDependencies: ["first-child"],
        labels: ["first-label"],
        license: "MIT"
    }
    local second := {
        category_path: "demo",
        name: "Second scheme",
        repo: "owner/second",
        schemas: ["second.schema"],
        dependencies: ["second-base"],
        reverseDependencies: ["second-child"],
        labels: ["second-label"],
        license: "Apache-2.0"
    }
    try {
        gui.catalog_entries := [first, second]
        gui.UpdateCategoryFilter()
        gui.RefreshCatalogView()
        gui.catalog_list.Modify(1, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 1, true)
        AssertTrue(InStr(gui.detail_title.Value, "First scheme") > 0,
            "The first selected scheme was not shown in the details.")

        gui.catalog_list.Modify(2, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 2, true)
        ; A delayed deselect notification for row 1 must synchronize from the
        ; ListView's current selection instead of clearing row 2's details.
        gui.OnCatalogSelection(gui.catalog_list, 1, false)
        AssertTrue(InStr(gui.detail_title.Value, "Second scheme") > 0
            && InStr(gui.detail_schemas.Value, "second.schema") > 0
            && InStr(gui.detail_dependencies.Value, "second-base") > 0
            && InStr(gui.detail_reverse_dependencies.Value, "second-child") > 0
            && InStr(gui.detail_labels.Value, "second-label") > 0,
            "A stale deselect notification cleared the current scheme details.")

        gui.catalog_list.Modify(2, "-Select")
        gui.OnCatalogSelection(gui.catalog_list, 2, false)
        AssertTrue(InStr(gui.detail_title.Value, "Select a catalog entry") > 0
            && gui.detail_schemas.Value = "Schemas: "
            && gui.detail_dependencies.Value = "Dependencies: ",
            "Details were not cleared after the ListView lost its selection.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeModes() {
    local service := RimeDepotGuiFakeService(), settings := RimeDepotGuiSettings(Map("UseGit", true))
    local gui := RimeDepotGui(service, settings, A_Temp . "\\RimeDepot-GuiSmoke.ini")
    local start_time, call, request
    try {
        AssertEqual("rppi", gui.mode, "The GUI did not start in RPPI mode.")
        gui.mode_selector.Choose(2)
        gui.OnModeChanged(gui.mode_selector, 2)
        AssertEqual("direct", gui.mode, "The GUI did not enter direct mode.")
        AssertTrue(gui.direct_source_edit.Visible && !gui.catalog_list.Visible,
            "Direct mode did not switch the visible control group.")

        gui.direct_source_edit.Value := "https://github.com/owner/direct-repository"
        gui.direct_ref_edit.Value := "feature/direct"
        gui.use_git_checkbox.Value := 1
        AssertTrue(gui.InstallSelected(), "The direct install action did not start.")
        start_time := A_TickCount
        while gui.busy && A_TickCount - start_time < 2000 {
            Sleep(20)
        }
        AssertTrue(!gui.busy && service.calls.Length >= 1, "The direct install did not complete.")
        call := service.calls[service.calls.Length]
        AssertEqual("direct", call.kind, "Direct mode called the wrong service operation.")
        request := call.request
        AssertTrue(request is Map && request["locator"] = "https://github.com/owner/direct-repository"
            && request["ref"] = "feature/direct" && request["transport"] = "git",
            "Direct mode did not pass the direct-install request fields.")

        gui.SetMode("rppi")
        AssertEqual("rppi", gui.mode, "The GUI did not return to RPPI mode.")
        AssertTrue(gui.catalog_list.Visible && !gui.direct_source_edit.Visible,
            "RPPI mode did not restore the catalog controls.")

        gui.catalog_entries := [{category_path: "demo", name: "Catalog scheme", repo: "owner/catalog"}]
        gui.UpdateCategoryFilter()
        gui.RefreshCatalogView()
        gui.catalog_list.Modify(1, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 1, true)
        gui.use_git_checkbox.Value := 1
        AssertTrue(gui.InstallSelected(), "The RPPI install action did not start.")
        start_time := A_TickCount
        while gui.busy && A_TickCount - start_time < 2000 {
            Sleep(20)
        }
        AssertTrue(!gui.busy && service.calls.Length >= 2, "The RPPI install did not complete.")
        call := service.calls[service.calls.Length]
        AssertEqual("entry", call.kind, "RPPI mode called direct target installation.")
        AssertTrue(InStr(gui.detail_title.Value, "Catalog scheme") > 0,
            "RPPI completion replaced the selected catalog details.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeCategories() {
    local gui := RimeDepotGui(RimeDepotGuiFakeService(), RimeDepotGuiSettings(),
        A_Temp . "\\RimeDepot-GuiSmoke-categories.ini")
    local entries := [
        {category_path: "汉语 / 普通话", name: "Mandarin", repo: "owner/mandarin", schemas: ["mandarin.schema"],
            dependencies: ["base"], reverseDependencies: [], labels: ["spoken"], license: "MIT"},
        {category_path: "汉语 / 方言", name: "Dialect", repo: "owner/dialect", schemas: ["dialect.schema"],
            dependencies: ["base"], reverseDependencies: [], labels: ["regional"], license: "MIT"},
        {category_path: "英语", name: "English", repo: "owner/english", schemas: ["english.schema"],
            dependencies: [], reverseDependencies: [], labels: ["latin"], license: "MIT"},
        {category_path: "汉语拼音", name: "Pinyin", repo: "owner/pinyin", schemas: ["pinyin.schema"],
            dependencies: [], reverseDependencies: [], labels: ["latin"], license: "MIT"}
    ]
    local expected_paths := ["", "汉语", "汉语 / 普通话", "汉语 / 方言", "英语", "汉语拼音"]
    local index, path, text, names
    try {
        gui.catalog_entries := entries
        gui.UpdateCategoryFilter()
        AssertEqual(expected_paths.Length, gui.category_paths.Length,
            "The category filter did not include every canonical path.")
        for index, path in expected_paths {
            AssertEqual(path, gui.category_paths[index], "The category path order or canonical value is wrong.")
        }

        gui.category_filter.Choose(3)
        text := gui.category_filter.Text
        AssertTrue(InStr(text, "普通话") > 0 && SubStr(text, 1, 4) = "    ",
            "Leaf category labels must show an indented node name.")

        gui.category_filter.Choose(2)
        gui.RefreshCatalogView()
        AssertEqual(2, gui.catalog_list.GetCount(), "Selecting a parent category must include only its subtree.")
        names := gui.catalog_list.GetText(1, 2) . "|" . gui.catalog_list.GetText(2, 2)
        AssertTrue(InStr(names, "Mandarin") > 0 && InStr(names, "Dialect") > 0
            && InStr(names, "English") = 0 && InStr(names, "Pinyin") = 0,
            "A parent category matched a sibling or prefix-only category.")

        gui.category_filter.Choose(3)
        gui.RefreshCatalogView()
        AssertEqual(1, gui.catalog_list.GetCount(), "Selecting a leaf category must include only that leaf.")
        AssertEqual("Mandarin", gui.catalog_list.GetText(1, 2), "The wrong leaf category row was shown.")

        gui.category_filter.Choose(1)
        gui.search_edit.Value := "汉语 / 方言"
        gui.RefreshCatalogView()
        AssertEqual(1, gui.catalog_list.GetCount(), "Search must match a full category path.")
        AssertEqual("Dialect", gui.catalog_list.GetText(1, 2), "Full-path search selected the wrong row.")

        gui.search_edit.Value := "no such scheme"
        gui.RefreshCatalogView()
        AssertEqual(0, gui.catalog_list.GetCount(), "A search miss must not leave stale rows visible.")
        AssertTrue(!gui.install_button.Enabled && InStr(gui.detail_title.Value, "Select a catalog entry") > 0,
            "A search miss must clear details and disable Install.")

        gui.search_edit.Value := ""
        gui.RefreshCatalogView()
        gui.catalog_list.Modify(2, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 2, true)
        AssertTrue(InStr(gui.detail_title.Value, "Dialect") > 0
            && InStr(gui.detail_dependencies.Value, "base") > 0
            && InStr(gui.detail_labels.Value, "regional") > 0,
            "Current selection details were not preserved after category filtering.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeCategoryOrder() {
    local gui := RimeDepotGui(0, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke-category-order.ini")
    local entries := [
        {category_path: "alpha / one", name: "Alpha one", repo: "owner/alpha-one"},
        {category_path: "beta", name: "Beta", repo: "owner/beta"},
        {category_path: "alpha / two / deep", name: "Alpha two deep", repo: "owner/alpha-two-deep"},
        {category_path: "alpha / two", name: "Alpha two", repo: "owner/alpha-two"},
        {category_path: "gamma", name: "Gamma", repo: "owner/gamma"},
        {category_path: "alpha / one / deep", name: "Alpha one deep", repo: "owner/alpha-one-deep"}
    ]
    local expected_paths := [
        "", "alpha", "alpha / one", "alpha / one / deep", "alpha / two", "alpha / two / deep", "beta", "gamma"
    ]
    local index, path, alpha_index, one_index, deep_index, selected_value, names
    try {
        gui.catalog_entries := entries
        gui.UpdateCategoryFilter()
        AssertEqual(expected_paths.Length, gui.category_paths.Length,
            "The category tree omitted or invented a canonical path.")
        for index, path in expected_paths {
            AssertEqual(path, gui.category_paths[index],
                "Category paths must be emitted in preorder with first-seen sibling order.")
        }

        alpha_index := RimeDepotGuiSmokeFindCategoryIndex(gui, "alpha")
        one_index := RimeDepotGuiSmokeFindCategoryIndex(gui, "alpha / one")
        deep_index := RimeDepotGuiSmokeFindCategoryIndex(gui, "alpha / two / deep")
        gui.category_filter.Choose(alpha_index)
        gui.RefreshCatalogView()
        AssertEqual(4, gui.catalog_list.GetCount(), "Selecting a parent must include every descendant entry.")
        names := gui.catalog_list.GetText(1, 2) . "|" . gui.catalog_list.GetText(2, 2)
            . "|" . gui.catalog_list.GetText(3, 2) . "|" . gui.catalog_list.GetText(4, 2)
        AssertTrue(InStr(names, "Alpha one") > 0 && InStr(names, "Alpha two deep") > 0
            && InStr(names, "Alpha two") > 0 && InStr(names, "Alpha one deep") > 0
            && InStr(names, "Beta") = 0 && InStr(names, "Gamma") = 0,
            "Parent filtering did not follow the canonical subtree boundary.")

        gui.category_filter.Choose(one_index)
        gui.RefreshCatalogView()
        AssertEqual(2, gui.catalog_list.GetCount(), "Selecting a branch must include only its own descendants.")
        AssertTrue(InStr(gui.catalog_list.GetText(1, 2), "Alpha one") > 0
            && InStr(gui.catalog_list.GetText(2, 2), "Alpha one deep") > 0,
            "The branch filter included a sibling branch.")

        gui.category_filter.Choose(deep_index)
        selected_value := gui.category_filter.Value
        gui.UpdateCategoryFilter()
        AssertEqual(selected_value, gui.category_filter.Value,
            "Rebuilding the preorder category list changed the selected value.")
        AssertEqual("alpha / two / deep", gui.SelectedCategoryPath(),
            "Rebuilding the category list did not preserve the canonical selection.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeCategoryNames() {
    local gui := RimeDepotGui(RimeDepotGuiFakeService(), RimeDepotGuiSettings(),
        A_Temp . "\\RimeDepot-GuiSmoke-category-names.ini")
    local entries := [
        {category_path: "汉语 / 普通话", name: "Mandarin", repo: "owner/mandarin", schemas: ["mandarin.schema"]},
        {category_path: "英语 / 普通话", name: "English pronunciation", repo: "owner/english-pronunciation",
            schemas: ["english-pronunciation.schema"]},
        {category_path: "All categories", name: "Literal category", repo: "owner/literal-category",
            schemas: ["literal.schema"]}
    ]
    local han_index, english_index, literal_index, selected_index, text
    try {
        gui.catalog_entries := entries
        gui.UpdateCategoryFilter()
        han_index := RimeDepotGuiSmokeFindCategoryIndex(gui, "汉语 / 普通话")
        english_index := RimeDepotGuiSmokeFindCategoryIndex(gui, "英语 / 普通话")
        literal_index := RimeDepotGuiSmokeFindCategoryIndex(gui, "All categories")
        AssertTrue(han_index > 0 && english_index > 0 && literal_index > 0
            && han_index != english_index && english_index != literal_index,
            "Distinct canonical category paths were not retained.")

        gui.category_filter.Choose(han_index)
        text := gui.category_filter.Text
        AssertTrue(InStr(text, "普通话 (汉语)") > 0,
            "The first duplicate leaf did not include its parent path.")
        gui.RefreshCatalogView()
        AssertEqual(1, gui.catalog_list.GetCount(), "The first duplicate leaf selected the wrong subtree.")
        AssertEqual("Mandarin", gui.catalog_list.GetText(1, 2), "The first duplicate leaf selected the wrong entry.")

        gui.category_filter.Choose(english_index)
        text := gui.category_filter.Text
        AssertTrue(InStr(text, "普通话 (英语)") > 0,
            "The second duplicate leaf did not include its parent path.")
        gui.RefreshCatalogView()
        AssertEqual(1, gui.catalog_list.GetCount(), "The second duplicate leaf selected the wrong subtree.")
        AssertEqual("English pronunciation", gui.catalog_list.GetText(1, 2),
            "The second duplicate leaf selected the wrong entry.")

        gui.category_filter.Choose(literal_index)
        text := gui.category_filter.Text
        AssertTrue(InStr(text, "All categories (category)") > 0,
            "A literal All categories node was confused with the sentinel.")
        gui.RefreshCatalogView()
        AssertEqual(1, gui.catalog_list.GetCount(), "The literal All categories node selected the wrong entry.")
        AssertEqual("Literal category", gui.catalog_list.GetText(1, 2),
            "The literal All categories node selected the wrong entry.")

        gui.category_filter.Choose(english_index)
        selected_index := gui.category_filter.Value
        gui.UpdateCategoryFilter()
        AssertEqual(english_index, gui.category_filter.Value,
            "Rebuilding categories changed the selected index unexpectedly.")
        AssertEqual("英语 / 普通话", gui.SelectedCategoryPath(),
            "Rebuilding categories did not preserve the selected canonical path.")
        AssertEqual(selected_index, gui.category_filter.Value,
            "Rebuilding categories did not preserve the selected value.")
        gui.RefreshCatalogView()
        gui.catalog_list.Modify(1, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 1, true)
        AssertTrue(InStr(gui.detail_summary.Value, "Category: 英语 / 普通话") > 0,
            "Details did not use the canonical category path.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeFindCategoryIndex(gui, target) {
    local index, path
    for index, path in gui.category_paths {
        if path = target {
            return index
        }
    }
    return 0
}

RimeDepotGuiSmokeGeometry() {
    ; No service is needed for geometry.  This also prevents Show("Hide")'s
    ; deferred initial catalog load from racing the mode-resize assertions.
    local gui := RimeDepotGui(0, RimeDepotGuiSettings(),
        A_Temp . "\\RimeDepot-GuiSmoke-geometry.ini")
    local source, x, y, width, height, direct_height, rppi_height, width_before, width_after
    local mode_popup_height, category_popup_height
    local mode_closed_height, category_closed_height
    try {
        source := FileRead(A_ScriptDir . "\\..\\..\\RimeDepotGui.ahk", "UTF-8")
        AssertTrue(InStr(source, 'AddDropDownList("x110 y146 w210 R2 Choose1"') > 0,
            "Mode DropDownList must use R2 rows.")
        AssertTrue(InStr(source, 'AddDropDownList("x448 y194 w210 R10 Choose1"') > 0,
            "Category DropDownList must use R10 rows.")
        AssertTrue(!gui._shown, "Constructing the GUI must not show a window.")
        gui.direct_group.GetPos(&x, &y, &width, &height)
        AssertEqual(184, y, "Direct group moved away from its reserved top position.")
        AssertTrue(height >= 130, "Direct group is too short for its fields.")
        gui.direct_source_edit.GetPos(&x, &y, &width, &height)
        AssertEqual(210, y, "Direct source field overlaps the group title.")
        gui.direct_ref_edit.GetPos(&x, &y, &width, &height)
        AssertEqual(250, y, "Direct ref field is not below the group title.")
        gui.SetMode("direct")
        AssertTrue(!gui._shown, "Changing mode before Show must not show the window.")
        gui.SetMode("rppi")
        gui.initial_load_started := true
        gui.Show("Hide")
        gui.Show("Hide w900")
        gui.GetClientPos(&x, &y, &width_before, &height)
        AssertEqual(900, width_before, "An explicit width option was not applied on the first/second Show.")

        gui.mode_selector.GetPos(&x, &y, &width, &mode_closed_height)
        gui.category_filter.GetPos(&x, &y, &width, &category_closed_height)
        mode_popup_height := RimeDepotGuiSmokeDropdownHeight(gui.mode_selector)
        category_popup_height := RimeDepotGuiSmokeDropdownHeight(gui.category_filter)
        AssertTrue(mode_popup_height > mode_closed_height && category_popup_height > category_closed_height
            && category_popup_height > mode_popup_height,
            "Mode/category popup heights did not reflect their R2/R10 row options.")

        gui.SetMode("direct")
        gui.GetClientPos(&x, &y, &width, &direct_height)
        AssertTrue(gui._hidden && direct_height <= 450,
            "Direct mode did not use its compact hidden window height.")
        gui.GetClientPos(&x, &y, &width_after, &height)
        AssertEqual(width_before, width_after, "Mode switching reset the current window width.")
        gui.SetMode("rppi")
        gui.GetClientPos(&x, &y, &width, &rppi_height)
        AssertTrue(rppi_height > direct_height && rppi_height >= 700,
            "RPPI mode did not restore the tall catalog window height.")
        gui.install_button.GetPos(&x, &y, &width, &height)
        AssertEqual(194, y, "RPPI Install button did not return to the catalog row.")
        gui.SetMode("direct")
        gui.install_button.GetPos(&x, &y, &width, &height)
        AssertEqual(210, y, "Direct Install button did not move beside Source.")
        gui.status_text.GetPos(&x, &y, &width, &height)
        AssertEqual(374, y, "Direct status text is not directly below the source group.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeDropdownHeight(control) {
    local rect := Buffer(16, 0), result, top, bottom
    result := DllCall("SendMessageW", "Ptr", control.Hwnd, "UInt", 0x0152,
        "Ptr", 0, "Ptr", rect.Ptr, "Ptr")
    AssertTrue(result != 0, "CB_GETDROPPEDCONTROLRECT failed for a hidden DropDownList.")
    top := NumGet(rect, 4, "Int")
    bottom := NumGet(rect, 12, "Int")
    AssertTrue(bottom > top, "CB_GETDROPPEDCONTROLRECT returned an empty rectangle.")
    return bottom - top
}

RimeDepotGuiSmokeBusy() {
    local service := RimeDepotGuiFakeService()
    local gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke-busy.ini")
    local entry := {category_path: "demo", name: "Busy fixture", repo: "owner/busy", schemas: ["busy.schema"],
        dependencies: ["base"], reverseDependencies: [], labels: ["busy"], license: "MIT"}
    local old_title, old_count, token
    try {
        gui.catalog_entries := [entry]
        gui.UpdateCategoryFilter()
        gui.RefreshCatalogView()
        gui.catalog_list.Modify(1, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 1, true)
        old_title := gui.detail_title.Value
        old_count := gui.catalog_list.GetCount()

        AssertTrue(gui.StartCatalogLoad(false), "The busy fixture operation did not start.")
        token := gui.operation_token
        AssertTrue(gui.busy, "The GUI did not enter busy state.")
        AssertTrue(!gui.mode_selector.Enabled && !gui.search_edit.Enabled && !gui.category_filter.Enabled
            && !gui.catalog_list.Enabled && !gui.refresh_button.Enabled,
            "RPPI controls were not disabled while the operation was busy.")
        AssertTrue(!gui.direct_source_edit.Enabled && !gui.direct_ref_edit.Enabled,
            "Direct controls were not disabled while the operation was busy.")
        AssertTrue(gui.cancel_button.Enabled, "Cancel must remain enabled while busy.")
        AssertTrue(gui.detail_title.Enabled, "Details text should remain readable while busy.")

        gui.search_edit.Value := "must not refresh"
        gui.OnFilterChanged()
        AssertEqual(old_count, gui.catalog_list.GetCount(), "Busy filter input changed the visible rows.")
        AssertEqual(old_title, gui.detail_title.Value, "Busy filter input cleared the current details.")
        gui.SetMode("direct")
        AssertEqual("rppi", gui.mode, "Busy mode switching must be ignored.")

        gui.OnOperationError(token - 1, Error("stale operation"))
        AssertTrue(gui.busy, "A stale callback changed the current busy operation.")
        AssertTrue(gui.CancelActiveJob(), "Cancel did not delegate to the active fake job.")
        AssertTrue(!gui.busy && !gui.cancel_button.Enabled && gui.mode_selector.Enabled
            && gui.search_edit.Enabled && gui.category_filter.Enabled && gui.catalog_list.Enabled
            && gui.refresh_button.Enabled && gui.direct_source_edit.Enabled
            && InStr(gui.status_text.Value, "Operation failed") > 0
            && InStr(gui.status_text.Value, "Cancellation requested") = 0,
            "Controls were not restored after the busy operation finished.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeProgress() {
    local service := RimeDepotGuiFakeService()
    local gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke-progress.ini")
    local job, token, entry := {category_path: "demo", name: "Progress fixture", repo: "owner/progress"}
    try {
        ; RPPI and Direct share the same progress state machine.  Keep the
        ; fake job from its delayed delivery while driving each callback here.
        AssertTrue(gui.StartCatalogLoad(false), "The RPPI progress operation did not start.")
        job := gui.active_job
        token := gui.operation_token
        job.delivered := true
        AssertTrue(gui.busy && RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar),
            "Operation start did not enable native marquee progress.")

        gui.OnProgress(token, job, {phase: "fetching", state: "index"})
        AssertTrue(RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar),
            "An unknown stage payload did not keep native marquee progress active.")
        gui.OnProgress(token, job, {percent: 25})
        AssertTrue(!RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar)
            && gui.progress_bar.Value = 25,
            "A percent payload did not switch to determinate progress at 25.")
        gui.OnProgress(token - 1, job, {percent: 75})
        AssertTrue(!RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar)
            && gui.progress_bar.Value = 25,
            "A stale progress callback changed the current progress state.")
        gui.OnProgress(token, job, {phase: "loading", state: "recipes"})
        AssertTrue(RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar)
            && gui.progress_bar.Value = 0,
            "An unknown next stage did not reset to native marquee progress.")
        gui.OnCatalogComplete(token, job, [entry])
        AssertTrue(!gui.busy && !RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar)
            && gui.progress_bar.Value = 100,
            "Successful RPPI completion did not stop marquee at 100.")

        gui.SetMode("direct")
        gui.direct_source_edit.Value := "owner/direct-progress"
        AssertTrue(gui.InstallDirect(), "The Direct progress operation did not start.")
        job := gui.active_job
        token := gui.operation_token
        AssertTrue(gui.busy && RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar),
            "Direct operation start did not enable native marquee progress.")
        gui.OnProgress(token, job, {fraction: 0.25})
        AssertTrue(!RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar)
            && gui.progress_bar.Value = 25,
            "A fraction payload did not switch Direct progress to determinate 25.")

        job.delivered := true
        gui.OnInstallComplete(token, job, Map("entries", []))
        AssertTrue(!gui.busy && !RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar)
            && gui.progress_bar.Value = 100,
            "Successful Direct completion did not stop marquee at 100.")

        AssertTrue(gui.InstallDirect(), "The Direct cancellation operation did not start.")
        job := gui.active_job
        token := gui.operation_token
        AssertTrue(gui.busy && RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar),
            "The second Direct operation did not re-enter native marquee progress.")
        gui.OnProgress(token, job, {fraction: 0.25})
        AssertTrue(gui.CancelActiveJob(), "The Direct progress cancellation did not start.")
        AssertTrue(!gui.busy && !RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar)
            && gui.progress_bar.Value = 0 && InStr(gui.status_text.Value, "Operation failed") > 0,
            "Cancellation did not stop marquee and reset progress to zero.")

        service.fail_install := true
        AssertTrue(!gui.InstallDirect(), "The simulated Direct start failure unexpectedly succeeded.")
        AssertTrue(!gui.busy && !RimeDepotGuiSmokeProgressHasMarquee(gui.progress_bar)
            && gui.progress_bar.Value = 0,
            "A Direct start failure did not stop marquee and reset progress.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeProgressHasMarquee(control) {
    local style
    if A_PtrSize = 8 {
        style := DllCall("GetWindowLongPtrW", "Ptr", control.Hwnd, "Int", -16, "Ptr")
    } else {
        style := DllCall("GetWindowLongW", "Ptr", control.Hwnd, "Int", -16, "Int")
    }
    return !!(style & 0x08)
}

class RimeDepotGuiFakeService {
    __New(synchronous_catalog := false, catalog_error := false) {
        this.config := 0
        this.jobs := []
        this.calls := []
        this.synchronous_catalog := synchronous_catalog
        this.catalog_error := catalog_error
        this.fail_install := false
    }

    Configure(values) {
        this.config := values
    }

    LoadCatalog(options := 0, callbacks := 0) {
        if !callbacks {
            callbacks := options
        }
        local job := RimeDepotGuiFakeJob(callbacks, "catalog")
        job.catalog_error := this.catalog_error
        this.jobs.Push(job)
        if this.synchronous_catalog {
            job.Deliver()
        } else {
            SetTimer(job.Deliver.Bind(job), -30)
        }
        return job
    }

    RefreshCatalog(options := 0, callbacks := 0) {
        return this.LoadCatalog(options, callbacks)
    }

    InstallEntry(entry, callbacks := 0) {
        this.calls.Push({kind: "entry", entry: entry})
        return this._Install(callbacks, "entry", entry, Map())
    }

    InstallDirect(request, callbacks := 0) {
        if this.fail_install {
            throw Error("simulated install start failure")
        }
        this.calls.Push({kind: "direct", request: RimeDepotGuiFakeCopy(request)})
        return this._Install(callbacks, "direct", request, Map())
    }

    _Install(callbacks, kind, target, options) {
        local job := RimeDepotGuiFakeJob(callbacks, kind, target)
        this.jobs.Push(job)
        SetTimer(job.Deliver.Bind(job), -30)
        return job
    }
}

class RimeDepotGuiFakeJob {
    __New(callbacks, kind := "catalog", target := 0) {
        this.callbacks := callbacks
        this.kind := kind
        this.target := target
        this.cancelled := false
        this.delivered := false
        this.catalog_error := false
        this.delivery_callback := this.Deliver.Bind(this)
    }

    IsDone() {
        return this.cancelled || this.delivered
    }

    Deliver(*) {
        local entry
        if this.cancelled || this.delivered {
            return
        }
        this.delivered := true
        if this.catalog_error {
            this.callbacks.ReportError(this, Error("synchronous catalog fixture failure"))
            return
        }
        entry := {
            category_path: "demo",
            name: "Fake scheme",
            repo: "https://example.invalid/rime/fake",
            branch: "main",
            schemas: ["fake.schema"],
            dependencies: ["base"],
            reverseDependencies: ["fake-child"],
            labels: ["smoke-test"],
            license: "MIT"
        }
        this.callbacks.ReportProgress(this, {percent: 50, message: "fake progress"})
        if this.kind = "catalog" {
            this.callbacks.ReportComplete(this, [entry])
        } else {
            this.callbacks.ReportComplete(this, Map("entries", [entry], "target", this.target))
        }
    }

    Cancel() {
        if this.cancelled || this.delivered {
            return
        }
        this.cancelled := true
        this.delivered := true
        this.callbacks.ReportError(this, Error("fake cancellation"))
    }
}

RimeDepotGuiFakeCopy(value) {
    local result := Map(), key, item
    if !IsObject(value) {
        return result
    }
    for key, item in value {
        result[key] := item
    }
    return result
}

RimeDepotGuiSmokeReportError(err) {
    local message := "Uncaught exception: "
    if IsObject(err) && HasProp(err, "Message") {
        message .= err.Message . "`n"
        if HasProp(err, "What") && err.What {
            message .= "  at " . err.What . "`n"
        }
        if HasProp(err, "File") && err.File {
            message .= "  Location: " . err.File
            if HasProp(err, "Line") && err.Line {
                message .= ":" . err.Line
            }
            message .= "`n"
        }
        if HasProp(err, "Stack") && err.Stack {
            message .= "Stack:`n" . err.Stack . "`n"
        }
    } else {
        message .= String(err) . "`n"
    }
    FileAppend(message, "*")
}
