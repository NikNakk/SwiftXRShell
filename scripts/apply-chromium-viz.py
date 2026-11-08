#!/usr/bin/env python3
"""Install the temporary, opt-in Viz bridge in the sibling Chromium checkout.
Only named files/anchors are changed; existing WebXR work is preserved.
"""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('chromium', nargs='?', type=Path, default=Path.home() / 'Code/chromium/src')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
chrome = args.chromium / 'chrome/browser'

def insert(path, marker, replacement, sentinel):
    text = path.read_text()
    if sentinel in text:
        return
    if text.count(marker) != 1:
        raise SystemExit(f'Expected one insertion anchor in {path}: {marker!r}')
    path.write_text(text.replace(marker, replacement, 1))

insert(chrome / 'BUILD.gn', '      "chrome_browser_main_mac.mm",',
       '      "chrome_browser_main_mac.mm",\n      "swiftxr_viz_bridge_mac.mm",\n      "swiftxr_viz_bridge_mac.h",\n      "swiftxr_viz_protocol.h",', '"swiftxr_viz_bridge_mac.mm"')
insert(chrome / 'chrome_browser_main_mac.h', 'namespace mac_metrics {',
       'class SwiftXRVizBridgeMac;\n\nnamespace mac_metrics {', 'class SwiftXRVizBridgeMac;')
insert(chrome / 'chrome_browser_main_mac.h', '  void PreProfileInit() override;',
       '  void PreProfileInit() override;\n  void PostBrowserStart() override;\n  void PostMainMessageLoopRun() override;', 'void PostBrowserStart() override;')
insert(chrome / 'chrome_browser_main_mac.h', '  std::unique_ptr<mac_metrics::Metrics> metrics_;',
       '  std::unique_ptr<mac_metrics::Metrics> metrics_;\n  std::unique_ptr<SwiftXRVizBridgeMac> swiftxr_viz_bridge_;', 'swiftxr_viz_bridge_;')
insert(chrome / 'chrome_browser_main_mac.mm', '#include "chrome/browser/chrome_browser_main_mac.h"',
       '#include "chrome/browser/chrome_browser_main_mac.h"\n#include "chrome/browser/swiftxr_viz_bridge_mac.h"', '#include "chrome/browser/swiftxr_viz_bridge_mac.h"')
insert(chrome / 'chrome_browser_main_mac.mm', 'ChromeBrowserMainPartsMac::~ChromeBrowserMainPartsMac() = default;',
       '''ChromeBrowserMainPartsMac::~ChromeBrowserMainPartsMac() = default;

void ChromeBrowserMainPartsMac::PostBrowserStart() {
  ChromeBrowserMainPartsPosix::PostBrowserStart();
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("swiftxr-viz-service"))
    swiftxr_viz_bridge_ = std::make_unique<SwiftXRVizBridgeMac>();
}

void ChromeBrowserMainPartsMac::PostMainMessageLoopRun() {
  swiftxr_viz_bridge_.reset();
  ChromeBrowserMainPartsPosix::PostMainMessageLoopRun();
}''', 'void ChromeBrowserMainPartsMac::PostBrowserStart()')
def copy_if_changed(source, destination):
    data = source.read_bytes()
    if not destination.exists() or destination.read_bytes() != data:
        destination.write_bytes(data)

for name in ('swiftxr_viz_bridge_mac.h', 'swiftxr_viz_bridge_mac.mm'):
    copy_if_changed(root / 'Tools/ChromiumViz' / name, chrome / name)
copy_if_changed(root / 'Sources/CVizBridge/include/SXRVizProtocol.h', chrome / 'swiftxr_viz_protocol.h')
print(f'Installed opt-in SwiftXR Viz bridge in {chrome}')
