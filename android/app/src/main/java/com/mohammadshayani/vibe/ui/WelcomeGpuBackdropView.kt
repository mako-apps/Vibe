package com.mohammadshayani.vibe.ui

import android.content.Context
import android.graphics.PixelFormat
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.SystemClock
import android.util.AttributeSet
import android.widget.FrameLayout
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

internal class WelcomeGpuBackdropView @JvmOverloads constructor(
  context: Context,
  attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {
  private val renderer = WelcomeGpuBackdropRenderer()
  private val surfaceView =
    GLSurfaceView(context).apply {
      setEGLContextClientVersion(2)
      setEGLConfigChooser(8, 8, 8, 8, 16, 0)
      preserveEGLContextOnPause = true
      holder.setFormat(PixelFormat.RGBA_8888)
      setRenderer(renderer)
      renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
    }

  init {
    addView(
      surfaceView,
      LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.MATCH_PARENT,
      ),
    )
  }

  fun onHostResume() {
    surfaceView.onResume()
  }

  fun onHostPause() {
    surfaceView.onPause()
  }
}

private class WelcomeGpuBackdropRenderer : GLSurfaceView.Renderer {
  private var programHandle = 0
  private var indexHandle = 0
  private var resolutionHandle = 0
  private var timeHandle = 0
  private var viewportWidth = 1
  private var viewportHeight = 1
  private val startedAt = SystemClock.elapsedRealtime()
  
  private val particleCount = 60000
  private var indexBuffer: FloatBuffer? = null

  override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
    // Generate particle indices (0 to 59999)
    val indices = FloatArray(particleCount) { it.toFloat() }
    indexBuffer = ByteBuffer.allocateDirect(particleCount * 4)
      .order(ByteOrder.nativeOrder())
      .asFloatBuffer()
      .apply {
        put(indices)
        position(0)
      }

    programHandle = linkProgram(
      loadShader(GLES20.GL_VERTEX_SHADER, vertexShaderSource),
      loadShader(GLES20.GL_FRAGMENT_SHADER, fragmentShaderSource)
    )
    
    if (programHandle != 0) {
      indexHandle = GLES20.glGetAttribLocation(programHandle, "aIndex")
      resolutionHandle = GLES20.glGetUniformLocation(programHandle, "uResolution")
      timeHandle = GLES20.glGetUniformLocation(programHandle, "uTime")
    }
    
    GLES20.glEnable(GLES20.GL_BLEND)
    GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE)
    GLES20.glClearColor(0.012f, 0.012f, 0.02f, 1f)
  }

  override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
    viewportWidth = width.coerceAtLeast(1)
    viewportHeight = height.coerceAtLeast(1)
    GLES20.glViewport(0, 0, viewportWidth, viewportHeight)
  }

  override fun onDrawFrame(gl: GL10?) {
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    if (programHandle == 0 || indexBuffer == null) return

    GLES20.glUseProgram(programHandle)
    
    indexBuffer!!.position(0)
    GLES20.glEnableVertexAttribArray(indexHandle)
    GLES20.glVertexAttribPointer(indexHandle, 1, GLES20.GL_FLOAT, false, 0, indexBuffer)
    
    GLES20.glUniform2f(resolutionHandle, viewportWidth.toFloat(), viewportHeight.toFloat())
    GLES20.glUniform1f(timeHandle, (SystemClock.elapsedRealtime() - startedAt) / 1000f)

    GLES20.glDrawArrays(GLES20.GL_POINTS, 0, particleCount)
    GLES20.glDisableVertexAttribArray(indexHandle)
  }

  private fun loadShader(type: Int, source: String): Int {
    val shaderHandle = GLES20.glCreateShader(type)
    if (shaderHandle == 0) return 0
    GLES20.glShaderSource(shaderHandle, source)
    GLES20.glCompileShader(shaderHandle)
    val compileStatus = IntArray(1)
    GLES20.glGetShaderiv(shaderHandle, GLES20.GL_COMPILE_STATUS, compileStatus, 0)
    if (compileStatus[0] == 0) {
      GLES20.glDeleteShader(shaderHandle)
      return 0
    }
    return shaderHandle
  }

  private fun linkProgram(vertexShader: Int, fragmentShader: Int): Int {
    if (vertexShader == 0 || fragmentShader == 0) return 0
    val program = GLES20.glCreateProgram()
    if (program == 0) return 0
    GLES20.glAttachShader(program, vertexShader)
    GLES20.glAttachShader(program, fragmentShader)
    GLES20.glLinkProgram(program)
    val linkStatus = IntArray(1)
    GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
    if (linkStatus[0] == 0) {
      GLES20.glDeleteProgram(program)
      return 0
    }
    return program
  }

  companion object {
    private val vertexShaderSource = """
      attribute float aIndex;
      uniform vec2 uResolution;
      uniform float uTime;
      
      varying vec3 vColor;
      varying float vAlpha;

      float hash(float n) {
          float sn = sin(n) * 43758.5453123;
          return fract(sn);
      }

      vec3 hsl2rgb(vec3 c) {
          vec3 rgb = clamp(abs(mod(c.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
          return c.z + c.y * (rgb - 0.5) * (1.0 - abs(2.0 * c.z - 1.0));
      }

      vec3 cubicBezier(vec3 p0, vec3 c0, vec3 c1, vec3 p1, float t) {
          float tn = 1.0 - t;
          return tn * tn * tn * p0 + 3.0 * tn * tn * t * c0 + 3.0 * tn * t * t * c1 + t * t * t * p1;
      }

      void main() {
          float rand1 = hash(aIndex * 12.9898);
          float rand2 = hash(aIndex * 78.233);
          float rand3 = hash(aIndex * 37.719);
          
          float angle = rand1 * 6.2831853;
          float radius = 150.0 + rand2 * 550.0;
          
          vec3 startPos = vec3(0.0, -1400.0, 0.0);
          vec3 endPos = vec3(0.0, 1400.0, 0.0);
          vec3 c1 = vec3(cos(angle) * radius * 1.5, -600.0, sin(angle) * radius * 1.5);
          vec3 c2 = vec3(cos(angle) * radius * 1.5, 600.0, sin(angle) * radius * 1.5);
          
          float duration = 32.0;
          float tProgress = mod((uTime + rand3 * duration), duration) / duration;
          
          vec3 pos = cubicBezier(startPos, c1, c2, endPos, tProgress);
          
          float sysAngle = uTime * 0.05;
          float cosA = cos(sysAngle);
          float sinA = sin(sysAngle);
          float newX = pos.x * cosA - pos.z * sinA;
          float newZ = pos.x * sinA + pos.z * cosA;
          pos.x = newX; pos.z = newZ;
          
          float cameraZ = 1800.0;
          float zDist = cameraZ - pos.z;
          float scale = 1400.0 / zDist;
          
          vec2 screenPos = pos.xy * scale;
          screenPos.x /= (uResolution.x * 0.5);
          screenPos.y /= (uResolution.y * 0.5);
          
          float h = 0.08 + rand1 * 0.04;
          float s = 0.38;
          float l = 0.32;
          
          float tAlpha = smoothstep(0.0, 0.22, tProgress) * smoothstep(1.0, 0.78, tProgress);
          
          gl_Position = vec4(screenPos, 0.0, 1.0);
          gl_PointSize = 18.0 * scale * tAlpha;
          vColor = hsl2rgb(vec3(h, s, l));
          vAlpha = tAlpha;
      }
    """.trimIndent()

    private val fragmentShaderSource = """
      precision highp float;
      varying vec3 vColor;
      varying float vAlpha;

      void main() {
          vec2 coord = gl_PointCoord - vec2(0.5, 0.5);
          float dist = length(coord);
          if (dist > 0.5) discard;
          
          float intensity = 1.0 - (dist * 2.0);
          intensity = intensity * intensity;
          
          float finalAlpha = intensity * vAlpha * 0.40;
          gl_FragColor = vec4(vColor * finalAlpha, finalAlpha);
      }
    """.trimIndent()
  }
}
