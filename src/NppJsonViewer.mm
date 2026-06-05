// NppJsonViewer — macOS port of NPP-JSONViewer/JSON-Viewer.
//
// Thin bootstrap: implements the Notepad++ plugin entry points, wires
// six menu items (Toggle / Format / Compress / Sort / Settings / About)
// with ⌘⌥⇧ shortcuts matching the Windows Ctrl+Alt+Shift shortcuts,
// registers the content view via NPPM_DMM_REGISTERPANEL (with NSPanel
// floating fallback for pre-v1.0.2 hosts), and forwards the three
// toolbar-row actions (Refresh / Validate / Format) back from JsonPanel
// delegate callbacks into the parser + editor.

#import <Cocoa/Cocoa.h>

#include <dlfcn.h>
#include <memory>
#include <string>

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"

#import "JsonPanel.h"
#import "JsonParser.h"
#import "JsonFormatter.h"
#import "JsonSettings.h"
#import "JsonSettingsDialog.h"
#import "JsonViewerBridge.h"   // inter-plugin handshake (JSTool "JSON Viewer" item)

// ─────────────────────────────────────────────────────────────────────────
//  Plugin identification
// ─────────────────────────────────────────────────────────────────────────
static const char *PLUGIN_NAME = "JSON Viewer";

enum CmdIdx {
    kCmdShowPanel   = 0,
    kCmdFormat      = 1,
    kCmdCompress    = 2,
    kCmdSort        = 3,
    kCmdSep         = 4,   // separator slot
    kCmdSettings    = 5,
    kCmdAbout       = 6,
    kCmdCount       = 7
};

static FuncItem sFuncItem[kCmdCount];
static NppData  sNppData;

// ─────────────────────────────────────────────────────────────────────────
//  Plugin state
// ─────────────────────────────────────────────────────────────────────────
static NSView      *sContentView   = nil;   // the panel's NSView (JsonPanel instance)
static JsonPanel   *sJsonPanel     = nil;   // typed reference (same object as sContentView)
static uint64_t     g_panelHandle  = 0;     // NPPM_DMM_REGISTERPANEL handle; 0 = not docked
static NSPanel     *g_floatingPanel = nil;  // NSPanel fallback for older hosts
static bool         sPanelVisible  = false;
static bool         sNppReady      = false;
static std::string  sResourcesDir;

static npj::Settings sSettings;

// Glue class so the plugin can be a JsonPanelDelegate (the bootstrap is
// plain C/C++; we need a singleton ObjC object to act as delegate).
@interface _NJVPluginBridge : NSObject <JsonPanelDelegate>
@end

static _NJVPluginBridge *sBridge = nil;

// ─────────────────────────────────────────────────────────────────────────
//  Forward declarations
// ─────────────────────────────────────────────────────────────────────────
static void cmdTogglePanel();
static void cmdFormat();
static void cmdCompress();
static void cmdSort();
static void cmdSettings();
static void cmdAbout();

static void ensureContentView();
static NSPanel *ensureFloatingPanel();
static BOOL panelIsShown();
static void refreshTree();
static void selectError(std::size_t offsetWithinSelection);
static void replaceEditorSelection(const std::string& text);
static void applyJsonLanguage();
static void jumpEditorToLine(std::size_t line, std::size_t col, std::size_t length);

// ─────────────────────────────────────────────────────────────────────────
//  Scintilla / NPP helpers
// ─────────────────────────────────────────────────────────────────────────
static inline intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return sNppData._sendMessage(sNppData._nppHandle, msg, w, l);
}

static NppHandle curScintilla() {
    int which = -1;
    npp(NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 1) ? sNppData._scintillaSecondHandle : sNppData._scintillaMainHandle;
}

static inline intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return sNppData._sendMessage(h, msg, w, l);
}

// ─────────────────────────────────────────────────────────────────────────
//  Resources directory — sibling "resources/" folder next to the dylib.
// ─────────────────────────────────────────────────────────────────────────
static std::string resolveResourcesDir() {
    Dl_info info = {};
    if (dladdr((const void *)&resolveResourcesDir, &info) && info.dli_fname) {
        std::string p = info.dli_fname;
        auto slash = p.rfind('/');
        if (slash != std::string::npos) return p.substr(0, slash) + "/resources";
    }
    return "";
}

// ─────────────────────────────────────────────────────────────────────────
//  Panel hosting (same dock/float pattern as XmlNavigator + MarkdownPanel)
// ─────────────────────────────────────────────────────────────────────────
static void ensureContentView() {
    if (sContentView) return;
    @autoreleasepool {
        sJsonPanel = [[JsonPanel alloc] init];
        sJsonPanel.delegate = sBridge;
        sContentView = sJsonPanel;
    }
}

static NSPanel *ensureFloatingPanel() {
    if (g_floatingPanel) return g_floatingPanel;
    ensureContentView();
    @autoreleasepool {
        NSRect frame = NSMakeRect(100, 100, 360, 520);
        NSUInteger mask = NSWindowStyleMaskTitled    |
                          NSWindowStyleMaskClosable  |
                          NSWindowStyleMaskResizable |
                          NSWindowStyleMaskUtilityWindow;
        g_floatingPanel = [[NSPanel alloc] initWithContentRect:frame
                                                      styleMask:mask
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
        g_floatingPanel.title               = @"JSON Viewer";
        g_floatingPanel.hidesOnDeactivate   = NO;
        g_floatingPanel.releasedWhenClosed  = NO;
        g_floatingPanel.level               = NSNormalWindowLevel;

        sContentView.frame = ((NSView *)g_floatingPanel.contentView).bounds;
        sContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [g_floatingPanel.contentView addSubview:sContentView];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification
                       object:g_floatingPanel
                        queue:nil
                   usingBlock:^(NSNotification *n) {
                       sPanelVisible = false;
                       npp(NPPM_SETMENUITEMCHECK, (uintptr_t)sFuncItem[kCmdShowPanel]._cmdID, 0);
                   }];
    }
    return g_floatingPanel;
}

static BOOL panelIsShown() {
    if (g_panelHandle > 0) {
        return sContentView && sContentView.window && sContentView.superview;
    }
    if (g_floatingPanel) return g_floatingPanel.isVisible;
    return NO;
}

// ─────────────────────────────────────────────────────────────────────────
//  Editor-text collection. The Windows plugin picks either the selection
//  (if there is one) or the whole document; the user may also have
//  multi-selection which we refuse.
// ─────────────────────────────────────────────────────────────────────────
struct EditorSnapshot {
    bool        ok          = false;
    bool        fromSelection = false;
    std::string text;
    std::size_t selStart    = 0;   // byte offset in the document where the text came from
    std::size_t selEnd      = 0;
};

static EditorSnapshot snapshotEditorText() {
    EditorSnapshot out;
    NppHandle h = curScintilla();
    if (!h) return out;

    // Reject multi-selections (match Windows behavior).
    if (sci(h, SCI_GETSELECTIONS) > 1) return out;

    std::size_t selStart = (std::size_t)sci(h, SCI_GETSELECTIONSTART);
    std::size_t selEnd   = (std::size_t)sci(h, SCI_GETSELECTIONEND);
    if (selEnd < selStart) std::swap(selStart, selEnd);
    bool hasSel = (selEnd > selStart);

    if (hasSel) {
        std::size_t len = selEnd - selStart;
        if (len > 0) {
            std::string buf;
            buf.resize(len);
            Sci_TextRangeFull tr = { {(Sci_Position)selStart, (Sci_Position)selEnd}, buf.data() };
            // Scintilla fills buf[0..len-1] without a NUL terminator when size matches.
            sci(h, SCI_GETTEXTRANGEFULL, 0, (intptr_t)&tr);
            out.text.swap(buf);
            out.fromSelection = true;
        }
    } else {
        std::size_t total = (std::size_t)sci(h, SCI_GETLENGTH);
        if (total > 0) {
            std::string buf;
            buf.resize(total);
            sci(h, SCI_GETTEXT, (uintptr_t)(total + 1), (intptr_t)buf.data());
            out.text.swap(buf);
            selEnd = total;
        }
    }
    out.ok        = true;
    out.selStart  = selStart;
    out.selEnd    = selEnd;
    return out;
}

static void replaceEditorSelection(const std::string& text) {
    NppHandle h = curScintilla();
    if (!h) return;
    std::size_t selStart = (std::size_t)sci(h, SCI_GETSELECTIONSTART);
    std::size_t selEnd   = (std::size_t)sci(h, SCI_GETSELECTIONEND);
    if (selEnd == selStart) {
        // No selection → replace whole doc
        sci(h, SCI_SETSEL, 0, (intptr_t)sci(h, SCI_GETLENGTH));
    }
    sci(h, SCI_REPLACESEL, 0, (intptr_t)text.c_str());
    // Restore a selection over the newly-inserted region so subsequent
    // format/compress chains operate on the same target.
    sci(h, SCI_SETSEL, selStart, (intptr_t)(selStart + text.size()));
}

static void applyJsonLanguage() {
    if (!sSettings.useJsonHighlight) return;
    npp(NPPM_SETCURRENTLANGTYPE, 0, (intptr_t)/*L_JSON=*/57);
}

static void jumpEditorToLine(std::size_t line, std::size_t column, std::size_t length) {
    NppHandle h = curScintilla();
    if (!h) return;

    // TrackingStream reported positions relative to the *parsed text*, which
    // may have been a selection. Offset by the selection start so the
    // click lands correctly when the JSON was just a piece of the file.
    std::size_t baseStart = (std::size_t)sci(h, SCI_GETSELECTIONSTART);
    std::size_t baseEnd   = (std::size_t)sci(h, SCI_GETSELECTIONEND);
    if (baseEnd < baseStart) std::swap(baseStart, baseEnd);
    std::size_t base = (baseEnd > baseStart) ? baseStart : 0;

    // Resolve line → byte position within the doc, then add column.
    std::size_t baseLine = (std::size_t)sci(h, SCI_LINEFROMPOSITION, (uintptr_t)base);
    std::size_t absLine  = baseLine + line;
    std::size_t lineStart = (std::size_t)sci(h, SCI_POSITIONFROMLINE, (uintptr_t)absLine);
    std::size_t target   = lineStart + column;

    sci(h, SCI_GOTOPOS, (uintptr_t)target);
    if (length > 0) {
        sci(h, SCI_SETSEL, (uintptr_t)target, (intptr_t)(target + length));
    }
    sci(h, 2400);  // SCI_GRABFOCUS — constant isn't exported; matches
                    // XmlNavigator pattern.
}

static void selectError(std::size_t offsetWithinAnalyzed) {
    NppHandle h = curScintilla();
    if (!h) return;
    std::size_t base = (std::size_t)sci(h, SCI_GETSELECTIONSTART);
    std::size_t end  = (std::size_t)sci(h, SCI_GETSELECTIONEND);
    if (end < base) std::swap(base, end);
    if (end == base) base = 0;  // no selection → error offset is absolute
    std::size_t pos = base + offsetWithinAnalyzed;
    sci(h, SCI_SETSEL, pos, (intptr_t)(pos + 1));
    sci(h, SCI_GOTOPOS, pos);
}

// ─────────────────────────────────────────────────────────────────────────
//  refreshTree — the central "re-parse + repopulate the panel" flow.
// ─────────────────────────────────────────────────────────────────────────
static void refreshTree() {
    if (!sJsonPanel) return;
    EditorSnapshot s = snapshotEditorText();
    if (!s.ok || s.text.empty()) {
        [sJsonPanel showPlaceholderMessage:@"Unable to parse JSON. Please ensure a valid JSON string is selected."];
        return;
    }
    npj::ParseResult r = npj::parseJson(s.text, npj::toParseOptions(sSettings));

    // If plain parse failed AND user has "Replace undefined with null" on,
    // retry with the regex pre-pass.
    if (r.status != npj::ParseStatus::Ok && sSettings.replaceUndefined) {
        std::string replaced = npj::replaceUndefinedWithNull(s.text);
        if (replaced != s.text) {
            r = npj::parseJson(replaced, npj::toParseOptions(sSettings));
        }
    }

    if (r.status == npj::ParseStatus::Ok) {
        [sJsonPanel setTree:std::move(r.root)];
    } else {
        NSString *msg = [NSString stringWithFormat:
                         @"Parse error at offset %zu (code %d): %s",
                         r.errorOffset, r.errorCode,
                         r.errorMessage.empty() ? "unknown" : r.errorMessage.c_str()];
        [sJsonPanel showPlaceholderMessage:msg];
    }
}

// ─────────────────────────────────────────────────────────────────────────
//  Menu-command implementations
// ─────────────────────────────────────────────────────────────────────────
static void cmdTogglePanel() {
    ensureContentView();

    // First call: try to dock via the host API. If it accepts → docked
    // mode. If not → fallback NSPanel for older hosts.
    if (g_panelHandle == 0 && g_floatingPanel == nil) {
        intptr_t h = sNppData._sendMessage(sNppData._nppHandle,
                                           NPPM_DMM_REGISTERPANEL,
                                           (uintptr_t)(__bridge void *)sContentView,
                                           (intptr_t)"JSON Viewer");
        if (h > 0) g_panelHandle = (uint64_t)h;
        else        ensureFloatingPanel();
    }

    BOOL currentlyShown = panelIsShown();
    BOOL target         = !currentlyShown;
    sPanelVisible       = target;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)sFuncItem[kCmdShowPanel]._cmdID, target ? 1 : 0);

    if (target) {
        if (g_panelHandle > 0) {
            sNppData._sendMessage(sNppData._nppHandle, NPPM_DMM_SHOWPANEL,
                                  (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel orderFront:nil];
        }
        refreshTree();
    } else {
        if (g_panelHandle > 0) {
            sNppData._sendMessage(sNppData._nppHandle, NPPM_DMM_HIDEPANEL,
                                  (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel orderOut:nil];
        }
    }
}

static void cmdFormat() {
    EditorSnapshot s = snapshotEditorText();
    if (!s.ok || s.text.empty()) {
        @autoreleasepool {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"JSON Viewer";
            a.informativeText = @"Unable to parse JSON. Please ensure a valid JSON string is selected.";
            [a runModal];
        }
        return;
    }
    npj::FormatResult r = npj::formatJson(s.text, npj::toFormatOptions(sSettings));
    if (!r.success && sSettings.replaceUndefined) {
        r = npj::formatJson(npj::replaceUndefinedWithNull(s.text), npj::toFormatOptions(sSettings));
    }
    if (!r.success) {
        @autoreleasepool {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"JSON Viewer: Parse error";
            a.informativeText = [NSString stringWithFormat:
                @"Offset %zu (code %d): %s", r.errorOffset, r.errorCode,
                r.errorMessage.c_str()];
            [a runModal];
        }
        selectError(r.errorOffset);
        return;
    }
    replaceEditorSelection(r.output);
    applyJsonLanguage();
    if (sPanelVisible) refreshTree();
}

static void cmdCompress() {
    EditorSnapshot s = snapshotEditorText();
    if (!s.ok || s.text.empty()) return;
    npj::FormatResult r = npj::compressJson(s.text, npj::toFormatOptions(sSettings));
    if (!r.success && sSettings.replaceUndefined) {
        r = npj::compressJson(npj::replaceUndefinedWithNull(s.text), npj::toFormatOptions(sSettings));
    }
    if (!r.success) {
        selectError(r.errorOffset);
        @autoreleasepool {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"JSON Viewer: Parse error";
            a.informativeText = [NSString stringWithUTF8String:r.errorMessage.c_str()];
            [a runModal];
        }
        return;
    }
    replaceEditorSelection(r.output);
    applyJsonLanguage();
    if (sPanelVisible) refreshTree();
}

static void cmdSort() {
    EditorSnapshot s = snapshotEditorText();
    if (!s.ok || s.text.empty()) return;
    npj::FormatResult r = npj::sortJsonByKey(s.text, npj::toFormatOptions(sSettings));
    if (!r.success && sSettings.replaceUndefined) {
        r = npj::sortJsonByKey(npj::replaceUndefinedWithNull(s.text), npj::toFormatOptions(sSettings));
    }
    if (!r.success) {
        selectError(r.errorOffset);
        @autoreleasepool {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"JSON Viewer: Parse error";
            a.informativeText = [NSString stringWithUTF8String:r.errorMessage.c_str()];
            [a runModal];
        }
        return;
    }
    replaceEditorSelection(r.output);
    applyJsonLanguage();
    if (sPanelVisible) refreshTree();
}

static void cmdValidate() {
    EditorSnapshot s = snapshotEditorText();
    if (!s.ok || s.text.empty()) {
        @autoreleasepool {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"JSON Viewer";
            a.informativeText = @"The text is empty.";
            [a runModal];
        }
        return;
    }
    npj::ParseResult r = npj::parseJson(s.text, npj::toParseOptions(sSettings));
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        if (r.status == npj::ParseStatus::Ok) {
            a.messageText = @"JSON Viewer";
            a.informativeText = @"The JSON appears valid. No errors were found during validation.";
        } else {
            a.messageText = @"JSON Viewer: Validation error";
            a.informativeText = [NSString stringWithFormat:
                @"Offset %zu (code %d): %s", r.errorOffset, r.errorCode,
                r.errorMessage.c_str()];
            selectError(r.errorOffset);
        }
        [a runModal];
    }
}

static void cmdSettings() {
    if ([JsonSettingsDialog presentWithSettings:&sSettings]) {
        if (sPanelVisible) refreshTree();
    }
}

static void cmdAbout() {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"JSON Viewer — macOS port";
        a.informativeText =
            @"Tree-view navigator, formatter, compressor and validator for JSON documents.\n\n"
             "macOS port of NPP-JSONViewer (GPLv2). Parser powered by RapidJSON SAX.\n\n"
             "Panel docks via NPPM_DMM_* when the host supports it; falls back to a\n"
             "floating NSPanel on older hosts.\n\n"
             "Report issues: https://github.com/notepad-plus-plus-mac/JSON-Viewer/issues";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

// ─────────────────────────────────────────────────────────────────────────
//  Bridge delegate (toolbar buttons from the panel → our commands)
// ─────────────────────────────────────────────────────────────────────────
@implementation _NJVPluginBridge
- (void)jsonPanel:(JsonPanel *)panel
    didSelectNodeAtLine:(NSUInteger)line
             column:(NSUInteger)column
             length:(NSUInteger)length {
    jumpEditorToLine((std::size_t)line, (std::size_t)column, (std::size_t)length);
}
- (void)jsonPanelRequestedRefresh:(JsonPanel *)panel   { refreshTree(); }
- (void)jsonPanelRequestedValidate:(JsonPanel *)panel  { cmdValidate(); }
- (void)jsonPanelRequestedFormat:(JsonPanel *)panel    { cmdFormat(); }
@end

// ─────────────────────────────────────────────────────────────────────────
//  Plugin exports
// ─────────────────────────────────────────────────────────────────────────

static void installShortcut(ShortcutKey *out, char base) {
    out->_isCtrl  = true;   // ⌘
    out->_isAlt   = true;   // ⌥
    out->_isShift = true;   // ⇧
    out->_key     = (UCHAR)base;
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    sNppData       = data;
    sResourcesDir  = resolveResourcesDir();
    sSettings      = npj::loadSettings();
    sBridge        = [[_NJVPluginBridge alloc] init];

    memset(sFuncItem, 0, sizeof(sFuncItem));

    auto setItem = [&](int idx, const char *name, PFUNCPLUGINCMD fn) {
        strlcpy(sFuncItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE);
        sFuncItem[idx]._pFunc      = fn;
        sFuncItem[idx]._init2Check = false;
        sFuncItem[idx]._pShKey     = nullptr;
    };

    setItem(kCmdShowPanel, "Show JSON Viewer",       cmdTogglePanel);
    setItem(kCmdFormat,    "Format JSON",            cmdFormat);
    setItem(kCmdCompress,  "Compress JSON",          cmdCompress);
    setItem(kCmdSort,      "Sort by key (ascending)", cmdSort);
    // Separator slot — empty name + null pFunc makes this a menu separator.
    sFuncItem[kCmdSep]._itemName[0] = '\0';
    sFuncItem[kCmdSep]._pFunc       = nullptr;
    setItem(kCmdSettings,  "Settings",               cmdSettings);
    setItem(kCmdAbout,     "About",                  cmdAbout);

    // Shortcuts — allocate small heap objects owned by the static array.
    static ShortcutKey scShow, scFormat, scCompress, scSort;
    installShortcut(&scShow,     'J');
    installShortcut(&scFormat,   'M');
    installShortcut(&scCompress, 'C');
    installShortcut(&scSort,     'K');
    sFuncItem[kCmdShowPanel]._pShKey = &scShow;
    sFuncItem[kCmdFormat]._pShKey    = &scFormat;
    sFuncItem[kCmdCompress]._pShKey  = &scCompress;
    sFuncItem[kCmdSort]._pShKey      = &scSort;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = kCmdCount;
    return sFuncItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION: {
            // Register our toolbar icon (plugin-dir/toolbar.png).
            sNppData._sendMessage(sNppData._nppHandle,
                                  NPPM_ADDTOOLBARICON_FORDARKMODE,
                                  (uintptr_t)sFuncItem[kCmdShowPanel]._cmdID,
                                  (intptr_t)"toolbar.png");
            break;
        }
        case NPPN_READY:
            sNppReady = true;
            break;
        case NPPN_BUFFERACTIVATED:
            if (sPanelVisible && sSettings.followCurrentTab) refreshTree();
            break;
        case NPPN_FILEOPENED:
            if (sSettings.autoFormatOnOpen) {
                // Match Windows: only auto-format files that look like JSON.
                unsigned lang = 0;
                sNppData._sendMessage(sNppData._nppHandle, NPPM_GETCURRENTLANGTYPE, 0, (intptr_t)&lang);
                if (lang == (unsigned)/*L_JSON=*/57) cmdFormat();
            }
            break;
        case SCN_MODIFIED:
            if (sPanelVisible && (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
                // Debounce in the panel would be nicer; for v1 just refresh
                // unconditionally. The tree build is O(N) in nodes and very
                // fast for typical JSON docs.
                static dispatch_block_t pending = nil;
                if (pending) { dispatch_block_cancel(pending); pending = nil; }
                pending = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
                    refreshTree();
                    pending = nil;
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), pending);
            }
            break;
        case NPPN_SHUTDOWN:
            npj::saveSettings(sSettings);
            if (g_panelHandle > 0) {
                sNppData._sendMessage(sNppData._nppHandle,
                                      NPPM_DMM_UNREGISTERPANEL,
                                      (uintptr_t)g_panelHandle, 0);
                g_panelHandle = 0;
            }
            if (g_floatingPanel) {
                [g_floatingPanel close];
                g_floatingPanel = nil;
            }
            sJsonPanel    = nil;
            sContentView  = nil;
            sBridge       = nil;
            break;
        default: break;
    }
}

// ─────────────────────────────────────────────────────────────────────────
//  Inter-plugin bridge: make the panel visible on request (does NOT toggle).
//  Used by the JSTool (JSMinNPP) "JSON Viewer" menu item via NPPM_MSGTOPLUGIN.
//  Mirrors the "show" branch of cmdTogglePanel() but never hides.
// ─────────────────────────────────────────────────────────────────────────
static void bridgeShowPanel() {
    ensureContentView();

    if (g_panelHandle == 0 && g_floatingPanel == nil) {
        intptr_t h = sNppData._sendMessage(sNppData._nppHandle,
                                           NPPM_DMM_REGISTERPANEL,
                                           (uintptr_t)(__bridge void *)sContentView,
                                           (intptr_t)"JSON Viewer");
        if (h > 0) g_panelHandle = (uint64_t)h;
        else        ensureFloatingPanel();
    }

    if (!panelIsShown()) {
        sPanelVisible = true;
        npp(NPPM_SETMENUITEMCHECK, (uintptr_t)sFuncItem[kCmdShowPanel]._cmdID, 1);
        if (g_panelHandle > 0) {
            sNppData._sendMessage(sNppData._nppHandle, NPPM_DMM_SHOWPANEL,
                                  (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel orderFront:nil];
        }
    }
    refreshTree();
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t Message, uintptr_t wParam, intptr_t lParam) {
    // The host delivers inter-plugin messages as (NPPM_MSGTOPLUGIN, 0, ci).
    if (Message == NPPM_MSGTOPLUGIN && lParam) {
        struct CommunicationInfo *ci = (struct CommunicationInfo *)lParam;
        switch (ci->internalMsg) {
            case JV_BRIDGE_MSG_PING:
                // Identify ourselves as a bridge-capable JSON Viewer.
                return JV_BRIDGE_ACK;
            case JV_BRIDGE_MSG_SHOWPANEL:
                if ([NSThread isMainThread]) {
                    bridgeShowPanel();
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{ bridgeShowPanel(); });
                }
                return 1;
            default:
                break;
        }
    }
    return 1;
}
