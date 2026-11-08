#ifndef CHROME_BROWSER_SWIFTXR_VIZ_BRIDGE_MAC_H_
#define CHROME_BROWSER_SWIFTXR_VIZ_BRIDGE_MAC_H_
#include <memory>
class SwiftXRVizBridgeMac {
 public:
  SwiftXRVizBridgeMac();
  ~SwiftXRVizBridgeMac();
 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
