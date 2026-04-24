#!/usr/bin/env python3
"""Capture the Nota window to a PNG via Quartz."""
import sys
from Quartz import (CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID,
                    CGWindowListCreateImage, kCGWindowImageBestResolution, kCGWindowImageBoundsIgnoreFraming,
                    kCGWindowListOptionIncludingWindow, CGRectNull)
from Cocoa import NSBitmapImageRep, NSPNGFileType

out = sys.argv[1]
wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
for w in wins:
    if w.get('kCGWindowOwnerName') == 'Nota':
        b = w.get('kCGWindowBounds', {})
        if (b.get('Width') or 0) < 200:
            continue
        img = CGWindowListCreateImage(
            CGRectNull,
            kCGWindowListOptionIncludingWindow,
            w['kCGWindowNumber'],
            kCGWindowImageBestResolution | kCGWindowImageBoundsIgnoreFraming,
        )
        if img is None:
            continue
        rep = NSBitmapImageRep.alloc().initWithCGImage_(img)
        data = rep.representationUsingType_properties_(NSPNGFileType, None)
        data.writeToFile_atomically_(out, True)
        print(f"saved {out} bounds={b}")
        sys.exit(0)
print("no Nota window found", file=sys.stderr)
sys.exit(1)
