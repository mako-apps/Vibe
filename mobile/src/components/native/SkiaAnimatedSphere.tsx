import React, { useRef, useEffect } from 'react';
import { View, StyleSheet, Dimensions } from 'react-native';
import { WebView } from 'react-native-webview';

// Adjusted size for the list view usage - smaller than full screen
const CANVAS_SIZE = 140;

type VisualizerState = 'idle' | 'searching' | 'connecting' | 'connected' | 'hosting' | 'hosting_active' | 'disconnecting' | 'error';

interface ParticleVisualizerProps {
    state?: VisualizerState;
    voiceAmplitude?: number;
    theme?: 'light' | 'dark';
    primaryColor?: string;
    secondaryColor?: string;
    isVisible?: boolean;
    style?: any;
}

const ParticleVisualizer: React.FC<ParticleVisualizerProps> = ({
    state = 'idle',
    voiceAmplitude = 0,
    theme = 'dark',
    primaryColor = '#22c55e',
    secondaryColor = '#0ea5e9',
    isVisible = true,
    style,
}) => {
    const webViewRef = useRef<WebView>(null);
    const lastUpdateTime = useRef(0);

    useEffect(() => {
        const now = Date.now();
        // Throttle updates but ensure isVisible change is sent immediately if possible (or just throttled is fine 50ms is fast)
        if (now - lastUpdateTime.current < 50) return;
        lastUpdateTime.current = now;

        if (webViewRef.current) {
            // Send updated props to WebView
            const data = JSON.stringify({
                type: 'update',
                state,
                voiceAmplitude,
                theme,
                primaryColor,
                secondaryColor,
                isVisible
            });
            webViewRef.current.postMessage(data);
        }
    }, [state, voiceAmplitude, theme, primaryColor, secondaryColor, isVisible]);

    const htmlContent = `
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <style>
    html, body { 
      margin: 0; 
      padding: 0; 
      width: 100%; 
      height: 100%; 
      background-color: transparent; 
      overflow: hidden;
    }
    canvas { 
      display: block; 
      width: 100%; 
      height: 100%;
    }
  </style>
</head>
<body>
  <canvas id="glCanvas"></canvas>
  <script>
    const canvas = document.getElementById('glCanvas');
    const gl = canvas.getContext('webgl', { 
      alpha: true, 
      antialias: false,
      depth: false,
      stencil: false,
      preserveDrawingBuffer: false,
      powerPreference: 'low-power',
      desynchronized: true
    });

    if (!gl) {
      console.error("WebGL not supported");
    }

    function resize() {
      const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
      const w = window.innerWidth;
      const h = window.innerHeight;
      canvas.width = w * pixelRatio;
      canvas.height = h * pixelRatio;
      gl.viewport(0, 0, canvas.width, canvas.height);
    }
    window.addEventListener('resize', resize);
    resize();

    // Simplex noise function
    const simplex = \`
      vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
      vec4 mod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
      vec4 permute(vec4 x) { return mod289(((x*34.0)+1.0)*x); }
      vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

      float snoise(vec3 v) {
        const vec2 C = vec2(1.0/6.0, 1.0/3.0);
        const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
        vec3 i  = floor(v + dot(v, C.yyy));
        vec3 x0 = v - i + dot(i, C.xxx);
        vec3 g = step(x0.yzx, x0.xyz);
        vec3 l = 1.0 - g;
        vec3 i1 = min(g.xyz, l.zxy);
        vec3 i2 = max(g.xyz, l.zxy);
        vec3 x1 = x0 - i1 + C.xxx;
        vec3 x2 = x0 - i2 + C.yyy;
        vec3 x3 = x0 - D.yyy;
        i = mod289(i);
        vec4 p = permute(permute(permute(
          i.z + vec4(0.0, i1.z, i2.z, 1.0))
          + i.y + vec4(0.0, i1.y, i2.y, 1.0))
          + i.x + vec4(0.0, i1.x, i2.x, 1.0));
        float n_ = 0.142857142857;
        vec3 ns = n_ * D.wyz - D.xzx;
        vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
        vec4 x_ = floor(j * ns.z);
        vec4 y_ = floor(j - 7.0 * x_);
        vec4 x = x_ * ns.x + ns.yyyy;
        vec4 y = y_ * ns.x + ns.yyyy;
        vec4 h = 1.0 - abs(x) - abs(y);
        vec4 b0 = vec4(x.xy, y.xy);
        vec4 b1 = vec4(x.zw, y.zw);
        vec4 s0 = floor(b0)*2.0 + 1.0;
        vec4 s1 = floor(b1)*2.0 + 1.0;
        vec4 sh = -step(h, vec4(0.0));
        vec4 a0 = b0.xzyw + s0.xzyw*sh.xxyy;
        vec4 a1 = b1.xzyw + s1.xzyw*sh.zzww;
        vec3 p0 = vec3(a0.xy,h.x);
        vec3 p1 = vec3(a0.zw,h.y);
        vec3 p2 = vec3(a1.xy,h.z);
        vec3 p3 = vec3(a1.zw,h.w);
        vec4 norm = taylorInvSqrt(vec4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
        p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
        vec4 m = max(0.6 - vec4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
        m = m * m;
        return 42.0 * dot(m*m, vec4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
      }
    \`;

    const vsSource = \`
      attribute vec3 aPos;
      attribute float aPhase;
      attribute float aId;

      uniform float uTime;
      uniform mat4 uRot;
      uniform float uRatio;
      uniform float uSphereSize;
      uniform float uFlowSpeed;
      uniform float uNoiseAmp;
      uniform float uConnect;
      uniform float uAudioReactive;
      uniform float uIsLight;
      uniform float uShape; // 0.0 = Sphere, 1.0 = Ring
      uniform float uScatter; // 0.0 = tight, 1.0 = scattered/breathing
      uniform float uPulse; // 0.0 = no pulse, 1.0 = pulsing

      uniform vec3 uPrimaryColor;
      uniform vec3 uSecondaryColor;

      varying vec3 vColor;
      varying float vAlpha;
      varying float vDepth;

      \${simplex}

      void main() {
        float sphereRadius = 150.0 * uSphereSize;
        vec3 basePos = aPos * sphereRadius;

        // Morph to Horizontal Ring (Torus)
        float ringRadius = sphereRadius * 1.6;
        vec3 ringPos = vec3(
          normalize(aPos.xz).x * ringRadius,
          aPos.y * sphereRadius * 0.12,
          normalize(aPos.xz).y * ringRadius
        );
        ringPos.x += aPos.x * 0.08;
        ringPos.z += aPos.z * 0.08;

        vec3 pos = mix(basePos, ringPos, uShape);

        // Organic noise movement - key to free-flowing dots
        float noiseScale = 0.006;
        float timeScale = uTime * uFlowSpeed * 0.3;

        float n1 = snoise(vec3(pos * noiseScale + timeScale));
        float n2 = snoise(vec3(pos * noiseScale * 1.7 - timeScale * 0.6));
        float n3 = snoise(vec3(pos.yzx * noiseScale * 2.3 + timeScale * 0.4));

        // Per-particle phase offset for individuality
        float phaseOffset = aPhase + aId * 0.37;
        float personalWobble = sin(uTime * 0.8 + phaseOffset) * 0.3;

        float currentNoiseAmp = mix(uNoiseAmp, uNoiseAmp * 0.3, uShape);

        // 3-axis displacement for truly free movement
        vec3 displacement = vec3(
          (n1 + personalWobble) * currentNoiseAmp * 14.0,
          (n2 + sin(uTime * 0.5 + phaseOffset * 2.0) * 0.2) * currentNoiseAmp * 10.0,
          (n3 + cos(uTime * 0.7 + phaseOffset) * 0.15) * currentNoiseAmp * 12.0
        );
        pos += displacement;

        // Scatter: breathing/expanding effect
        float breathe = sin(uTime * 1.2 + aPhase) * 0.5 + 0.5;
        pos += aPos * uScatter * breathe * 20.0;

        // Pulse: rhythmic inward/outward wave
        float pulseWave = sin(uTime * 3.0 + length(aPos.xz) * 4.0) * 0.5 + 0.5;
        pos += aPos * uPulse * pulseWave * 15.0;

        // Audio reactivity
        pos += aPos * uAudioReactive * 18.0;

        // Entry/exit animation
        if (uConnect < 0.99) {
          float progress = smoothstep(0.0, 1.0, uConnect);
          float scatter = (1.0 - progress) * sin(aPhase * 3.0 + uTime * 2.0) * 50.0;
          pos = basePos * (0.05 + 0.95 * progress) + aPos * scatter;
        }

        vec4 rotated = uRot * vec4(pos, 1.0);
        float persp = 550.0 / (550.0 + rotated.z + 550.0);

        gl_Position = vec4(rotated.xy * persp / 280.0, rotated.z / 1000.0, 1.0);

        vDepth = clamp((rotated.z + 180.0) / 360.0, 0.0, 1.0);

        // Variable dot sizes with more variation
        float sizeVariation = 0.5 + 0.8 * (sin(aId * 0.13 + uTime * 0.2) * 0.5 + 0.5);
        float baseSize = 5.0 * sizeVariation;
        float audioBoost = 1.0 + uAudioReactive * 0.4;
        float pulseSize = 1.0 + uPulse * pulseWave * 0.3;
        gl_PointSize = baseSize * persp * uRatio * audioBoost * pulseSize * (0.5 + 0.5 * vDepth);

        // Color mixing with more variation
        float colorMix = 0.5 + 0.5 * aPos.y + n1 * 0.25 + n2 * 0.1;
        vec3 baseColor = mix(uSecondaryColor, uPrimaryColor, clamp(colorMix, 0.0, 1.0));

        // Both themes use additive blending on transparent canvas
        // Light theme: use deeper, more saturated base colors (passed from JS)
        // Dark theme: brighten with subtle shimmer for glow
        float shimmer = sin(uTime * 2.0 + aPhase * 5.0) * 0.06 + 0.06;
        vec3 brightColor = mix(baseColor, vec3(1.0), 0.25 + shimmer);
        vColor = mix(baseColor, brightColor, 0.25);

        vAlpha = (0.45 + 0.55 * vDepth) * uConnect;
      }
    \`.replace('\${simplex}', simplex);

    const fsSource = \`
      precision mediump float;
      varying vec3 vColor;
      varying float vAlpha;
      varying float vDepth;

      void main() {
        vec2 coord = gl_PointCoord - vec2(0.5);
        float dist = length(coord);

        if(dist > 0.5) discard;

        float innerGlow = 1.0 - smoothstep(0.0, 0.22, dist);
        float outerGlow = 1.0 - smoothstep(0.15, 0.5, dist);

        vec3 brightCenter = mix(vec3(1.0, 0.98, 0.96), vColor, smoothstep(0.0, 0.25, dist));
        vec3 finalColor = mix(vColor * 0.85, brightCenter, innerGlow * 0.7);
        finalColor *= (0.8 + 0.2 * vDepth);

        float alpha = (innerGlow * 0.9 + outerGlow * 0.4) * pow(1.0 - dist, 1.2);

        gl_FragColor = vec4(finalColor, alpha * vAlpha);
      }
    \`;

    function buildShader(type, src) {
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
        console.error('Shader error:', gl.getShaderInfoLog(s));
      }
      return s;
    }

    const prog = gl.createProgram();
    gl.attachShader(prog, buildShader(gl.VERTEX_SHADER, vsSource));
    gl.attachShader(prog, buildShader(gl.FRAGMENT_SHADER, fsSource));
    gl.linkProgram(prog);

    // Helper: Hex directly to RGB [0..1]
    function hexToRgb(hex) {
        if (!hex) return [0, 1, 0];
        const bigint = parseInt(hex.replace('#', ''), 16);
        const r = (bigint >> 16) & 255;
        const g = (bigint >> 8) & 255;
        const b = bigint & 255;
        return [r / 255, g / 255, b / 255];
    }

    // Particle data
    const COUNT = 350; // Optimized count for small view
    const data = new Float32Array(COUNT * 5);
    for(let i = 0; i < COUNT; i++) {
      const theta = Math.acos(1 - 2 * (i/COUNT));
      const phi = Math.PI * (1 + Math.sqrt(5)) * i;
      const idx = i * 5;
      data[idx] = Math.sin(theta) * Math.cos(phi);
      data[idx+1] = Math.sin(theta) * Math.sin(phi);
      data[idx+2] = Math.cos(theta);
      data[idx+3] = Math.random() * 6.28;
      data[idx+4] = i;
    }

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);

    const uLocs = {
      time: gl.getUniformLocation(prog, 'uTime'),
      rot: gl.getUniformLocation(prog, 'uRot'),
      ratio: gl.getUniformLocation(prog, 'uRatio'),
      sphereSize: gl.getUniformLocation(prog, 'uSphereSize'),
      flowSpeed: gl.getUniformLocation(prog, 'uFlowSpeed'),
      noiseAmp: gl.getUniformLocation(prog, 'uNoiseAmp'),
      connect: gl.getUniformLocation(prog, 'uConnect'),
      audioReactive: gl.getUniformLocation(prog, 'uAudioReactive'),
      isLight: gl.getUniformLocation(prog, 'uIsLight'),
      shape: gl.getUniformLocation(prog, 'uShape'),
      scatter: gl.getUniformLocation(prog, 'uScatter'),
      pulse: gl.getUniformLocation(prog, 'uPulse'),
      primaryColor: gl.getUniformLocation(prog, 'uPrimaryColor'),
      secondaryColor: gl.getUniformLocation(prog, 'uSecondaryColor'),
    };

    // Initial state matches idle config (horizontal ring)
    let state = {
      t: 0,
      rotY: 0,
      sphereSize: 1.5, targetSphereSize: 1.5,
      flowSpeed: 1.2, targetFlowSpeed: 1.2,
      noiseAmp: 0.9, targetNoiseAmp: 0.9,
      connect: 1, targetConnect: 1,
      audioRaw: 0,
      audioSmooth: 0,
      isLight: 0, targetIsLight: 0,
      rotSpeed: 0.25, targetRotSpeed: 0.25,
      shape: 1.0, targetShape: 1.0,
      scatter: 0.08, targetScatter: 0.08,
      pulse: 0, targetPulse: 0,
      primColor: [0.85, 0.59, 0.04], // Deep amber default
      secColor: [0.86, 0.15, 0.15],  // Deep red default
      isVisible: true,
    };

    // VPN/Connection-optimized state configs
    const CONFIG = {
      // Idle/Disconnected: horizontal ring with flowing movement (like old tool_execution)
      idle:            { sphereSize: 1.5, flowSpeed: 1.2,  noiseAmp: 0.9,  rotSpeed: 0.25, shape: 1.0, scatter: 0.08, pulse: 0.0  },
      // Searching: ring spins faster, more scattered, energetic
      searching:       { sphereSize: 1.4, flowSpeed: 2.2,  noiseAmp: 1.3,  rotSpeed: 0.55, shape: 0.85, scatter: 0.5,  pulse: 0.3  },
      // Connecting: ring tightens into sphere, pulsing as handshake happens
      connecting:      { sphereSize: 1.6, flowSpeed: 1.4,  noiseAmp: 0.8,  rotSpeed: 0.3,  shape: 0.4, scatter: 0.15, pulse: 0.7  },
      // Connected: full sphere, bigger, stable, gentle organic breathing
      connected:       { sphereSize: 2.0, flowSpeed: 0.45, noiseAmp: 0.55, rotSpeed: 0.06, shape: 0.0, scatter: 0.03, pulse: 0.0  },
      // Hosting (relay off): horizontal ring like idle but calmer
      hosting:         { sphereSize: 1.5, flowSpeed: 0.8,  noiseAmp: 0.6,  rotSpeed: 0.15, shape: 1.0, scatter: 0.06, pulse: 0.0  },
      // Hosting active: ring with steady pulse, alive
      hosting_active:  { sphereSize: 1.6, flowSpeed: 1.0,  noiseAmp: 0.7,  rotSpeed: 0.18, shape: 0.7, scatter: 0.08, pulse: 0.2  },
      // Disconnecting: sphere shrinks back to ring
      disconnecting:   { sphereSize: 1.3, flowSpeed: 0.3,  noiseAmp: 0.4,  rotSpeed: 0.03, shape: 0.6, scatter: 0.35, pulse: 0.0  },
      // Error: jittery ring, scattered particles
      error:           { sphereSize: 1.3, flowSpeed: 1.0,  noiseAmp: 1.5,  rotSpeed: 0.03, shape: 0.8, scatter: 0.7,  pulse: 0.5  },
    };

    document.addEventListener('message', handleMsg);
    window.addEventListener('message', handleMsg);

    function handleMsg(e) {
      try {
        const msg = JSON.parse(e.data);
        if (msg.type === 'update') {
          const cfg = CONFIG[msg.state] || CONFIG.idle;
          state.targetSphereSize = cfg.sphereSize;
          state.targetFlowSpeed = cfg.flowSpeed;
          state.targetNoiseAmp = cfg.noiseAmp;
          state.targetConnect = cfg.connect !== undefined ? cfg.connect : 1;
          state.targetRotSpeed = cfg.rotSpeed;
          state.targetShape = cfg.shape !== undefined ? cfg.shape : 0.0;
          state.targetScatter = cfg.scatter !== undefined ? cfg.scatter : 0.0;
          state.targetPulse = cfg.pulse !== undefined ? cfg.pulse : 0.0;

          let amp = typeof msg.voiceAmplitude === 'number' ? msg.voiceAmplitude : 0;
          if (amp < 0.0) {
            const noiseFloor = -60.0;
            const speechFloor = -20.0;
            amp = amp <= noiseFloor ? 0.0 : amp >= speechFloor ? 1.0 : (amp - noiseFloor) / (speechFloor - noiseFloor);
          }
          state.audioRaw = Math.max(0.0, Math.min(1.0, amp));
          state.targetIsLight = msg.theme === 'light' ? 1.0 : 0.0;

          if (msg.primaryColor) state.primColor = hexToRgb(msg.primaryColor);
          if (msg.secondaryColor) state.secColor = hexToRgb(msg.secondaryColor);

          if (msg.isVisible !== undefined) {
             const wasVisible = state.isVisible;
             state.isVisible = msg.isVisible;
             if (!wasVisible && state.isVisible) {
                 requestAnimationFrame(frame);
             }
          }
        }
      } catch(err) {}
    }

    gl.enable(gl.BLEND);
    // Default dark mode: additive blending for glow
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE);

    let lastFrameTime = 0;
    const targetFPS = 60;
    const frameInterval = 1000 / targetFPS;

    function frame(timestamp) {
      if (!state.isVisible) return;

      if (timestamp - lastFrameTime < frameInterval) {
        requestAnimationFrame(frame);
        return;
      }
      const dt = Math.min((timestamp - lastFrameTime) / 16.67, 2.0); // Normalize to ~60fps
      lastFrameTime = timestamp;

      const lerp = (a, b, f) => a + (b - a) * Math.min(f * dt, 1.0);

      // Faster, smoother interpolation
      state.sphereSize = lerp(state.sphereSize, state.targetSphereSize, 0.18);
      state.flowSpeed = lerp(state.flowSpeed, state.targetFlowSpeed, 0.15);
      state.noiseAmp = lerp(state.noiseAmp, state.targetNoiseAmp, 0.15);
      state.connect = lerp(state.connect, state.targetConnect, 0.12);
      state.isLight = lerp(state.isLight, state.targetIsLight, 0.15);
      state.rotSpeed = lerp(state.rotSpeed, state.targetRotSpeed, 0.15);
      state.audioSmooth = lerp(state.audioSmooth, state.audioRaw, 0.15);
      state.shape = lerp(state.shape, state.targetShape, 0.12);
      state.scatter = lerp(state.scatter, state.targetScatter, 0.12);
      state.pulse = lerp(state.pulse, state.targetPulse, 0.14);

      state.t += 0.016 * dt;
      state.rotY += 0.016 * state.rotSpeed * dt;

      // Gentle tilt for 3D feel
      const tiltX = Math.sin(state.t * 0.3) * 0.08;
      const cY = Math.cos(state.rotY);
      const sY = Math.sin(state.rotY);
      const cX = Math.cos(tiltX);
      const sX = Math.sin(tiltX);
      const rotMat = new Float32Array([
        cY,      sX*sY,  cX*sY, 0,
        0,       cX,     -sX,   0,
        -sY,     sX*cY,  cX*cY, 0,
        0,       0,      0,     1
      ]);

      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);

      gl.useProgram(prog);
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);

      const stride = 5 * 4;
      const aPos = gl.getAttribLocation(prog, 'aPos');
      const aPhase = gl.getAttribLocation(prog, 'aPhase');
      const aId = gl.getAttribLocation(prog, 'aId');

      gl.enableVertexAttribArray(aPos);
      gl.vertexAttribPointer(aPos, 3, gl.FLOAT, false, stride, 0);
      gl.enableVertexAttribArray(aPhase);
      gl.vertexAttribPointer(aPhase, 1, gl.FLOAT, false, stride, 12);
      gl.enableVertexAttribArray(aId);
      gl.vertexAttribPointer(aId, 1, gl.FLOAT, false, stride, 16);

      gl.uniform1f(uLocs.time, state.t);
      gl.uniformMatrix4fv(uLocs.rot, false, rotMat);
      gl.uniform1f(uLocs.ratio, Math.min(window.devicePixelRatio || 1, 2));
      gl.uniform1f(uLocs.sphereSize, state.sphereSize);
      gl.uniform1f(uLocs.flowSpeed, state.flowSpeed);
      gl.uniform1f(uLocs.noiseAmp, state.noiseAmp);
      gl.uniform1f(uLocs.connect, state.connect);
      gl.uniform1f(uLocs.audioReactive, state.audioSmooth);
      gl.uniform1f(uLocs.isLight, state.isLight);
      gl.uniform1f(uLocs.shape, state.shape);
      gl.uniform1f(uLocs.scatter, state.scatter);
      gl.uniform1f(uLocs.pulse, state.pulse);

      gl.uniform3fv(uLocs.primaryColor, state.primColor);
      gl.uniform3fv(uLocs.secondaryColor, state.secColor);

      gl.drawArrays(gl.POINTS, 0, COUNT);
      requestAnimationFrame(frame);
    }
    
    requestAnimationFrame(frame);
  </script>
</body>
</html>
  `;

    return (
        <View style={[styles.container, style]}>
            <View style={{ width: CANVAS_SIZE, height: CANVAS_SIZE }}>
                <WebView
                    ref={webViewRef}
                    originWhitelist={['*']}
                    source={{ html: htmlContent }}
                    style={styles.webview}
                    backgroundColor="transparent"
                    showsHorizontalScrollIndicator={false}
                    showsVerticalScrollIndicator={false}
                    javaScriptEnabled={true}
                    scrollEnabled={false}
                    bounces={false}
                    overScrollMode="never"
                />
            </View>
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
    },
    webview: {
        backgroundColor: 'transparent',
        opacity: 0.99, // Fix for some android rendering glitches
    },
});

export default ParticleVisualizer;
