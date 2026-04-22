// NSWindow controller for the Settings dialog. Mirrors the Windows
// "JSON Viewer Settings" dialog (Image #24): six checkboxes + three radio
// groups + OK/Cancel.

#pragma once

#import <Cocoa/Cocoa.h>
#import "JsonSettings.h"

NS_ASSUME_NONNULL_BEGIN

@interface JsonSettingsDialog : NSObject
// Present modally on top of the main app. Blocks until user clicks OK or
// Cancel. Returns YES if OK was clicked and settings were saved.
+ (BOOL)presentWithSettings:(npj::Settings *)settings;
@end

NS_ASSUME_NONNULL_END
