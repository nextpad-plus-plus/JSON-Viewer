// JsonSettingsDialog — runs the settings window as a modal. Layout is
// hand-constrained to match the Windows spec (checkbox column on the
// left, three grouped radio buttons on the right).

#import "JsonSettingsDialog.h"

// Persistence helpers (implemented at the bottom of this file to avoid
// introducing a whole new TU).
namespace npj {

std::string settingsPath() {
    NSString *home = NSHomeDirectory();
    NSString *dir  = [home stringByAppendingPathComponent:@".notepad++/plugins/NppJsonViewer"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSString *full = [dir stringByAppendingPathComponent:@"config.json"];
    return std::string([full UTF8String]);
}

Settings loadSettings() {
    Settings s;
    NSString *path = [NSString stringWithUTF8String:settingsPath().c_str()];
    NSData *data   = [NSData dataWithContentsOfFile:path];
    if (!data) return s;

    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!obj || ![obj isKindOfClass:[NSDictionary class]]) return s;
    NSDictionary *d = obj;

    NSNumber *n;
    if ((n = d[@"followCurrentTab"]))    s.followCurrentTab    = [n boolValue];
    if ((n = d[@"autoFormatOnOpen"]))    s.autoFormatOnOpen    = [n boolValue];
    if ((n = d[@"ignoreTrailingComma"])) s.ignoreTrailingComma = [n boolValue];
    if ((n = d[@"ignoreComments"]))      s.ignoreComments      = [n boolValue];
    if ((n = d[@"useJsonHighlight"]))    s.useJsonHighlight    = [n boolValue];
    if ((n = d[@"replaceUndefined"]))    s.replaceUndefined    = [n boolValue];

    if ((n = d[@"indent"]))      s.indent      = static_cast<IndentStyle>([n intValue] & 0xFF);
    if ((n = d[@"indentCount"])) s.indentCount = [n unsignedIntValue];
    if ((n = d[@"eol"]))         s.eol         = static_cast<LineEnding>([n intValue] & 0xFF);
    if ((n = d[@"lineFormat"]))  s.lineFormat  = static_cast<LineFormat>([n intValue] & 0xFF);

    return s;
}

void saveSettings(const Settings& s) {
    NSDictionary *d = @{
        @"followCurrentTab":    @(s.followCurrentTab),
        @"autoFormatOnOpen":    @(s.autoFormatOnOpen),
        @"ignoreTrailingComma": @(s.ignoreTrailingComma),
        @"ignoreComments":      @(s.ignoreComments),
        @"useJsonHighlight":    @(s.useJsonHighlight),
        @"replaceUndefined":    @(s.replaceUndefined),
        @"indent":      @(static_cast<int>(s.indent)),
        @"indentCount": @(s.indentCount),
        @"eol":         @(static_cast<int>(s.eol)),
        @"lineFormat":  @(static_cast<int>(s.lineFormat)),
    };
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data) return;
    NSString *path = [NSString stringWithUTF8String:settingsPath().c_str()];
    [data writeToFile:path atomically:YES];
}

} // namespace npj


// ─────────────────────────────────────────────────────────────────────────
//  Dialog
// ─────────────────────────────────────────────────────────────────────────

// Tag values used on radio-group matrix cells so we can read selection.
static const NSInteger kIndentAuto  = 0;
static const NSInteger kIndentSpace = 1;
static const NSInteger kIndentTab   = 2;

static const NSInteger kEolAuto      = 0;
static const NSInteger kEolWindows   = 1;
static const NSInteger kEolUnix      = 2;
static const NSInteger kEolMacintosh = 3;

static const NSInteger kFmtDefault    = 0;
static const NSInteger kFmtSingleLine = 1;

@interface JsonSettingsDialog () <NSWindowDelegate>
@end

@implementation JsonSettingsDialog {
    NSWindow    *_window;
    npj::Settings *_settingsOut;   // target to write into on OK
    npj::Settings  _current;       // working copy

    // Left-column checkboxes
    NSButton *_cbFollow;
    NSButton *_cbAutoFormat;
    NSButton *_cbIgnoreComma;
    NSButton *_cbIgnoreComments;
    NSButton *_cbUseHighlight;
    NSButton *_cbReplaceUndefined;

    // Indentation radios
    NSButton *_rIndentAuto;
    NSButton *_rIndentSpace;
    NSButton *_rIndentTab;

    // EOL radios
    NSButton *_rEolAuto;
    NSButton *_rEolWindows;
    NSButton *_rEolUnix;
    NSButton *_rEolMac;

    // Line format radios
    NSButton *_rFmtDefault;
    NSButton *_rFmtSingleLine;

    // OK modal result
    BOOL _ok;
}

+ (BOOL)presentWithSettings:(npj::Settings *)settings {
    // Singleton so the window (and its deferred close-animation callbacks
    // on the user-interactive QoS queue) outlives a single call. When the
    // dialog was allocated as a local, ARC released it the moment
    // runModal returned — but AppKit had already queued a
    // _NSWindowTransformAnimation cleanup block onto a background dispatch
    // queue, which then fired objc_msgSend on a freed NSWindow and
    // crashed Notepad++. Reusing one static instance avoids the race.
    static dispatch_once_t once;
    static JsonSettingsDialog *sInstance = nil;
    dispatch_once(&once, ^{
        sInstance = [[JsonSettingsDialog alloc] init];
        [sInstance _buildWindow];
    });

    sInstance->_settingsOut = settings;
    sInstance->_current     = *settings;
    [sInstance _populate];
    return [sInstance _runModal];
}

- (BOOL)_runModal {
    _ok = NO;
    [NSApp runModalForWindow:_window];
    [_window orderOut:nil];
    if (_ok && _settingsOut) {
        [self _readBack];
        *_settingsOut = _current;
        npj::saveSettings(_current);
    }
    return _ok;
}

#pragma mark - UI construction

- (NSButton *)_makeCheckbox:(NSString *)title {
    NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (NSButton *)_makeRadio:(NSString *)title tag:(NSInteger)tag {
    NSButton *b = [NSButton radioButtonWithTitle:title target:self action:@selector(_radioClicked:)];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.tag = tag;
    return b;
}

- (void)_radioClicked:(NSButton *)sender {
    // Manually enforce single-selection per group. NSButton with
    // radioButtonWithTitle: normally handles this when members share a
    // common target+action, but that breaks across group boxes. We
    // inspect sender's superview (the NSBox contentView) and turn off
    // all OTHER NSButtons that share the same target+action.
    NSView *group = sender.superview;
    if (!group) return;
    SEL a = sender.action;
    id  t = sender.target;
    for (NSView *v in group.subviews) {
        if (v == sender) continue;
        if (![v isKindOfClass:[NSButton class]]) continue;
        NSButton *b = (NSButton *)v;
        if (b.target == t && b.action == a) {
            b.state = NSControlStateValueOff;
        }
    }
    sender.state = NSControlStateValueOn;
}

// Build a grouped box with radios laid out in `columns` columns. Radios
// are assigned row-by-row, left-to-right, matching the Windows dialog in
// Image #26. Caller picks column count per group so long labels ("Format
// arrays on a single line") don't get crammed into a narrow column.
//
// `extraWidth` pads the grey box to the right of its natural content
// width WITHOUT moving any radios — implemented via an invisible spacer
// pinned to the top-right of the content view. The content's trailing
// edge extends by exactly `extraWidth` pt.
- (NSView *)_groupBoxWithTitle:(NSString *)title
                         radios:(NSArray<NSButton *> *)radios
                        columns:(NSUInteger)columns
                      extraWidth:(CGFloat)extraWidth {
    NSParameterAssert(columns >= 1);

    NSBox *box = [[NSBox alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.title = title;
    box.boxType = NSBoxPrimary;
    box.titlePosition = NSAtTop;

    NSView *content = box.contentView;

    const CGFloat kRowGap  = 6;
    const CGFloat kColGap  = 28;
    const CGFloat kPadLead = 10;
    const CGFloat kPadTop  = 4;
    const CGFloat kPadBot  = 6;

    NSButton *prevRowLead = nil;     // left-most radio of the previous row, for top anchoring

    for (NSUInteger i = 0; i < radios.count; ++i) {
        NSButton *r = radios[i];
        [content addSubview:r];

        NSUInteger col = i % columns;
        if (col == 0) {
            // New row — anchor leading, place below previous row's leader.
            [r.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:kPadLead].active = YES;
            if (prevRowLead) {
                [r.topAnchor constraintEqualToAnchor:prevRowLead.bottomAnchor constant:kRowGap].active = YES;
            } else {
                [r.topAnchor constraintEqualToAnchor:content.topAnchor constant:kPadTop].active = YES;
            }
            prevRowLead = r;
        } else {
            // Continuation of current row: to the right of the previous radio
            // on the same row, aligned on the Y-axis with it.
            NSButton *leftNeighbor = radios[i - 1];
            [r.leadingAnchor constraintEqualToAnchor:leftNeighbor.trailingAnchor constant:kColGap].active = YES;
            [r.centerYAnchor constraintEqualToAnchor:leftNeighbor.centerYAnchor].active = YES;
        }
    }
    if (prevRowLead) {
        [prevRowLead.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-kPadBot].active = YES;
    }

    // Extra-width spacer: a 1pt-tall invisible view pinned to the leading
    // edge of the topmost-row's rightmost radio, extending `extraWidth`
    // points farther right. Because NSBox's contentView hugs its subviews
    // via constraint solving, the box's natural width grows by exactly
    // `extraWidth` without touching any radio's position.
    if (extraWidth > 0 && radios.count > 0) {
        NSUInteger topRightIdx = MIN((NSUInteger)columns - 1, radios.count - 1);
        NSButton  *topRight    = radios[topRightIdx];

        NSView *spacer = [[NSView alloc] init];
        spacer.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:spacer];
        [NSLayoutConstraint activateConstraints:@[
            [spacer.leadingAnchor  constraintEqualToAnchor:topRight.trailingAnchor],
            [spacer.topAnchor      constraintEqualToAnchor:content.topAnchor constant:kPadTop],
            [spacer.widthAnchor    constraintEqualToConstant:extraWidth],
            [spacer.heightAnchor   constraintEqualToConstant:1],
            // Keep spacer inside content bounds — forces content to grow.
            [spacer.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-kPadLead],
        ]];
    }
    return box;
}

- (void)_buildWindow {
    // 648pt wide (10% narrower than the earlier 720pt) per the updated
    // spec. Right-column grey boxes are widened individually via the
    // extraWidth: argument so they visually dominate the dialog; the
    // left-column checkbox stack takes whatever horizontal space
    // remains.
    NSRect frame = NSMakeRect(0, 0, 648, 420);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title    = @"JSON Viewer Settings";
    _window.delegate = self;
    // Default for initWithContentRect:… is YES, which would let AppKit
    // drop a retain on -close. We reuse this window across invocations
    // as a singleton, so prevent the auto-release.
    _window.releasedWhenClosed = NO;
    [_window center];

    NSView *content = _window.contentView;

    // Left column — checkboxes
    _cbFollow           = [self _makeCheckbox:@"Follow current tab if it is json file"];
    _cbAutoFormat       = [self _makeCheckbox:@"Auto format json file when opened"];
    _cbIgnoreComma      = [self _makeCheckbox:@"Ignore trailing comma"];
    _cbIgnoreComments   = [self _makeCheckbox:@"Ignore comments in json"];
    _cbUseHighlight     = [self _makeCheckbox:@"Use json highlighting"];
    _cbReplaceUndefined = [self _makeCheckbox:@"Replace value 'undefined' with 'null'"];

    NSStackView *left = [[NSStackView alloc] init];
    left.translatesAutoresizingMaskIntoConstraints = NO;
    left.orientation = NSUserInterfaceLayoutOrientationVertical;
    left.alignment   = NSLayoutAttributeLeading;
    left.spacing     = 8;
    [left addArrangedSubview:_cbFollow];
    [left addArrangedSubview:_cbAutoFormat];
    [left addArrangedSubview:_cbIgnoreComma];
    [left addArrangedSubview:_cbIgnoreComments];
    [left addArrangedSubview:_cbUseHighlight];
    [left addArrangedSubview:_cbReplaceUndefined];
    [content addSubview:left];

    // Right column — three grouped boxes, column counts picked per group
    // so long labels never wrap or clip.
    //
    // Indentation (3 items) — 2 columns: [Auto detect | Use tab] / [Use space]
    // matches the Windows layout exactly.
    _rIndentAuto  = [self _makeRadio:@"Auto detect" tag:kIndentAuto];
    _rIndentSpace = [self _makeRadio:@"Use space"   tag:kIndentSpace];
    _rIndentTab   = [self _makeRadio:@"Use tab"     tag:kIndentTab];
    NSView *indentBox = [self _groupBoxWithTitle:@"Indentation:"
                                          radios:@[_rIndentAuto, _rIndentTab, _rIndentSpace]
                                         columns:2
                                      extraWidth:78];

    // Line Ending (4 items) — 2 columns: [Auto detect | Window (CR LF)] /
    // [Unix (LF) | Macintosh (LF)]
    _rEolAuto    = [self _makeRadio:@"Auto detect"     tag:kEolAuto];
    _rEolWindows = [self _makeRadio:@"Window (CR LF)"  tag:kEolWindows];
    _rEolUnix    = [self _makeRadio:@"Unix (LF)"       tag:kEolUnix];
    _rEolMac     = [self _makeRadio:@"Macintosh (LF)"  tag:kEolMacintosh];
    NSView *eolBox = [self _groupBoxWithTitle:@"Line Ending:"
                                       radios:@[_rEolAuto, _rEolWindows, _rEolUnix, _rEolMac]
                                      columns:2
                                   extraWidth:30];

    // Line formatting (2 items) — 1 column: the second label is too long
    // for any side-by-side layout without clipping.
    _rFmtDefault    = [self _makeRadio:@"Default formatting"               tag:kFmtDefault];
    _rFmtSingleLine = [self _makeRadio:@"Format arrays on a single line"   tag:kFmtSingleLine];
    NSView *fmtBox = [self _groupBoxWithTitle:@"Line formatting:"
                                       radios:@[_rFmtDefault, _rFmtSingleLine]
                                      columns:1
                                   extraWidth:140];

    NSStackView *right = [[NSStackView alloc] init];
    right.translatesAutoresizingMaskIntoConstraints = NO;
    right.orientation = NSUserInterfaceLayoutOrientationVertical;
    right.alignment   = NSLayoutAttributeLeading;
    right.spacing     = 10;
    [right addArrangedSubview:indentBox];
    [right addArrangedSubview:eolBox];
    [right addArrangedSubview:fmtBox];
    [content addSubview:right];

    // OK / Cancel — matching the Windows dialog's order (OK on the LEFT,
    // Cancel on the RIGHT). The user explicitly asked for flawless parity
    // with the Windows layout; deviating from the macOS convention here
    // is intentional.
    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(_okClicked:)];
    ok.translatesAutoresizingMaskIntoConstraints = NO;
    ok.keyEquivalent = @"\r";
    [content addSubview:ok];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(_cancelClicked:)];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    cancel.keyEquivalent = @"\e";
    [content addSubview:cancel];

    // Checkbox labels wrap when the column is squeezed (happens when the
    // right-side group boxes are widened via extraWidth: and the overall
    // window width is tighter than the sum of both columns' naturals).
    for (NSButton *cb in @[_cbFollow, _cbAutoFormat, _cbIgnoreComma,
                           _cbIgnoreComments, _cbUseHighlight, _cbReplaceUndefined]) {
        [cb.cell setWraps:YES];
        [cb.cell setLineBreakMode:NSLineBreakByWordWrapping];
    }

    NSLayoutConstraint *leftMaxWidth = [left.widthAnchor constraintLessThanOrEqualToConstant:300];
    leftMaxWidth.priority = NSLayoutPriorityRequired;

    [NSLayoutConstraint activateConstraints:@[
        [left.topAnchor       constraintEqualToAnchor:content.topAnchor constant:18],
        [left.leadingAnchor   constraintEqualToAnchor:content.leadingAnchor constant:20],
        leftMaxWidth,

        [right.topAnchor      constraintEqualToAnchor:content.topAnchor constant:12],
        [right.leadingAnchor  constraintEqualToAnchor:left.trailingAnchor constant:16],
        [right.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],

        // Cancel sits at the trailing edge; OK sits to its LEFT — reversed
        // from the macOS default so the visual matches the Windows dialog.
        [cancel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [cancel.bottomAnchor   constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [ok.trailingAnchor     constraintEqualToAnchor:cancel.leadingAnchor constant:-10],
        [ok.centerYAnchor      constraintEqualToAnchor:cancel.centerYAnchor],
    ]];
}

#pragma mark - Populate / read back

- (void)_populate {
    _cbFollow.state           = _current.followCurrentTab   ? NSControlStateValueOn : NSControlStateValueOff;
    _cbAutoFormat.state       = _current.autoFormatOnOpen   ? NSControlStateValueOn : NSControlStateValueOff;
    _cbIgnoreComma.state      = _current.ignoreTrailingComma ? NSControlStateValueOn : NSControlStateValueOff;
    _cbIgnoreComments.state   = _current.ignoreComments     ? NSControlStateValueOn : NSControlStateValueOff;
    _cbUseHighlight.state     = _current.useJsonHighlight   ? NSControlStateValueOn : NSControlStateValueOff;
    _cbReplaceUndefined.state = _current.replaceUndefined   ? NSControlStateValueOn : NSControlStateValueOff;

    _rIndentAuto.state  = (_current.indent == npj::IndentStyle::Auto)  ? NSControlStateValueOn : NSControlStateValueOff;
    _rIndentSpace.state = (_current.indent == npj::IndentStyle::Space) ? NSControlStateValueOn : NSControlStateValueOff;
    _rIndentTab.state   = (_current.indent == npj::IndentStyle::Tab)   ? NSControlStateValueOn : NSControlStateValueOff;

    _rEolAuto.state    = (_current.eol == npj::LineEnding::Auto)      ? NSControlStateValueOn : NSControlStateValueOff;
    _rEolWindows.state = (_current.eol == npj::LineEnding::Windows)   ? NSControlStateValueOn : NSControlStateValueOff;
    _rEolUnix.state    = (_current.eol == npj::LineEnding::Unix)      ? NSControlStateValueOn : NSControlStateValueOff;
    _rEolMac.state     = (_current.eol == npj::LineEnding::Macintosh) ? NSControlStateValueOn : NSControlStateValueOff;

    _rFmtDefault.state    = (_current.lineFormat == npj::LineFormat::Default)          ? NSControlStateValueOn : NSControlStateValueOff;
    _rFmtSingleLine.state = (_current.lineFormat == npj::LineFormat::SingleLineArrays) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)_readBack {
    _current.followCurrentTab   = (_cbFollow.state           == NSControlStateValueOn);
    _current.autoFormatOnOpen   = (_cbAutoFormat.state       == NSControlStateValueOn);
    _current.ignoreTrailingComma = (_cbIgnoreComma.state     == NSControlStateValueOn);
    _current.ignoreComments     = (_cbIgnoreComments.state   == NSControlStateValueOn);
    _current.useJsonHighlight   = (_cbUseHighlight.state     == NSControlStateValueOn);
    _current.replaceUndefined   = (_cbReplaceUndefined.state == NSControlStateValueOn);

    if (_rIndentTab.state == NSControlStateValueOn)       _current.indent = npj::IndentStyle::Tab;
    else if (_rIndentSpace.state == NSControlStateValueOn) _current.indent = npj::IndentStyle::Space;
    else                                                   _current.indent = npj::IndentStyle::Auto;

    if (_rEolWindows.state == NSControlStateValueOn)       _current.eol = npj::LineEnding::Windows;
    else if (_rEolUnix.state == NSControlStateValueOn)     _current.eol = npj::LineEnding::Unix;
    else if (_rEolMac.state == NSControlStateValueOn)      _current.eol = npj::LineEnding::Macintosh;
    else                                                    _current.eol = npj::LineEnding::Auto;

    _current.lineFormat = (_rFmtSingleLine.state == NSControlStateValueOn)
        ? npj::LineFormat::SingleLineArrays
        : npj::LineFormat::Default;
}

#pragma mark - Actions

- (void)_okClicked:(id)sender {
    _ok = YES;
    [NSApp stopModal];
}
- (void)_cancelClicked:(id)sender {
    _ok = NO;
    [NSApp stopModal];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    _ok = NO;
    [NSApp stopModal];
    return YES;
}

@end
