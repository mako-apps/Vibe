import { useEffect, useRef } from 'react';

/**
 * ContourField — a living topographic map rendered as a full-surface GLSL shader.
 *
 * Domain-warped FBM iso-contours drift like territory being redrawn; the field
 * bends around the pointer and slides/rotates with scroll depth. Teal→violet
 * spectral lines over obsidian, with film grain and vignette baked in.
 *
 * Pauses off-screen / hidden tab, renders a single static frame under
 * prefers-reduced-motion, caps DPR, and survives context loss.
 */

const VERT = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`;

const FRAG = `
#ifdef GL_OES_standard_derivatives
#extension GL_OES_standard_derivatives : enable
#endif
precision highp float;

uniform vec2  uRes;
uniform float uTime;
uniform vec2  uPointer;   // pixels, gl-space (y up)
uniform float uScroll;    // scrollY / viewport height
uniform float uIntensity;
uniform float uSeed;

float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(hash(i),                 hash(i + vec2(1.0, 0.0)), u.x),
    mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
    u.y
  );
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 r = mat2(0.8, -0.6, 0.6, 0.8);
  for (int i = 0; i < 5; i++) {
    v += a * vnoise(p);
    p = r * p * 2.03 + 11.5;
    a *= 0.55;
  }
  return v;
}

void main() {
  vec2 frag = gl_FragCoord.xy;
  vec2 uv0 = (frag - 0.5 * uRes) / uRes.y;
  vec2 uv = uv0;
  float t = uTime * 0.05;

  // Depth: the map slides and tilts as you descend the page.
  uv.y += uScroll * 0.25;
  float rr = uScroll * 0.06;
  float cs = cos(rr), sn = sin(rr);
  uv = mat2(cs, -sn, sn, cs) * uv;

  // Pointer lens: territory bends around your presence.
  vec2 pp = (uPointer - 0.5 * uRes) / uRes.y;
  vec2 dp = uv0 - pp;
  float lens = exp(-dot(dp, dp) * 10.0);
  uv -= dp * lens * 0.14;

  // Domain warp → contour field.
  vec2 q = vec2(
    fbm(uv * 1.35 + vec2(0.0, t) + uSeed),
    fbm(uv * 1.35 + vec2(5.2, 1.3) - t + uSeed)
  );
  float f = fbm(uv * 1.35 + 0.9 * q + vec2(t * 0.5, -t * 0.35));

  // Iso-lines with derivative-based AA.
  float levels = 24.0;
  float fl = f * levels;
  float band = abs(fract(fl) - 0.5);
#ifdef GL_OES_standard_derivatives
  float aa = fwidth(fl) * 0.9 + 0.004;
#else
  float aa = 0.05;
#endif
  float line = 1.0 - smoothstep(0.03, 0.03 + aa, band);

  // Every 6th contour reads as a "major" ridge.
  float bandM = abs(fract(fl / 6.0) - 0.5);
  float major = 1.0 - smoothstep(0.006, 0.006 + aa / 6.0 + 0.002, bandM);

  // Luminance travels along the lines like signal.
  float shimmer = 0.40 + 0.60 * vnoise(uv * 6.0 + vec2(t * 3.0, -t * 2.0));

  vec3 bg     = vec3(0.012, 0.024, 0.022);
  vec3 teal   = vec3(0.35, 0.85, 0.80);
  vec3 violet = vec3(0.58, 0.50, 1.00);
  float hue = smoothstep(0.15, 0.90, f + 0.25 * q.y);
  vec3 lc = mix(teal, violet, hue);

  vec3 col = bg;
  col += lc * line * shimmer * (0.30 * uIntensity);
  col += lc * pow(line * shimmer, 3.0) * 0.35 * uIntensity;
  col += lc * major * (0.10 * uIntensity);
  col += teal * lens * 0.06 * uIntensity;

  float vig = smoothstep(1.35, 0.30, length(uv0));
  col *= mix(0.72, 1.0, vig);

  float g = hash(frag + fract(uTime) * 100.0);
  col += (g - 0.5) * 0.03;

  gl_FragColor = vec4(col, 1.0);
}
`;

interface ContourFieldProps {
  /** 1 = hero strength, lower for ambient surfaces (auth uses ~0.55). */
  intensity?: number;
  seed?: number;
  className?: string;
}

export const ContourField = ({ intensity = 1, seed = 0, className }: ContourFieldProps) => {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const intensityRef = useRef(intensity);
  intensityRef.current = intensity;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const gl = canvas.getContext('webgl', {
      antialias: false,
      alpha: false,
      depth: false,
      stencil: false,
      powerPreference: 'high-performance',
    }) as WebGLRenderingContext | null;

    if (!gl) {
      // No WebGL: quiet spectral gradient so the page still reads.
      canvas.style.background =
        'radial-gradient(120% 90% at 20% 10%, #0c1a18 0%, #050807 55%, #0a0a14 100%)';
      return;
    }

    gl.getExtension('OES_standard_derivatives');

    let program: WebGLProgram | null = null;
    let uni: Record<string, WebGLUniformLocation | null> = {};
    let raf = 0;
    let running = false;
    let inView = true;
    let destroyed = false;
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    const pointer = { x: 0, y: 0, tx: 0, ty: 0, has: false };
    let scroll = 0;
    const start = performance.now();

    const compile = (type: number, src: string) => {
      const sh = gl.createShader(type);
      if (!sh) return null;
      gl.shaderSource(sh, src);
      gl.compileShader(sh);
      if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
        console.warn('[ContourField] shader:', gl.getShaderInfoLog(sh));
        gl.deleteShader(sh);
        return null;
      }
      return sh;
    };

    const init = () => {
      const vs = compile(gl.VERTEX_SHADER, VERT);
      const fs = compile(gl.FRAGMENT_SHADER, FRAG);
      if (!vs || !fs) return false;
      program = gl.createProgram();
      if (!program) return false;
      gl.attachShader(program, vs);
      gl.attachShader(program, fs);
      gl.linkProgram(program);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        console.warn('[ContourField] link:', gl.getProgramInfoLog(program));
        return false;
      }
      gl.useProgram(program);

      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      // Fullscreen triangle.
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const loc = gl.getAttribLocation(program, 'aPos');
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

      uni = {};
      for (const name of ['uRes', 'uTime', 'uPointer', 'uScroll', 'uIntensity', 'uSeed']) {
        uni[name] = gl.getUniformLocation(program, name);
      }
      return true;
    };

    if (!init()) return;

    const dprCap = () => Math.min(window.devicePixelRatio || 1, 1.75);

    const resize = () => {
      const dpr = dprCap();
      const w = canvas.clientWidth;
      const h = canvas.clientHeight;
      if (w === 0 || h === 0) return;
      const pw = Math.round(w * dpr);
      const ph = Math.round(h * dpr);
      if (canvas.width !== pw || canvas.height !== ph) {
        canvas.width = pw;
        canvas.height = ph;
        gl.viewport(0, 0, pw, ph);
      }
      if (reduced) draw(start + 9000);
    };

    const draw = (now: number) => {
      if (!program) return;
      const dpr = dprCap();
      const time = (now - start) / 1000;

      // Ease pointer + scroll so the field feels liquid, not twitchy.
      pointer.x += (pointer.tx - pointer.x) * 0.06;
      pointer.y += (pointer.ty - pointer.y) * 0.06;
      const targetScroll = window.scrollY / Math.max(window.innerHeight, 1);
      scroll += (targetScroll - scroll) * 0.08;

      gl.uniform2f(uni.uRes, canvas.width, canvas.height);
      gl.uniform1f(uni.uTime, time);
      gl.uniform2f(
        uni.uPointer,
        pointer.has ? pointer.x * dpr : canvas.width * 0.68,
        pointer.has ? canvas.height - pointer.y * dpr : canvas.height * 0.6
      );
      gl.uniform1f(uni.uScroll, scroll);
      gl.uniform1f(uni.uIntensity, intensityRef.current);
      gl.uniform1f(uni.uSeed, seed);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    };

    const loop = (now: number) => {
      if (!running) return;
      draw(now);
      raf = requestAnimationFrame(loop);
    };

    const syncRunning = () => {
      const should = inView && !document.hidden && !reduced && !destroyed;
      if (should && !running) {
        running = true;
        raf = requestAnimationFrame(loop);
      } else if (!should && running) {
        running = false;
        cancelAnimationFrame(raf);
      }
    };

    const onPointer = (e: PointerEvent) => {
      const r = canvas.getBoundingClientRect();
      pointer.tx = e.clientX - r.left;
      pointer.ty = e.clientY - r.top;
      if (!pointer.has) {
        pointer.x = pointer.tx;
        pointer.y = pointer.ty;
        pointer.has = true;
      }
    };

    const onVisibility = () => syncRunning();
    const io = new IntersectionObserver((entries) => {
      inView = entries[0]?.isIntersecting ?? true;
      syncRunning();
    });
    io.observe(canvas);

    const ro = new ResizeObserver(resize);
    ro.observe(canvas);
    resize();

    const onLost = (e: Event) => {
      e.preventDefault();
      running = false;
      cancelAnimationFrame(raf);
    };
    const onRestored = () => {
      if (init()) {
        resize();
        syncRunning();
      }
    };

    window.addEventListener('pointermove', onPointer, { passive: true });
    document.addEventListener('visibilitychange', onVisibility);
    canvas.addEventListener('webglcontextlost', onLost);
    canvas.addEventListener('webglcontextrestored', onRestored);

    syncRunning();
    if (reduced) draw(start + 9000);

    return () => {
      destroyed = true;
      running = false;
      cancelAnimationFrame(raf);
      io.disconnect();
      ro.disconnect();
      window.removeEventListener('pointermove', onPointer);
      document.removeEventListener('visibilitychange', onVisibility);
      canvas.removeEventListener('webglcontextlost', onLost);
      canvas.removeEventListener('webglcontextrestored', onRestored);
      const ext = gl.getExtension('WEBGL_lose_context');
      ext?.loseContext();
    };
  }, [seed]);

  return <canvas ref={canvasRef} className={className} aria-hidden="true" />;
};

export default ContourField;
