(() => {
  'use strict';

  const BUTTON_ID = 'swiftxr-webxr-stream-button';
  let xrSession = null;
  let gl = null;
  let program = null;
  let videoTexture = null;
  let vao = null;
  let indexCount = 0;
  let activeVideo = null;
  let projectionMode = 3; // 3 = YouTube/FFmpeg EAC360, 1 = equirectangular 360.
  let shellYielded = false;

  const log = (...args) => console.log('[SwiftXR YouTube WebXR]', ...args);

  async function requestShellHandoff(action) {
    if (!chrome?.runtime?.sendMessage) return false;

    try {
      const response = await chrome.runtime.sendMessage({
        type: 'swiftxr-openxr-handoff',
        action
      });
      if (!response?.ok) {
        throw new Error(response?.error || 'SwiftXR Shell handoff failed');
      }
      return true;
    } catch (error) {
      // The extension is also useful without SwiftXR Shell running. In that
      // case there is simply no cooperative handoff endpoint to contact.
      log('SwiftXR Shell handoff unavailable:', error);
      return false;
    }
  }

  function isWatchPage() {
    return location.pathname === '/watch' && new URL(location.href).searchParams.has('v');
  }

  function currentVideo() {
    const videos = [...document.querySelectorAll('video')];
    return videos.find(v => v.videoWidth > 0 && v.videoHeight > 0) || videos[0] || null;
  }

  function setButtonState(text, error = false) {
    const button = document.getElementById(BUTTON_ID);
    if (!button) return;
    button.textContent = text;
    button.style.background = error ? 'rgba(180,35,35,.96)' : 'rgba(92,107,242,.96)';
  }

  function installButton() {
    if (!isWatchPage() || !navigator.xr) {
      document.getElementById(BUTTON_ID)?.remove();
      return;
    }
    if (document.getElementById(BUTTON_ID)) return;

    const button = document.createElement('button');
    button.id = BUTTON_ID;
    button.textContent = '🥽 Stream in VR';
    Object.assign(button.style, {
      position: 'fixed',
      right: '24px',
      bottom: '24px',
      zIndex: '2147483647',
      border: '1px solid rgba(255,255,255,.32)',
      borderRadius: '18px',
      padding: '14px 20px',
      color: 'white',
      background: 'rgba(92,107,242,.96)',
      font: '600 16px -apple-system, BlinkMacSystemFont, sans-serif',
      boxShadow: '0 8px 28px rgba(0,0,0,.38)',
      cursor: 'pointer'
    });
    button.addEventListener('click', enterXR, true);
    document.documentElement.appendChild(button);
  }

  async function enterXR(event) {
    event.preventDefault();
    event.stopPropagation();

    if (xrSession) {
      await xrSession.end();
      return;
    }

    const video = currentVideo();
    if (!video || !video.videoWidth || !video.videoHeight) {
      setButtonState('No playable video', true);
      return;
    }

    activeVideo = video;
    const aspect = video.videoWidth / Math.max(video.videoHeight, 1);
    // YouTube EAC is normally a 3x2 cubemap atlas (~1.5:1). Conventional
    // monoscopic equirectangular 360 is normally ~2:1.
    projectionMode = aspect > 1.72 ? 1 : 3;

    try {
      setButtonState('Releasing SwiftXR Shell…');
      shellYielded = await requestShellHandoff('yield');

      // xrDestroyInstance is synchronous, but give the runtime one macOS run
      // loop turn to retire compositor ownership before Chromium requests XR.
      if (shellYielded) {
        await new Promise(resolve => setTimeout(resolve, 75));
      }

      setButtonState('Starting VR…');
      xrSession = await navigator.xr.requestSession('immersive-vr', {
        optionalFeatures: ['local-floor']
      });
      xrSession.addEventListener('end', onSessionEnded);

      gl = document.createElement('canvas').getContext('webgl2', {
        alpha: false,
        antialias: false,
        depth: true,
        xrCompatible: true
      });
      if (!gl) throw new Error('WebGL2 unavailable');

      await gl.makeXRCompatible();
      xrSession.updateRenderState({
        baseLayer: new XRWebGLLayer(xrSession, gl, {
          alpha: false,
          antialias: false,
          depth: true,
          stencil: false
        })
      });

      setupRenderer();
      const referenceSpace = await xrSession.requestReferenceSpace('local');
      setButtonState(projectionMode === 3 ? '🥽 Streaming EAC 360' : '🥽 Streaming 360');
      xrSession.requestAnimationFrame((time, frame) => renderXR(time, frame, referenceSpace));
    } catch (error) {
      log(error);
      setButtonState('VR start failed', true);
      xrSession = null;
      if (shellYielded) {
        shellYielded = false;
        await requestShellHandoff('resume');
      }
    }
  }

  function onSessionEnded() {
    xrSession = null;
    gl = null;
    program = null;
    videoTexture = null;
    vao = null;
    indexCount = 0;
    activeVideo = null;
    setButtonState('🥽 Stream in VR');

    if (shellYielded) {
      shellYielded = false;
      requestShellHandoff('resume').catch(log);
    }
  }

  function compileShader(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      throw new Error(gl.getShaderInfoLog(shader) || 'shader compile failed');
    }
    return shader;
  }

  function setupRenderer() {
    const vs = compileShader(gl.VERTEX_SHADER, `#version 300 es
      precision highp float;
      layout(location = 0) in vec3 aPosition;
      uniform mat4 uProjection;
      uniform mat4 uViewRotation;
      out vec3 vDirection;
      void main() {
        vDirection = normalize(aPosition);
        gl_Position = uProjection * uViewRotation * vec4(aPosition * 10.0, 1.0);
      }
    `);

    const fs = compileShader(gl.FRAGMENT_SHADER, `#version 300 es
      precision highp float;
      precision highp int;

      in vec3 vDirection;
      uniform sampler2D uVideo;
      uniform int uProjectionMode;
      uniform vec2 uTextureSize;
      out vec4 outColor;
      const float PI = 3.14159265358979323846;

      vec2 projectEAC(vec3 w) {
        vec3 p = vec3(w.x, -w.y, -w.z);
        float ax = abs(p.x), ay = abs(p.y), az = abs(p.z);
        float uf = 0.0, vf = 0.0;
        int col = 1, row = 0, rotation = 0;

        if (ax >= ay && ax >= az) {
          if (p.x >= 0.0) {
            uf = -p.z / p.x; vf = p.y / p.x; col = 2; row = 0;
          } else {
            uf = -p.z / p.x; vf = -p.y / p.x; col = 0; row = 0;
          }
        } else if (ay >= ax && ay >= az) {
          if (p.y >= 0.0) {
            uf = p.x / p.y; vf = -p.z / p.y; col = 0; row = 1; rotation = 3;
          } else {
            uf = -p.x / p.y; vf = -p.z / p.y; col = 2; row = 1; rotation = 3;
          }
        } else {
          if (p.z >= 0.0) {
            uf = p.x / p.z; vf = p.y / p.z; col = 1; row = 0;
          } else {
            uf = p.x / p.z; vf = -p.y / p.z; col = 1; row = 1; rotation = 1;
          }
        }

        if (rotation == 1) {
          float t = uf; uf = -vf; vf = t;
        } else if (rotation == 3) {
          float t = -uf; uf = vf; vf = t;
        }

        uf = (2.0 / PI) * atan(uf) + 0.5;
        vf = (2.0 / PI) * atan(vf) + 0.5;
        float uPad = 2.0 / max(uTextureSize.x, 1.0);
        float vPad = 2.0 / max(uTextureSize.y, 1.0);
        return vec2(
          (uf + float(col)) * (1.0 - 2.0 * uPad) / 3.0 + uPad,
          vf * (0.5 - 2.0 * vPad) + vPad + 0.5 * float(row)
        );
      }

      vec2 projectEquirect(vec3 w) {
        vec3 d = normalize(w);
        float longitude = atan(d.x, -d.z);
        float latitude = asin(clamp(d.y, -1.0, 1.0));
        return vec2(longitude / (2.0 * PI) + 0.5, 0.5 - latitude / PI);
      }

      void main() {
        vec3 d = normalize(vDirection);
        vec2 uv = uProjectionMode == 3 ? projectEAC(d) : projectEquirect(d);
        outColor = texture(uVideo, uv);
      }
    `);

    program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(program) || 'program link failed');
    }

    const vertices = [];
    const indices = [];
    const latSegments = 48;
    const lonSegments = 96;
    for (let y = 0; y <= latSegments; ++y) {
      const v = y / latSegments;
      const phi = v * Math.PI;
      const sy = Math.cos(phi);
      const sr = Math.sin(phi);
      for (let x = 0; x <= lonSegments; ++x) {
        const u = x / lonSegments;
        const theta = u * Math.PI * 2.0;
        vertices.push(sr * Math.sin(theta), sy, -sr * Math.cos(theta));
      }
    }
    for (let y = 0; y < latSegments; ++y) {
      for (let x = 0; x < lonSegments; ++x) {
        const a = y * (lonSegments + 1) + x;
        const b = a + lonSegments + 1;
        // Reverse winding: camera is inside the sphere.
        indices.push(a, a + 1, b, a + 1, b + 1, b);
      }
    }

    vao = gl.createVertexArray();
    gl.bindVertexArray(vao);

    const vertexBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(vertices), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 0, 0);

    const indexBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint32Array(indices), gl.STATIC_DRAW);
    indexCount = indices.length;

    videoTexture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, videoTexture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.LEQUAL);
    gl.disable(gl.CULL_FACE);
  }

  function rotationOnlyViewMatrix(view) {
    // WebXR matrices are column-major. Keep rotation, discard per-eye/head
    // translation so the video sphere follows orientation but has no parallax.
    const m = new Float32Array(view.transform.inverse.matrix);
    m[12] = 0;
    m[13] = 0;
    m[14] = 0;
    return m;
  }

  function uploadVideoFrame() {
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, videoTexture);
    try {
      gl.texImage2D(
        gl.TEXTURE_2D,
        0,
        gl.RGBA,
        gl.RGBA,
        gl.UNSIGNED_BYTE,
        activeVideo
      );
    } catch (error) {
      throw new Error('Could not upload YouTube video frame: ' + error);
    }
  }

  function renderXR(_time, frame, referenceSpace) {
    if (!xrSession || !gl || !activeVideo) return;
    const pose = frame.getViewerPose(referenceSpace);
    const layer = xrSession.renderState.baseLayer;

    if (pose && activeVideo.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
      try {
        uploadVideoFrame();
      } catch (error) {
        log(error);
        setButtonState('Video texture blocked', true);
        xrSession.end();
        return;
      }

      gl.bindFramebuffer(gl.FRAMEBUFFER, layer.framebuffer);
      gl.clearColor(0, 0, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.useProgram(program);
      gl.bindVertexArray(vao);

      gl.uniform1i(gl.getUniformLocation(program, 'uVideo'), 0);
      gl.uniform1i(gl.getUniformLocation(program, 'uProjectionMode'), projectionMode);
      gl.uniform2f(
        gl.getUniformLocation(program, 'uTextureSize'),
        activeVideo.videoWidth,
        activeVideo.videoHeight
      );

      for (const view of pose.views) {
        const viewport = layer.getViewport(view);
        gl.viewport(viewport.x, viewport.y, viewport.width, viewport.height);
        gl.uniformMatrix4fv(
          gl.getUniformLocation(program, 'uProjection'),
          false,
          view.projectionMatrix
        );
        gl.uniformMatrix4fv(
          gl.getUniformLocation(program, 'uViewRotation'),
          false,
          rotationOnlyViewMatrix(view)
        );
        gl.drawElements(gl.TRIANGLES, indexCount, gl.UNSIGNED_INT, 0);
      }
    }

    xrSession.requestAnimationFrame((time, nextFrame) =>
      renderXR(time, nextFrame, referenceSpace));
  }

  installButton();
  new MutationObserver(installButton).observe(document.documentElement, {
    subtree: true,
    childList: true
  });
  window.addEventListener('yt-navigate-finish', installButton, true);
})();
