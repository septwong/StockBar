#import <AppKit/AppKit.h>

/// Installs the custom status-item host view used by StockBar's multi-display renderer.
/// The implementation keeps the deprecated AppKit call isolated and warning-free.
FOUNDATION_EXPORT void StockBarInstallStatusItemView(NSStatusItem *statusItem, NSView *view);
