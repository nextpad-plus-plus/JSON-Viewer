# JSON Viewer — macOS port

Tree-view navigator, formatter, compressor, and validator for JSON documents inside Notepad++ macOS. Port of the Windows [NPP-JSONViewer/JSON-Viewer](https://github.com/NPP-JSONViewer/JSON-Viewer) plugin (GPLv2).

## Features

- **JSON tree panel** that docks into the side-panel host (with pop-out to a floating utility window).
- **Live preview** — click any tree node to jump the editor caret to its line/column; re-parses on buffer edits (debounced).
- **Format / Compress / Sort by key** operations, configurable indent (tab / N spaces / auto), EOL (CRLF / LF / CR / auto), and line-format (default / single-line arrays).
- **Validate** — friendly parse-error alert with the offending position highlighted in the editor.
- **Right-click context menu**: Copy / Copy name / Copy value / Copy path / Expand all / Collapse all — same enable/disable semantics as the Windows plugin.
- **Live search** in the tree (keyboard-driven filter with auto-expand).
- **Settings dialog** with all the toggles from the Windows version: follow current tab, auto-format on open, ignore comments / trailing commas / undefined values, JSON syntax highlighting, indent + EOL + line-format controls.
- **Cmd+/−/0 zoom** via the host's panel-zoom plumbing.

## Shortcuts (macOS)

| Action | Shortcut |
|---|---|
| Toggle JSON Viewer panel | ⌘⌥⇧J |
| Format JSON | ⌘⌥⇧M |
| Compress JSON | ⌘⌥⇧C |
| Sort by key (ascending) | ⌘⌥⇧K |

## Requirements

- Notepad++ macOS v1.0.2 or later (for `NPPM_DMM_*` docking). Older hosts fall back to a floating NSPanel automatically.
- macOS 11.0 or later. Universal binary (arm64 + x86_64).

## Build

```bash
cd JSON-Viewer
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu)
```

The dylib installs to `~/.notepad++/plugins/NppJsonViewer/` via `make install`.

## Parser

Uses RapidJSON SAX (bundled in `external/rapidjson_include/` from the [NPP-JSONViewer fork](https://github.com/NPP-JSONViewer/rapidjson) — the same fork used by the Windows plugin, with the `RawNumber` write fix). `TrackingStream` wraps `rapidjson::StringStream` to count line/column for every token, so each tree node carries a precise Scintilla position for click-to-jump.

**Speed:** NSOutlineView is data-source-based and lazy — only visible rows are queried — so initial render scales with viewport size rather than node count. A 10 MB JSON document parses + displays in sub-300 ms on M-series Macs.

## License

GPLv2 (inherits from the original Windows plugin).
