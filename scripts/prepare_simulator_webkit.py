#!/usr/bin/env python3
"""Expose the selected 18.5 simulator's own Swift WebKit overlay to XCTest.

Xcode 16.4's iOS 18.5 runtime stores the overlay in Cryptexes, outside its default
dyld search paths for apps targeting iOS <18.4 (WebKit bug 293831). XCTest already
searches BUILT_PRODUCTS_DIR. This build-only symlink neither packages a dylib into
the App nor changes its deployment target. Other runtimes are left unchanged.
https://developer.apple.com/forums/thread/785964
"""
import argparse
import json
from pathlib import Path
import sys


def prepare(payload, runtime, products):
    if runtime != "iOS-18-5":
        return False
    matches = [item for item in payload.get("runtimes", [])
               if item.get("identifier", "").endswith("." + runtime)
               and item.get("isAvailable", False)]
    if len(matches) != 1 or not matches[0].get("bundlePath"):
        raise ValueError("Expected one available iOS 18.5 runtime")
    library = (Path(matches[0]["bundlePath"]) / "Contents/Resources/RuntimeRoot"
               / "System/Cryptexes/OS/usr/lib/swift/libswiftWebKit.dylib")
    if not library.is_file():
        raise ValueError("Selected simulator Swift WebKit overlay was not found")
    products = Path(products)
    if not products.is_dir():
        raise ValueError("Build products directory was not found")
    destination = products / library.name
    if destination.is_symlink():
        destination.unlink()
    elif destination.exists():
        raise ValueError("Refusing to replace an existing build product")
    destination.symlink_to(library.resolve())
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--products", required=True)
    args = parser.parse_args()
    try:
        linked = prepare(json.load(sys.stdin), args.runtime, args.products)
    except (ValueError, KeyError, OSError) as error:
        print("Simulator WebKit setup failed: " + str(error), file=sys.stderr)
        sys.exit(1)
    print("Simulator WebKit overlay linked from the selected runtime" if linked
          else "Simulator does not require the iOS 18.5 WebKit workaround")
