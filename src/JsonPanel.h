// JsonPanel — content NSView for the JSON Viewer plugin.
//
// Two-section layout matching our host's side-panel standard (Function
// List, Folder as Workspace):
//
//   [ search field  ·  [refresh] [validate] [format] ]
//   ─────────────────────────────────────────────────
//   [ NSOutlineView — JSON tree, lazily bound to JsonNode model ]
//
// Does not render its own title bar or close X — the host PanelFrame
// supplies those when the view is registered via NPPM_DMM_REGISTERPANEL.
// Floating-fallback path wraps this in an NSPanel (for older hosts
// without the docking API).

#pragma once

#import <Cocoa/Cocoa.h>

#import "JsonParser.h"
#import "JsonFormatter.h"

NS_ASSUME_NONNULL_BEGIN

@class JsonPanel;

@protocol JsonPanelDelegate <NSObject>
// User clicked a tree node. `line` and `column` are 0-based inside the
// editor's current Scintilla document; `length` is the key/value token
// length in bytes. Delegate (the plugin bootstrap) forwards to Scintilla.
- (void)jsonPanel:(JsonPanel *)panel didSelectNodeAtLine:(NSUInteger)line
                                              column:(NSUInteger)column
                                              length:(NSUInteger)length;
// Actions fired from the toolbar buttons / context menu.
- (void)jsonPanelRequestedRefresh:(JsonPanel *)panel;
- (void)jsonPanelRequestedValidate:(JsonPanel *)panel;
- (void)jsonPanelRequestedFormat:(JsonPanel *)panel;
@end

@interface JsonPanel : NSView

@property (nonatomic, weak, nullable) id<JsonPanelDelegate> delegate;

// Install a fresh tree model. Call after a parse (or to show an error
// placeholder). Pass nil to clear.
- (void)setTree:(std::unique_ptr<npj::JsonNode>)root;

// Show a placeholder message under the root (e.g. parse error details).
- (void)showPlaceholderMessage:(NSString *)text;

// Current font size for the tree row. Also controls row height.
@property (nonatomic, assign) CGFloat panelFontSize;

// Host-integration hooks called by Cmd +/−/0 via FloatingPanelWindow /
// MainWindowController's panel-zoom routing (same pattern other panels use).
- (void)panelZoomIn;
- (void)panelZoomOut;
- (void)panelZoomReset;

@end

NS_ASSUME_NONNULL_END
