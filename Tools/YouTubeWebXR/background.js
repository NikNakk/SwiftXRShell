'use strict';

const HANDOFF_BASE = 'http://127.0.0.1:49375';

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || message.type !== 'swiftxr-openxr-handoff') {
    return false;
  }

  const action = message.action;
  if (action !== 'yield' && action !== 'resume') {
    sendResponse({ok: false, error: 'invalid handoff action'});
    return false;
  }

  fetch(`${HANDOFF_BASE}/${action}`, {
    method: 'POST',
    headers: {
      'X-SwiftXR-Handoff': '1'
    },
    cache: 'no-store'
  })
    .then(async response => {
      const body = await response.text();
      if (!response.ok) {
        throw new Error(body || `handoff HTTP ${response.status}`);
      }
      sendResponse({ok: true});
    })
    .catch(error => {
      sendResponse({ok: false, error: String(error)});
    });

  return true;
});
