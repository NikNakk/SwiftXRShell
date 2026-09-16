@preconcurrency import WebKit
import AppKit
import Foundation
import SwiftXR

@MainActor
private final class HiddenYouTubeBrowserWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class YouTubeBrowserController: NSObject {
    static let width: CGFloat = 1440
    static let height: CGFloat = 810

    private static let motionSnapshotInterval: TimeInterval = 1.0 / 45.0
    private static let typingSnapshotInterval: TimeInterval = 1.0 / 30.0
    private static let idleSnapshotInterval: TimeInterval = 1.0 / 12.0
    private static let scrollStepInterval: TimeInterval = 1.0 / 35.0
    private static let continuationWakeInterval: TimeInterval = 1.0 / 8.0
    private static let scrollScale: Double = 900
    private static let maximumScrollStep: Double = 220
    private static let momentumDecay: Double = 0.82

    private let webView: WKWebView
    private let window: HiddenYouTubeBrowserWindow
    private var loaded = false
    private var snapshotPending = false
    private var needsSnapshot = true
    private var lastSnapshot = Date.distantPast
    private var textInputFocused = false
    private var isShutdown = false

    // Controller scrolling keeps the proven GAV-style direct window.scrollBy
    // fallback. Trackpad scrolling bypasses this path entirely and is delivered
    // to WebKit as the original NSEvent so precise deltas, gesture phases and
    // native momentum are preserved.
    private var pendingScrollDistance: Double = 0
    private var scrollMomentum: Double = 0
    private var scrollEvaluationPending = false
    private var lastScrollStep = Date.distantPast
    private var scrollActiveUntil = Date.distantPast
    private var continuationWakePending = false
    private var lastContinuationWake = Date.distantPast

    private weak var transformedApplication: XRMacApplication?
    private var previousEventTransformer: XRMacApplication.EventTransformer?

    var onSnapshot: ((NSImage?) -> Void)?
    var onLaunchURL: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false

        let contentController = WKUserContentController()
        configuration.userContentController = contentController

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            configuration: configuration
        )
        webView.allowsMagnification = false

        window = HiddenYouTubeBrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0.001
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = webView

        let screens = NSScreen.screens
        let minX = screens.map(\.frame.minX).min() ?? 0
        let minY = screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(
            NSPoint(
                x: minX - Self.width - 4096,
                y: minY - Self.height - 4096
            )
        )

        super.init()

        contentController.add(self, name: "swiftXRVR")
        contentController.addUserScript(
            WKUserScript(
                source: Self.injectionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        webView.navigationDelegate = self
        window.orderFrontRegardless()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        uninstallNativeScrollBridge()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "swiftXRVR")
        webView.navigationDelegate = nil
        window.orderOut(nil)
    }

    func open() {
        guard !isShutdown else { return }
        window.orderFrontRegardless()
        installNativeScrollBridge()
        needsSnapshot = true
        onStatus?("Loading YouTube VR…")

        guard !loaded else { return }
        loaded = true
        guard let url = URL(string: "https://www.youtube.com/results?search_query=VR180+8K") else {
            return
        }
        webView.load(URLRequest(url: url))
    }

    func close() {
        textInputFocused = false
        pendingScrollDistance = 0
        scrollMomentum = 0
        scrollActiveUntil = .distantPast
        uninstallNativeScrollBridge()
        window.orderOut(nil)
    }

    func tick() {
        guard !isShutdown else { return }

        let now = Date()
        stepScrollIfNeeded(now: now)

        let scrolling = now < scrollActiveUntil
        if scrolling {
            needsSnapshot = true
            wakeYouTubeContinuationIfNeeded(now: now)
        }

        let interval: TimeInterval
        if scrolling {
            interval = Self.motionSnapshotInterval
        } else if textInputFocused {
            interval = Self.typingSnapshotInterval
        } else {
            interval = Self.idleSnapshotInterval
        }

        guard !snapshotPending else { return }
        guard needsSnapshot || now.timeIntervalSince(lastSnapshot) >= interval else {
            return
        }

        needsSnapshot = false
        snapshotPending = true
        lastSnapshot = now

        webView.takeSnapshot(with: nil) { [weak self] image, error in
            Task { @MainActor in
                guard let self else { return }
                self.snapshotPending = false
                if let image { self.onSnapshot?(image) }
                else if let error {
                    self.onStatus?("YouTube snapshot failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func pointerMoved() {
        if textInputFocused { maintainKeyboardFocus() }
    }

    func click(at normalizedPoint: SIMD2<Float>) {
        guard !isShutdown else { return }
        let u = min(max(Double(normalizedPoint.x), 0), 1)
        let v = min(max(Double(normalizedPoint.y), 0), 1)
        let x = u * Double(Self.width)
        let y = v * Double(Self.height)
        maintainKeyboardFocus()

        let script = """
        (() => {
          const x = \(String(format: "%.1f", x));
          const y = \(String(format: "%.1f", y));
          const deepElementFromPoint = (root, px, py) => {
            let e = root.elementFromPoint ? root.elementFromPoint(px, py) : null;
            const visited = new Set();
            while (e && e.shadowRoot && !visited.has(e)) {
              visited.add(e);
              const inner = e.shadowRoot.elementFromPoint ? e.shadowRoot.elementFromPoint(px, py) : null;
              if (!inner || inner === e) break;
              e = inner;
            }
            return e;
          };
          let e = deepElementFromPoint(document, x, y);
          if (!e) return { kind: 'none', tag: '' };
          let editable = null;
          if (e.matches && e.matches('input, textarea, [contenteditable="true"], [role="textbox"]')) {
            editable = e;
          } else if (e.closest) {
            editable = e.closest('input, textarea, [contenteditable="true"], [role="textbox"]');
          }
          if (editable) {
            try { editable.focus({preventScroll: true}); } catch (_) { editable.focus(); }
            editable.click();
            return { kind: 'editable', tag: (editable.tagName || '').toLowerCase() };
          }
          e.click();
          return { kind: 'click', tag: (e.tagName || '').toLowerCase() };
        })()
        """

        webView.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                self.needsSnapshot = true
                if let result = result as? [String: Any],
                   result["kind"] as? String == "editable" {
                    self.textInputFocused = true
                    self.maintainKeyboardFocus()
                } else {
                    self.textInputFocused = false
                }
            }
        }
    }

    /// Controller/right-stick fallback. Physical trackpad events are intercepted
    /// before SwiftXR reduces them to semantic deltas and are sent through
    /// `handleNativeScroll(_:)` instead.
    func scroll(_ delta: SIMD2<Float>) {
        guard !isShutdown else { return }
        let amount = -Double(delta.y) * Self.scrollScale
        guard abs(amount) > 0.15 else { return }

        pendingScrollDistance = min(max(pendingScrollDistance + amount, -2400), 2400)
        scrollMomentum *= 0.35
        scrollActiveUntil = Date().addingTimeInterval(0.35)
        needsSnapshot = true
        stepScrollIfNeeded(now: Date(), force: true)
    }

    func back() -> Bool {
        guard !isShutdown else { return false }
        textInputFocused = false
        if webView.canGoBack {
            webView.goBack()
            needsSnapshot = true
            return true
        }
        return false
    }

    private func installNativeScrollBridge() {
        guard transformedApplication == nil else { return }
        guard let application = NSApplication.shared as? XRMacApplication else { return }

        let previous = application.swiftXREventTransformer
        transformedApplication = application
        previousEventTransformer = previous

        application.swiftXREventTransformer = { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, !self.isShutdown, event.type == .scrollWheel else {
                    return false
                }
                self.handleNativeScroll(event)
                return true
            }

            if consumed { return nil }
            return previous?(event) ?? event
        }
    }

    private func uninstallNativeScrollBridge() {
        guard let application = transformedApplication else { return }
        application.swiftXREventTransformer = previousEventTransformer
        transformedApplication = nil
        previousEventTransformer = nil
    }

    private func handleNativeScroll(_ event: NSEvent) {
        // Let WebKit consume the real trackpad event. This preserves precise
        // pixel deltas plus phase/momentumPhase, matching ordinary Safari/WKWebView
        // behaviour and allowing YouTube's own scroll/lazy-loading machinery to
        // observe a genuine browser scroll rather than a JS-mutated scrollTop.
        pendingScrollDistance = 0
        scrollMomentum = 0
        webView.scrollWheel(with: event)
        scrollActiveUntil = Date().addingTimeInterval(0.60)
        needsSnapshot = true
    }

    private func wakeYouTubeContinuationIfNeeded(now: Date) {
        guard !continuationWakePending else { return }
        guard now.timeIntervalSince(lastContinuationWake) >= Self.continuationWakeInterval else { return }

        continuationWakePending = true
        lastContinuationWake = now

        // Native wheel scrolling in WebKit can advance the asynchronous scrolling
        // tree before page JavaScript catches up. YouTube loads more results from a
        // ytd-continuation-item-renderer near the end of the document, normally via
        // an intersection observer. Ask the web-content process to evaluate that
        // region periodically while scrolling, and click YouTube's own fallback
        // continuation button if it has chosen to expose one. This deliberately
        // does not change scrollTop, so it cannot fight the smooth native scroll.
        let script = """
        (() => {
          const root = document.scrollingElement || document.documentElement;
          if (!root) return { action: 'no-root' };

          const viewport = Math.max(window.innerHeight || 0, root.clientHeight || 0);
          if (viewport <= 0) return { action: 'no-viewport' };

          const remaining = root.scrollHeight - root.scrollTop - viewport;
          if (remaining > Math.max(900, viewport * 1.25)) {
            return { action: 'far', remaining };
          }

          const continuations = Array.from(document.querySelectorAll('ytd-continuation-item-renderer'));
          for (let i = continuations.length - 1; i >= 0; --i) {
            const continuation = continuations[i];
            const rect = continuation.getBoundingClientRect();
            if (rect.bottom < -64 || rect.top > viewport * 1.5) continue;

            // Ensure any scroll-event-based fallback sees the reconciled layout.
            window.dispatchEvent(new Event('scroll'));
            document.dispatchEvent(new Event('scroll', { bubbles: true }));

            const button = continuation.querySelector(
              'button, tp-yt-paper-button, yt-button-shape button'
            );
            if (button && !button.disabled && button.getClientRects().length > 0) {
              button.click();
              return { action: 'clicked', remaining };
            }

            return { action: 'woke', remaining };
          }

          return { action: 'none', remaining };
        })()
        """

        webView.evaluateJavaScript(script) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.continuationWakePending = false
            }
        }
    }

    private func stepScrollIfNeeded(now: Date, force: Bool = false) {
        guard !scrollEvaluationPending else { return }
        guard force || now.timeIntervalSince(lastScrollStep) >= Self.scrollStepInterval else { return }

        let step: Double
        if abs(pendingScrollDistance) > 0.5 {
            step = min(max(pendingScrollDistance, -Self.maximumScrollStep), Self.maximumScrollStep)
            pendingScrollDistance -= step
            scrollMomentum = step * 0.70
        } else if abs(scrollMomentum) > 0.75 {
            step = scrollMomentum
            scrollMomentum *= Self.momentumDecay
        } else {
            scrollMomentum = 0
            return
        }

        lastScrollStep = now
        scrollActiveUntil = now.addingTimeInterval(0.25)
        scrollEvaluationPending = true

        let script = "window.scrollBy(0, \(String(format: "%.1f", step)));"
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.scrollEvaluationPending = false
                self.needsSnapshot = true
            }
        }
    }

    private func maintainKeyboardFocus() {
        window.orderFrontRegardless()
        if !window.isKeyWindow { window.makeKey() }
        if window.firstResponder !== webView { window.makeFirstResponder(webView) }
    }

    private static let injectionScript = #"""
    (() => {
      const BUTTON_ID = 'swiftxr-psvr2-play-button';
      const STYLE_ID = 'swiftxr-youtube-style';

      const installStyle = () => {
        if (document.getElementById(STYLE_ID)) return;
        const style = document.createElement('style');
        style.id = STYLE_ID;
        style.textContent = `
          html { color-scheme: dark; background: #0f0f0f !important; }
          body { background: #0f0f0f !important; }
          ytd-mini-guide-renderer { display: none !important; }
          ytd-app[mini-guide-visible] ytd-page-manager.ytd-app,
          ytd-app[guide-persistent-and-visible] ytd-page-manager.ytd-app {
            margin-left: 0 !important;
          }
          #guide { display: none !important; }
          ytd-popup-container tp-yt-paper-dialog { max-width: 90vw !important; }
        `;
        document.documentElement.appendChild(style);
      };

      const isPlayableURL = value => {
        try {
          const u = new URL(value, location.href);
          const host = u.hostname.toLowerCase();
          const isYouTube = host === 'youtube.com' || host === 'www.youtube.com' || host.endsWith('.youtube.com');
          if (!isYouTube) return null;
          if (u.pathname === '/watch' && u.searchParams.get('v')) return u.href;
          if (u.pathname.startsWith('/shorts/')) return u.href;
        } catch (_) {}
        return null;
      };

      document.addEventListener('click', ev => {
        const target = ev.target instanceof Element ? ev.target : null;
        const anchor = target ? target.closest('a[href]') : null;
        if (!anchor) return;
        const playable = isPlayableURL(anchor.href);
        if (!playable) return;
        ev.preventDefault();
        ev.stopImmediatePropagation();
        window.webkit.messageHandlers.swiftXRVR.postMessage(playable);
      }, true);

      const install = () => {
        installStyle();
        document.querySelectorAll('video').forEach(v => { v.muted = true; v.pause(); });
        const onVideo = location.pathname === '/watch' || location.pathname.startsWith('/shorts/');
        let button = document.getElementById(BUTTON_ID);
        if (!onVideo) {
          if (button) button.remove();
          return;
        }
        if (!button) {
          button = document.createElement('button');
          button.id = BUTTON_ID;
          button.textContent = '🥽 Play in PSVR2';
          Object.assign(button.style, {
            position: 'fixed', right: '24px', bottom: '24px', zIndex: '2147483647',
            border: '1px solid rgba(255,255,255,.32)', borderRadius: '18px',
            padding: '14px 20px', color: 'white', background: 'rgba(92,107,242,.96)',
            font: '600 16px -apple-system, BlinkMacSystemFont, sans-serif',
            boxShadow: '0 8px 28px rgba(0,0,0,.38)', cursor: 'pointer'
          });
          button.addEventListener('click', ev => {
            ev.preventDefault();
            ev.stopPropagation();
            window.webkit.messageHandlers.swiftXRVR.postMessage(location.href);
          }, true);
          document.documentElement.appendChild(button);
        }
      };

      install();
      new MutationObserver(install).observe(document.documentElement, {subtree:true, childList:true});
      window.addEventListener('yt-navigate-finish', install, true);
      setInterval(install, 1200);
    })();
    """#
}

extension YouTubeBrowserController: WKScriptMessageHandler, WKNavigationDelegate {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "swiftXRVR", let url = message.body as? String else { return }
        onLaunchURL?(url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        needsSnapshot = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        needsSnapshot = true
        onStatus?("YouTube VR")
    }
}
