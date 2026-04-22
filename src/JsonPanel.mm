// JsonPanel implementation.
//
// NSOutlineView data-source binds directly to the JsonNode tree via
// non-owning JsonNode* pointers wrapped in NSValue. The panel owns the
// tree (std::unique_ptr<JsonNode>); the outline view retains only NSValue
// wrappers, which are pure pointer containers — so the tree lifetime is
// independent of AppKit's internal row cache. Whenever we replace the
// tree (Refresh, live-parse on buffer change, etc.) we -reloadData first
// so stale NSValue pointers are dropped before the new root is installed.
//
// Filtering ("search in tree") builds an in-memory std::unordered_set of
// nodes to show. Any node in the set AND all its ancestors are visible;
// everything else is pruned by numberOfChildrenOfItem: / child:ofItem:.
// On a non-empty filter we also auto-expand so hits surface without a
// manual toggle. Empty filter hides nothing (the set is simply ignored).

#import "JsonPanel.h"

#include <dlfcn.h>
#include <functional>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

// ─────────────────────────────────────────────────────────────────────────
//  Helpers for NSValue wrapping of JsonNode*. Two NSValue instances
//  wrapping the same pointer compare equal under -isEqual:, which is
//  what NSOutlineView uses to remember expansion state for the same
//  item across calls.
// ─────────────────────────────────────────────────────────────────────────
static inline NSValue *nodeWrap(const npj::JsonNode *n) {
    return [NSValue valueWithPointer:(const void *)n];
}
static inline const npj::JsonNode *nodeUnwrap(id obj) {
    if (![obj isKindOfClass:[NSValue class]]) return nullptr;
    return static_cast<const npj::JsonNode *>([obj pointerValue]);
}

// ─────────────────────────────────────────────────────────────────────────
//  _JVOutlineView — NSOutlineView subclass that renders the disclosure
//  triangle at ~50% of the system default size. Achieved by returning a
//  shrunk frame from frameOfOutlineCellAtRow: (AppKit scales the triangle
//  artwork to fit the rect).
// ─────────────────────────────────────────────────────────────────────────
@interface _JVOutlineView : NSOutlineView
@end

@implementation _JVOutlineView

// AppKit uses the rect returned from this method for BOTH drawing the
// disclosure triangle AND hit-testing clicks on it. We return a shrunk
// rect so the arrow *renders* tiny, but hit testing for clicks is
// restored to the default-size zone via the mouseDown: override below.
// Without that override, users have to click a 2–3 pixel target, which
// feels glitchy and falls through to the row-select action when missed.
- (NSRect)frameOfOutlineCellAtRow:(NSInteger)row {
    NSRect r = [super frameOfOutlineCellAtRow:row];
    if (NSIsEmptyRect(r)) return r;

    // ~17.5% of the default triangle size — the stepped-down sequence
    // has been: 1.0 (system) → 0.5 → 0.25 → 0.175 (this round, 30%
    // smaller than the previous 0.25×). Re-centered inside the original
    // rect so the vertical alignment stays stable.
    const CGFloat k = 0.175;
    CGFloat newW = r.size.width  * k;
    CGFloat newH = r.size.height * k;
    r.origin.x += (r.size.width  - newW) * 0.5;
    r.origin.y += (r.size.height - newH) * 0.5;
    r.size.width  = newW;
    r.size.height = newH;
    return r;
}

// Restore the default-size click target for the disclosure triangle.
// `[super frameOfOutlineCellAtRow:]` bypasses our override and gives us
// the system's natural ~13×13pt rect — we use that as the hit zone so
// users can comfortably click the area around the tiny glyph, matching
// the pre-shrink click behavior.
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    if (row >= 0) {
        id item = [self itemAtRow:row];
        if (item && [self isExpandable:item]) {
            NSRect fullRect = [super frameOfOutlineCellAtRow:row];
            if (!NSIsEmptyRect(fullRect) && NSMouseInRect(p, fullRect, self.isFlipped)) {
                if ([self isItemExpanded:item]) {
                    [self collapseItem:item];
                } else {
                    [self expandItem:item];
                }
                return;   // consumed — don't let super turn this into a row selection
            }
        }
    }
    [super mouseDown:event];
}

@end

// ─────────────────────────────────────────────────────────────────────────
//  _JVPanelButton — 16×16 button with panel-toolbar hover style. Same
//  visual spec as _NMPPanelButton in NppMarkdownPanel and _FTPanelButton
//  in the host's FolderTreePanel: no border at rest, blueish border +
//  light-blue fill on hover/press, no fill in dark mode.
// ─────────────────────────────────────────────────────────────────────────
@interface _JVPanelButton : NSButton {
    BOOL _hovering;
}
@property (nonatomic, copy)   NSString *iconName;          // basename w/o .png
@property (nonatomic, copy, nullable) NSString *resourcesDir;
- (void)reloadIcon;
@end

@implementation _JVPanelButton

- (instancetype)init {
    self = [super init];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.bordered = NO;
        [self setButtonType:NSButtonTypeMomentaryChange];
        [self.widthAnchor  constraintEqualToConstant:16].active = YES;
        [self.heightAnchor constraintEqualToConstant:16].active = YES;
        NSTrackingArea *ta = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited |
                          NSTrackingActiveInActiveApp |
                          NSTrackingInVisibleRect)
                   owner:self userInfo:nil];
        [self addTrackingArea:ta];
    }
    return self;
}

- (void)mouseEntered:(NSEvent *)event { _hovering = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event  { _hovering = NO;  [self setNeedsDisplay:YES]; }

- (BOOL)_isDark {
    if (@available(macOS 10.14, *)) {
        NSAppearanceName match = [self.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,
                                                 NSAppearanceNameDarkAqua]];
        return [match isEqualToString:NSAppearanceNameDarkAqua];
    }
    return NO;
}

- (void)reloadIcon {
    if (!_iconName.length || !_resourcesDir.length) return;
    NSString *path = [NSString stringWithFormat:@"%@/%@.png", _resourcesDir, _iconName];
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
    if (img) {
        img.size = NSMakeSize(11, 11);   // 11pt visual size inside 16×16 button
        self.image = img;
    }
    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self reloadIcon];
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL pressed = self.isHighlighted;
    BOOL active  = pressed || _hovering;
    BOOL isDark  = [self _isDark];

    if (active) {
        if (!isDark) {
            NSColor *bg = pressed
                ? [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:1.0]
                : [NSColor colorWithRed:0xE5/255.0 green:0xF3/255.0 blue:0xFF/255.0 alpha:1.0];
            [bg setFill];
            NSRectFill(self.bounds);
        }
        NSColor *bdr = [NSColor colorWithRed:0xD0/255.0 green:0xEA/255.0 blue:0xFF/255.0 alpha:1.0];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 0.5, 0.5)];
        border.lineWidth = 1.0;
        [bdr setStroke];
        [border stroke];
    }

    if (self.image) {
        NSSize isz = self.image.size;
        NSRect ir = NSMakeRect(NSMidX(self.bounds) - isz.width / 2.0,
                               NSMidY(self.bounds) - isz.height / 2.0,
                               isz.width, isz.height);
        [self.image drawInRect:ir
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:nil];
    }
}

@end

// ─────────────────────────────────────────────────────────────────────────
//  JsonPanel main class
// ─────────────────────────────────────────────────────────────────────────

@interface JsonPanel () <NSOutlineViewDataSource, NSOutlineViewDelegate,
                          NSTextFieldDelegate, NSMenuItemValidation>
@end

@implementation JsonPanel {
    // Tree state (owned)
    std::unique_ptr<npj::JsonNode> _tree;
    // Optional placeholder when there's no valid tree (parse error, empty).
    NSString                      *_placeholderText;

    // UI
    NSTextField                   *_searchField;
    _JVPanelButton                *_refreshButton;
    _JVPanelButton                *_validateButton;
    _JVPanelButton                *_formatButton;
    NSScrollView                  *_scrollView;
    NSOutlineView                 *_outlineView;

    // Filter
    std::unordered_set<const npj::JsonNode *> _visibleSet;
    std::string                                _filterText;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _panelFontSize = 10;
        [self _buildLayout];
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:NSMakeRect(0, 0, 340, 520)]; }

- (void)_buildLayout {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Toolbar row ─────────────────────────────────────────────────────
    _searchField = [[NSTextField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = @"Search in tree...";
    _searchField.font = [NSFont systemFontOfSize:11];
    _searchField.bezelStyle = NSTextFieldRoundedBezel;
    _searchField.delegate = self;
    [[_searchField cell] setScrollable:YES];
    [self addSubview:_searchField];

    NSString *resourcesDir = [self _resourcesDir];
    _refreshButton  = [self _makeButton:@"jv_refresh"  tooltip:@"Refresh JSON tree"          resourcesDir:resourcesDir action:@selector(_refreshClicked:)];
    _validateButton = [self _makeButton:@"jv_validate" tooltip:@"Validate JSON"              resourcesDir:resourcesDir action:@selector(_validateClicked:)];
    _formatButton   = [self _makeButton:@"jv_format"   tooltip:@"Format / Beautify JSON"     resourcesDir:resourcesDir action:@selector(_formatClicked:)];

    // ── Outline view ────────────────────────────────────────────────────
    _outlineView = [[_JVOutlineView alloc] init];
    _outlineView.headerView = nil;
    _outlineView.rowHeight  = _panelFontSize + 8;
    _outlineView.indentationPerLevel = 14;
    _outlineView.allowsMultipleSelection = NO;
    _outlineView.autoresizesOutlineColumn = NO;
    _outlineView.dataSource = self;
    _outlineView.delegate   = self;
    _outlineView.target = self;
    _outlineView.action = @selector(_outlineRowClicked:);

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"node"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outlineView addTableColumn:col];
    _outlineView.outlineTableColumn = col;
    [_outlineView sizeLastColumnToFit];

    // Context menu (applied at every right-click via menuForEvent:)
    _outlineView.menu = [self _buildContextMenu];

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;
    _scrollView.documentView = _outlineView;
    [self addSubview:_scrollView];

    // ── Constraints ─────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // Search field — leading gutter 6pt, 22pt tall, to left of refresh
        [_searchField.topAnchor      constraintEqualToAnchor:self.topAnchor constant:4],
        [_searchField.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor constant:6],
        [_searchField.trailingAnchor constraintEqualToAnchor:_refreshButton.leadingAnchor constant:-6],
        [_searchField.heightAnchor   constraintEqualToConstant:22],

        // Three buttons right-aligned: refresh, validate, format
        [_formatButton.trailingAnchor   constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [_validateButton.trailingAnchor constraintEqualToAnchor:_formatButton.leadingAnchor   constant:-2],
        [_refreshButton.trailingAnchor  constraintEqualToAnchor:_validateButton.leadingAnchor constant:-2],

        [_refreshButton.centerYAnchor  constraintEqualToAnchor:_searchField.centerYAnchor],
        [_validateButton.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],
        [_formatButton.centerYAnchor   constraintEqualToAnchor:_searchField.centerYAnchor],

        // Outline fills the rest
        [_scrollView.topAnchor      constraintEqualToAnchor:_searchField.bottomAnchor constant:4],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scrollView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

- (NSString *)_resourcesDir {
    // The dylib lives at <plugin-dir>/<NppJsonViewer>.dylib, with
    // resources/ alongside. Walk one level up from the dylib path.
    Dl_info info = {};
    dladdr((__bridge const void *)[self class], &info);
    if (!info.dli_fname) return nil;
    NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
    NSString *pluginDir = [dylibPath stringByDeletingLastPathComponent];
    return [pluginDir stringByAppendingPathComponent:@"resources"];
}

- (_JVPanelButton *)_makeButton:(NSString *)iconName
                         tooltip:(NSString *)tooltip
                    resourcesDir:(NSString *)resourcesDir
                          action:(SEL)action {
    _JVPanelButton *b = [[_JVPanelButton alloc] init];
    b.resourcesDir = resourcesDir;
    b.iconName     = iconName;
    b.toolTip      = tooltip;
    b.target       = self;
    b.action       = action;
    [b reloadIcon];
    [self addSubview:b];
    return b;
}

// ─── Public API ──────────────────────────────────────────────────────────

- (void)setTree:(std::unique_ptr<npj::JsonNode>)root {
    // Always reload FIRST with the old tree still live — ensures AppKit's
    // per-row cache drops all NSValue wrappers before we destroy their
    // underlying JsonNode objects.
    [_outlineView reloadData];
    _tree = std::move(root);
    _placeholderText = nil;
    _visibleSet.clear();
    _filterText.clear();
    _searchField.stringValue = @"";
    [_outlineView reloadData];
    // Expand root so the user sees immediate structure without clicking.
    if (_tree && !_tree->children.empty()) {
        [_outlineView expandItem:nodeWrap(_tree.get())];
    }
}

- (void)showPlaceholderMessage:(NSString *)text {
    _tree.reset();
    _visibleSet.clear();
    _filterText.clear();
    _searchField.stringValue = @"";
    _placeholderText = [text copy];
    [_outlineView reloadData];
}

- (void)panelZoomIn {
    _panelFontSize = MIN(_panelFontSize + 1, 28);
    _outlineView.rowHeight = _panelFontSize + 8;
    [_outlineView reloadData];
}

- (void)panelZoomOut {
    _panelFontSize = MAX(_panelFontSize - 1, 8);
    _outlineView.rowHeight = _panelFontSize + 8;
    [_outlineView reloadData];
}

- (void)panelZoomReset {
    _panelFontSize = 10;
    _outlineView.rowHeight = _panelFontSize + 8;
    [_outlineView reloadData];
}

// ─── Toolbar actions ─────────────────────────────────────────────────────

- (void)_refreshClicked:(id)sender {
    id<JsonPanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(jsonPanelRequestedRefresh:)])
        [d jsonPanelRequestedRefresh:self];
}
- (void)_validateClicked:(id)sender {
    id<JsonPanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(jsonPanelRequestedValidate:)])
        [d jsonPanelRequestedValidate:self];
}
- (void)_formatClicked:(id)sender {
    id<JsonPanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(jsonPanelRequestedFormat:)])
        [d jsonPanelRequestedFormat:self];
}

// ─── Row-click → editor jump ─────────────────────────────────────────────

- (void)_outlineRowClicked:(id)sender {
    NSInteger row = _outlineView.clickedRow;
    if (row < 0) return;
    id item = [_outlineView itemAtRow:row];
    const npj::JsonNode *n = nodeUnwrap(item);
    if (!n || n == _tree.get()) return;  // root has no useful position
    if (!n->pos.length)  return;

    id<JsonPanelDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(jsonPanel:didSelectNodeAtLine:column:length:)]) {
        [d jsonPanel:self
            didSelectNodeAtLine:n->pos.line
                       column:n->pos.column
                       length:n->pos.length];
    }
}

// ─── Filter ──────────────────────────────────────────────────────────────
//
// Rebuild _visibleSet via a DFS: a node is visible if its key or value
// contains the filter substring (case-insensitive), OR any of its
// descendants is visible. We populate the set so the data-source methods
// can check membership in O(1).

- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object != _searchField) return;
    NSString *q = [_searchField.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    _filterText = q ? std::string([q UTF8String]) : std::string();
    [self _rebuildVisibleSet];
    [_outlineView reloadData];
    if (!_filterText.empty()) {
        [_outlineView expandItem:nil expandChildren:YES];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)fieldEditor
     doCommandBySelector:(SEL)cmd {
    // Escape clears the filter
    if (cmd == @selector(cancelOperation:) && [control isKindOfClass:[NSTextField class]]) {
        NSTextField *tf = (NSTextField *)control;
        if (tf.stringValue.length) {
            tf.stringValue = @"";
            _filterText.clear();
            _visibleSet.clear();
            [_outlineView reloadData];
            return YES;
        }
    }
    return NO;
}

- (BOOL)_nodeMatches:(const npj::JsonNode *)n {
    if (_filterText.empty()) return YES;
    auto contains = [&](const std::string& s) -> bool {
        // case-insensitive substring. Small strings, bytewise lower-cmp is fine.
        if (s.size() < _filterText.size()) return NO;
        for (std::size_t i = 0; i + _filterText.size() <= s.size(); ++i) {
            bool hit = true;
            for (std::size_t j = 0; j < _filterText.size(); ++j) {
                char a = std::tolower(static_cast<unsigned char>(s[i + j]));
                char b = std::tolower(static_cast<unsigned char>(_filterText[j]));
                if (a != b) { hit = false; break; }
            }
            if (hit) return YES;
        }
        return NO;
    };
    return contains(n->key) || contains(n->value);
}

- (BOOL)_populateVisible:(const npj::JsonNode *)n {
    BOOL selfMatches = [self _nodeMatches:n];
    BOOL anyChildVisible = NO;
    for (const auto& c : n->children) {
        if ([self _populateVisible:c.get()]) anyChildVisible = YES;
    }
    if (selfMatches || anyChildVisible) {
        _visibleSet.insert(n);
        return YES;
    }
    return NO;
}

- (void)_rebuildVisibleSet {
    _visibleSet.clear();
    if (_filterText.empty() || !_tree) return;
    [self _populateVisible:_tree.get()];
}

// ─── Data source ─────────────────────────────────────────────────────────

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(nullable id)item {
    if (!_tree) {
        // Placeholder mode — one synthetic row showing the message.
        return (item == nil && _placeholderText.length) ? 1 : 0;
    }
    // nil item = outline's top level. The root JsonNode IS the sole top-
    // level row (rendered as "JSON"), so its own children appear one
    // level deeper — matching the Windows tree in Image #30.
    if (item == nil) {
        return 1;
    }
    const npj::JsonNode *n = nodeUnwrap(item);
    if (!n) return 0;

    if (!_filterText.empty()) {
        NSInteger count = 0;
        for (const auto& c : n->children) {
            if (_visibleSet.find(c.get()) != _visibleSet.end()) ++count;
        }
        return count;
    }
    return (NSInteger)n->children.size();
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(nullable id)item {
    if (!_tree) {
        // Synthetic placeholder row (represented by a unique sentinel string).
        return @"__JV_PLACEHOLDER__";
    }
    if (item == nil) {
        return nodeWrap(_tree.get());   // the "JSON" root
    }
    const npj::JsonNode *n = nodeUnwrap(item);
    if (!n) return @"";

    if (!_filterText.empty()) {
        NSInteger i = 0;
        for (const auto& c : n->children) {
            if (_visibleSet.find(c.get()) == _visibleSet.end()) continue;
            if (i == index) return nodeWrap(c.get());
            ++i;
        }
        return @"";
    }
    if (index < 0 || (std::size_t)index >= n->children.size()) return @"";
    return nodeWrap(n->children[(std::size_t)index].get());
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    if ([item isKindOfClass:[NSString class]]) return NO;  // placeholder row
    const npj::JsonNode *n = nodeUnwrap(item);
    if (!n) return NO;
    if (!_filterText.empty()) {
        // Only count visible children under the filter.
        for (const auto& c : n->children) {
            if (_visibleSet.find(c.get()) != _visibleSet.end()) return YES;
        }
        return NO;
    }
    return !n->children.empty();
}

// ─── Delegate: cell views ────────────────────────────────────────────────

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    static NSString * const kId = @"JVCell";
    NSTableCellView *cell = [ov makeViewWithIdentifier:kId owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = kId;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:tf];
        cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor  constant:2],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    cell.textField.font = [NSFont systemFontOfSize:_panelFontSize];

    if ([item isKindOfClass:[NSString class]]) {
        // placeholder row
        cell.textField.stringValue = _placeholderText ?: @"";
        cell.textField.textColor   = [NSColor secondaryLabelColor];
        return cell;
    }

    const npj::JsonNode *n = nodeUnwrap(item);
    if (!n) { cell.textField.stringValue = @""; return cell; }

    // Root label: literally "JSON" (no count suffix) — matches the
    // Windows tree in Image #28 where the root is always labeled "JSON"
    // regardless of the document's top-level type.
    if (n == _tree.get()) {
        cell.textField.stringValue = @"JSON";
        cell.textField.textColor   = [NSColor labelColor];
        return cell;
    }

    // Container row: "key {N}" or "[idx] [N]"
    if (n->type == npj::JsonNodeType::Object || n->type == npj::JsonNodeType::Array) {
        std::string label = n->key;
        label += " ";
        label += (n->type == npj::JsonNodeType::Array) ? "[" : "{";
        label += std::to_string(n->memberCount);
        label += (n->type == npj::JsonNodeType::Array) ? "]" : "}";
        cell.textField.stringValue = [NSString stringWithUTF8String:label.c_str()] ?: @"";
    } else {
        cell.textField.stringValue = [NSString stringWithUTF8String:npj::formatLeafLabel(*n).c_str()] ?: @"";
    }
    cell.textField.textColor = [self _colorForNodeType:n->type];
    return cell;
}

- (NSColor *)_colorForNodeType:(npj::JsonNodeType)t {
    // Subtle semantic coloring, readable in both light and dark modes.
    switch (t) {
        case npj::JsonNodeType::String: return [NSColor systemGreenColor];
        case npj::JsonNodeType::Number: return [NSColor systemBlueColor];
        case npj::JsonNodeType::Bool:   return [NSColor systemOrangeColor];
        case npj::JsonNodeType::Null:   return [NSColor systemGrayColor];
        default:                        return [NSColor labelColor];
    }
}

- (CGFloat)outlineView:(NSOutlineView *)ov heightOfRowByItem:(id)item {
    return _panelFontSize + 8;
}

// ─── Context menu ────────────────────────────────────────────────────────
//
// Items match Windows exactly. Enable/disable logic:
//   * root node:       Copy enabled; Copy name/value/path disabled;
//                      Expand/Collapse enabled if it has children
//   * container node:  Copy + Copy path enabled; Copy name/value disabled
//   * leaf node:       all 4 copies enabled; Expand/Collapse disabled

- (NSMenu *)_buildContextMenu {
    NSMenu *m = [[NSMenu alloc] init];
    m.autoenablesItems = YES;

    NSMenuItem *copyAll = [[NSMenuItem alloc] initWithTitle:@"Copy"
                                                     action:@selector(_ctxCopy:)
                                              keyEquivalent:@""];
    copyAll.target = self;
    [m addItem:copyAll];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *copyName = [[NSMenuItem alloc] initWithTitle:@"Copy name"
                                                     action:@selector(_ctxCopyName:)
                                              keyEquivalent:@""];
    copyName.target = self;
    [m addItem:copyName];

    NSMenuItem *copyValue = [[NSMenuItem alloc] initWithTitle:@"Copy value"
                                                      action:@selector(_ctxCopyValue:)
                                               keyEquivalent:@""];
    copyValue.target = self;
    [m addItem:copyValue];

    NSMenuItem *copyPath = [[NSMenuItem alloc] initWithTitle:@"Copy path"
                                                     action:@selector(_ctxCopyPath:)
                                              keyEquivalent:@""];
    copyPath.target = self;
    [m addItem:copyPath];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *expandAll = [[NSMenuItem alloc] initWithTitle:@"Expand all"
                                                      action:@selector(_ctxExpandAll:)
                                               keyEquivalent:@""];
    expandAll.target = self;
    [m addItem:expandAll];

    NSMenuItem *collapseAll = [[NSMenuItem alloc] initWithTitle:@"Collapse all"
                                                        action:@selector(_ctxCollapseAll:)
                                                 keyEquivalent:@""];
    collapseAll.target = self;
    [m addItem:collapseAll];

    return m;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    // We don't use NSOutlineView's default — we want to select the row
    // under the mouse before the menu appears so the copy actions have
    // a valid target.
    NSPoint p = [_outlineView convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [_outlineView rowAtPoint:p];
    if (row >= 0) {
        [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                   byExtendingSelection:NO];
    }
    return _outlineView.menu;
}

- (const npj::JsonNode *)_selectedNode {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return nullptr;
    return nodeUnwrap([_outlineView itemAtRow:row]);
}

// Collect ancestor chain root→(parent of `target`) for path building. O(N)
// walk through the tree; acceptable since this only runs on menu actions.
- (std::vector<const npj::JsonNode *>)_ancestorsOf:(const npj::JsonNode *)target {
    std::vector<const npj::JsonNode *> result;
    if (!_tree || !target) return result;
    std::function<bool(const npj::JsonNode *, std::vector<const npj::JsonNode *>&)> walk =
    [&walk, target](const npj::JsonNode *n, std::vector<const npj::JsonNode *>& stack) -> bool {
        if (n == target) return true;
        stack.push_back(n);
        for (const auto& c : n->children) {
            if (walk(c.get(), stack)) return true;
        }
        stack.pop_back();
        return false;
    };
    std::vector<const npj::JsonNode *> stack;
    walk(_tree.get(), stack);
    return stack;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    const npj::JsonNode *n = [self _selectedNode];
    SEL a = item.action;
    BOOL isRoot      = (n == _tree.get());
    BOOL isContainer = n && (n->type == npj::JsonNodeType::Object || n->type == npj::JsonNodeType::Array);

    if (a == @selector(_ctxCopy:))       return n != nullptr;
    if (a == @selector(_ctxCopyName:))   return n && !isRoot && !isContainer;
    if (a == @selector(_ctxCopyValue:))  return n && !isRoot && !isContainer;
    if (a == @selector(_ctxCopyPath:))   return n && !isRoot;
    if (a == @selector(_ctxExpandAll:))  return n && isContainer;
    if (a == @selector(_ctxCollapseAll:)) return n && isContainer;
    return YES;
}

- (void)_pasteboardCopy:(NSString *)s {
    if (!s.length) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:s forType:NSPasteboardTypeString];
}

- (void)_ctxCopy:(id)sender {
    const npj::JsonNode *n = [self _selectedNode];
    if (!n) return;
    NSString *full;
    if (n->type == npj::JsonNodeType::Object || n->type == npj::JsonNodeType::Array) {
        std::string label = n->key;
        label += " ";
        label += (n->type == npj::JsonNodeType::Array) ? "[" : "{";
        label += std::to_string(n->memberCount);
        label += (n->type == npj::JsonNodeType::Array) ? "]" : "}";
        full = [NSString stringWithUTF8String:label.c_str()];
    } else {
        full = [NSString stringWithUTF8String:npj::formatLeafLabel(*n).c_str()];
    }
    [self _pasteboardCopy:full];
}

- (void)_ctxCopyName:(id)sender {
    const npj::JsonNode *n = [self _selectedNode];
    if (!n) return;
    [self _pasteboardCopy:[NSString stringWithUTF8String:n->key.c_str()]];
}

- (void)_ctxCopyValue:(id)sender {
    const npj::JsonNode *n = [self _selectedNode];
    if (!n) return;
    [self _pasteboardCopy:[NSString stringWithUTF8String:n->value.c_str()]];
}

- (void)_ctxCopyPath:(id)sender {
    const npj::JsonNode *n = [self _selectedNode];
    if (!n || n == _tree.get()) return;
    auto ancestors = [self _ancestorsOf:n];
    // Drop the synthetic root from the ancestor list so paths start at
    // the first real level (matches Windows output).
    if (!ancestors.empty() && ancestors.front() == _tree.get())
        ancestors.erase(ancestors.begin());
    std::string path = npj::buildNodePath(ancestors, *n);
    [self _pasteboardCopy:[NSString stringWithUTF8String:path.c_str()]];
}

- (void)_ctxExpandAll:(id)sender {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    id item = [_outlineView itemAtRow:row];
    if (item) [_outlineView expandItem:item expandChildren:YES];
}

- (void)_ctxCollapseAll:(id)sender {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    id item = [_outlineView itemAtRow:row];
    if (item) [_outlineView collapseItem:item collapseChildren:YES];
}

// ─── Cleanup ─────────────────────────────────────────────────────────────

- (void)dealloc {
    // Drop the outline's data source before we let _tree die.
    _outlineView.dataSource = nil;
    _outlineView.delegate = nil;
}

@end
