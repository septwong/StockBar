#import "StatusItemCompatibility.h"

void StockBarInstallStatusItemView(NSStatusItem *statusItem, NSView *view) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    statusItem.view = view;
#pragma clang diagnostic pop
}
