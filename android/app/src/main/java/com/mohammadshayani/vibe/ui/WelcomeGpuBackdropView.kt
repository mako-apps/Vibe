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
  private val renderer = WelcomeGpuBackdropRenderer(isNightMode(context))
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

  fun refreshAppearance() {
    renderer.setDarkTheme(isNightMode(context))
  }
}

private class WelcomeGpuBackdropRenderer(initialDarkTheme: Boolean) : GLSurfaceView.Renderer {
  private val quadVertices: FloatBuffer =
    ByteBuffer.allocateDirect(quadData.size * 4)
      .order(ByteOrder.nativeOrder())
      .asFloatBuffer()
      .apply {
        put(quadData)
        position(0)
      }

  @Volatile
  private var targetDarkTheme = initialDarkTheme

  private var programHandle = 0
  private var positionHandle = 0
  private var resolutionHandle = 0
  private var timeHandle = 0
  private var darkThemeHandle = 0
  private var viewportWidth = 1
  private var viewportHeight = 1
  private val startedAt = SystemClock.elapsedRealtime()

  override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
    programHandle = linkProgram(loadShader(GLES20.GL_VERTEX_SHADER, vertexShaderSource), loadShader(GLES20.GL_FRAGMENT_SHADER, fragmentShaderSource))
    if (programHandle != 0) {
      positionHandle = GLES20.glGetAttribLocation(programHandle, "aPosition")
      resolutionHandle = GLES20.glGetUniformLocation(programHandle, "uResolution")
      timeHandle = GLES20.glGetUniformLocation(programHandle, "uTime")
      darkThemeHandle = GLES20.glGetUniformLocation(programHandle, "uDarkTheme")
    }
    GLES20.glClearColor(0f, 0f, 0f, 1f)
  }

  override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
    viewportWidth = width.coerceAtLeast(1)
    viewportHeight = height.coerceAtLeast(1)
    GLES20.glViewport(0, 0, viewportWidth, viewportHeight)
  }

  override fun onDrawFrame(gl: GL10?) {
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    if (programHandle == 0) return

    GLES20.glUseProgram(programHandle)
    quadVertices.position(0)
    GLES20.glEnableVertexAttribArray(positionHandle)
    GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 0, quadVertices)
    GLES20.glUniform2f(resolutionHandle, viewportWidth.toFloat(), viewportHeight.toFloat())
    GLES20.glUniform1f(timeHandle, (SystemClock.elapsedRealtime() - startedAt) / 1000f)
    GLES20.glUniform1f(darkThemeHandle, if (targetDarkTheme) 1f else 0f)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    GLES20.glDisableVertexAttribArray(positionHandle)
  }

  fun setDarkTheme(isDark: Boolean) {
    targetDarkTheme = isDark
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

    GLES20.glDeleteShader(vertexShader)
    GLES20.glDeleteShader(fragmentShader)
    return program
  }

  companion object {
    private val quadData =
      floatArrayOf(
        -1f, -1f,
        1f, -1f,
        -1f, 1f,
        1f, 1f,
      )

    private val vertexShaderSource =
      """
      attribute vec2 aPosition;

      void main() {
        gl_Position = vec4(aPosition, 0.0, 1.0);
      }
      """.trimIndent()

    private val fragmentShaderSource =
      """
      precision highp float;

      uniform vec2 uResolution;
      uniform float uTime;
      uniform float uDarkTheme;

      float hash(vec2 p) {
        return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
      }

      void main() {
        vec2 uv = gl_FragCoord.xy / uResolution.xy;
        vec2 scaled = (uv - 0.5) * vec2(uResolution.x / max(uResolution.y, 1.0), 1.0);

        vec3 baseTop = mix(vec3(0.955, 0.968, 0.986), vec3(0.030, 0.040, 0.065), uDarkTheme);
        vec3 baseMid = mix(vec3(0.937, 0.949, 0.972), vec3(0.019, 0.025, 0.041), uDarkTheme);
        vec3 baseBottom = mix(vec3(0.914, 0.928, 0.957), vec3(0.008, 0.011, 0.020), uDarkTheme);

        vec3 color = mix(baseTop, baseMid, smoothstep(0.0, 0.54, uv.y));
        color = mix(color, baseBottom, smoothstep(0.46, 1.0, uv.y));

        vec2 lightAnchor = mix(vec2(0.84, 0.18), vec2(0.94, 0.09), uDarkTheme);
        vec2 drift = vec2(cos(uTime * 0.20), sin(uTime * 0.17)) * mix(0.008, 0.013, uDarkTheme);
        vec2 lightPos = lightAnchor + drift;

        float source = smoothstep(mix(0.34, 0.26, uDarkTheme), 0.0, distance(uv, lightPos));
        float halo = smoothstep(mix(0.66, 0.48, uDarkTheme), 0.0, distance(uv, lightPos + vec2(-0.18, 0.14)));
        float beamA = exp(-abs((uv.x - lightPos.x) + (uv.y - lightPos.y) * 1.18) * mix(22.0, 15.0, uDarkTheme));
        float beamB = exp(-abs((uv.x - lightPos.x) + (uv.y - lightPos.y) * 0.52) * mix(32.0, 21.0, uDarkTheme));
        float brushed = 0.5 + 0.5 * sin(((scaled.x * 0.75) - scaled.y) * 52.0 + uTime * 0.75);
        float pulse = 0.72 + 0.28 * sin(uTime * 0.62 + uv.y * 10.0);
        float beam = (beamA * 0.68 + beamB * 0.32) * (0.78 + 0.22 * brushed) * pulse;

        vec3 warm = mix(vec3(0.920, 0.874, 0.760), vec3(0.994, 0.918, 0.698), 0.5 + 0.5 * sin(uTime * 0.22));
        vec3 cool = mix(vec3(0.548, 0.752, 0.938), vec3(0.628, 0.826, 0.996), 0.5 + 0.5 * cos(uTime * 0.28));
        vec3 ambient = mix(vec3(0.526, 0.652, 0.812), vec3(0.198, 0.308, 0.470), uDarkTheme);

        color += source * mix(vec3(0.960, 0.954, 0.928), warm, uDarkTheme) * mix(0.12, 0.44, uDarkTheme);
        color += halo * cool * mix(0.06, 0.18, uDarkTheme);
        color += beam * mix(cool * 0.18, mix(cool, warm, 0.42) * 0.46, uDarkTheme);
        color += exp(-length(scaled + vec2(0.42, -0.24)) * 1.9) * ambient * mix(0.05, 0.14, uDarkTheme);

        float vignette = smoothstep(1.42, 0.18, length(scaled + vec2(-0.08, 0.10)));
        color *= mix(0.84, 1.0, vignette);

        float grain = (hash(gl_FragCoord.xy + vec2(uTime * 64.0, uTime * 19.0)) - 0.5) / 255.0;
        color += grain;

        gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
      }
      """.trimIndent()
  }
}
