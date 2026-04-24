#!/usr/bin/env python3
"""Capture the Nota window (with desktop wallpaper behind it) to a PNG via Quartz."""
import sys
from Quartz import (CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID,
                    CGWindowListCreateImage, kCGWindowImageBestResolution, kCGWindowImageBoundsIgnoreFraming,
                    kCGWindowListOptionOnScreenBelowWindow, kCGWindowListOptionIncludingWindow,
                    CGRectMake, CGRectNull)
from Cocoa import NSBitmapImageRep, NSPNGFileType

out = sys.argv[1]
wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
for w in wins:
    if w.get('kCGWindowOwnerName') == 'Nota':
        b = w.get('kCGWindowBounds', {})
        if (b.get('Width') or 0) < 200:
            continue
        # Capture a region that includes the Nota window plus some margin so the desktop wallpaper
        # is visible through any translucent glass elements.
        margin = 80
        rect = CGRectMake(
            b['X'] - margin,
            b['Y'] - margin,
            b['Width'] + 2 * margin,
            b['Height'] + 2 * margin,
        )
        # Option: all windows on screen at/below Nota, including Nota itself.
        img = CGWindowListCreateImage(
            rect,
            kCGWindowListOptionOnScreenBelowWindow | kCGWindowListOptionIncludingWindow,
            w['kCGWindowNumber'],
            kCGWindowImageBestResolution,
        )
        if img is None:
            continue
        rep = NSBitmapImageRep.alloc().initWithCGImage_(img)
        data = rep.representationUsingType_properties_(NSPNGFileType, None)
        data.writeToFile_atomically_(out, True)
        print(f"saved {out} bounds={b} rect=({rect.origin.x},{rect.origin.y},{rect.size.width},{rect.size.height})")
        sys.exit(0)
print("no Nota window found", file=sys.stderr)
sys.exit(1)
