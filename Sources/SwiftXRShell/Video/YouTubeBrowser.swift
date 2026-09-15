@preconcurrency import WebKit
import AppKit
import Foundation

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
    private static let scrollScale: Double = 900

    private let webView: WKWebView
    private let window: HiddenYouTubeBrowserWindow
    private var loaded = false
    private var snapshotPending = false
    private var needsSnapshot = true
    private var lastSnapshot = Date.distantPast
    private var textInputFocused = false
    private var isShutdown = false
    private var pendingScrollImpulse: Double = 0
    private var scrollEvaluationPending = false
    private var scrollActiveUntil = Date.distantPast

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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "swiftXRVR")
        webView.navigationDelegate = nil
        window.orderOut(nil)
    }

    func open() {
        guard !isShutdown else { return }
        window.orderFrontRegardless()
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
        pendingScrollImpulse = 0
        scrollActiveUntil = .distantPast
        window.orderOut(nil)
    }

    func tick() {
        guard !isShutdown else { return }
        flushPendingScrollIfNeeded()

        let now = Date()
        let scrolling = now < scrollActiveUntil
        if scrolling {
            needsSnapshot = true
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

    func scroll(_ delta: SIMD2<Float>) {
        guard !isShutdown else { return }
        let amount = -Double(delta.y) * Self.scrollScale
        guard abs(amount) > 0.15 else { return }

        pendingScrollImpulse = min(max(pendingScrollImpulse + amount, -1800), 1800)
        scrollActiveUntil = Date().addingTimeInterval(0.9)
        needsSnapshot = true
        flushPendingScrollIfNeeded()
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

    private func flushPendingScrollIfNeeded() {
        guard !scrollEvaluationPending, abs(pendingScrollImpulse) > 0.5 else { return }
        let impulse = min(max(pendingScrollImpulse, -900), 900)
        pendingScrollImpulse -= impulse
        scrollEvaluationPending = true

        let script = "window.__swiftXRScrollImpulse && window.__swiftXRScrollImpulse(\(String(format: "%.1f", impulse)));"
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.scrollEvaluationPending = false
                self.needsSnapshot = true
                self.flushPendingScrollIfNeeded()
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
      const SCROLL_STATE = '__swiftXRScrollState';

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

      const installSmoothScroll = () => {
        if (window[SCROLL_STATE]) return;
        const state = { velocity: 0, running: true };
        window[SCROLL_STATE] = state;
        window.__swiftXRScrollImpulse = amount => {
          const impulse = Math.max(-900, Math.min(900, Number(amount) || 0));
          state.velocity = Math.max(-72, Math.min(72, state.velocity + impulse * 0.085));
        };
        const frame = () => {
          if (!state.running) return;
          if (Math.abs(state.velocity) > 0.04) {
            const root = document.scrollingElement || document.documentElement;
            if (root) root.scrollTop += state.velocity;
            state.velocity *= 0.885;
            if (Math.abs(state.velocity) < 0.04) state.velocity = 0;
          }
          requestAnimationFrame(frame);
        };
        requestAnimationFrame(frame);
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
        installSmoothScroll();
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
