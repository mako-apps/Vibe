package com.mohammadshayani.vibe.ui

import android.content.Context
import android.graphics.PixelFormat
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.SystemClock
import android.util.AttributeSet
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

class GlKeyMaskView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : GLSurfaceView(context, attrs) {

    private val renderer: GlKeyMaskRenderer

    init {
        setEGLContextClientVersion(2)
        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        holder.setFormat(PixelFormat.TRANSLUCENT)
        setZOrderOnTop(true)
        renderer = GlKeyMaskRenderer()
        setRenderer(renderer)
        renderMode = RENDERMODE_CONTINUOUSLY
    }

    private class GlKeyMaskRenderer : Renderer {
        private val quadVertices: FloatBuffer = ByteBuffer.allocateDirect(quadData.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(quadData)
                position(0)
            }

        private var programHandle = 0
        private var positionHandle = 0
        private var timeHandle = 0
        private val startedAt = SystemClock.elapsedRealtime()

        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            programHandle = linkProgram(
                loadShader(GLES20.GL_VERTEX_SHADER, vertexShaderSource),
                loadShader(GLES20.GL_FRAGMENT_SHADER, fragmentShaderSource)
            )
            if (programHandle != 0) {
                positionHandle = GLES20.glGetAttribLocation(programHandle, "aPosition")
                timeHandle = GLES20.glGetUniformLocation(programHandle, "uTime")
            }
            GLES20.glClearColor(0f, 0f, 0f, 0f)
        }

        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
            GLES20.glViewport(0, 0, width, height)
        }

        override fun onDrawFrame(gl: GL10?) {
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            if (programHandle == 0) return

            GLES20.glUseProgram(programHandle)
            quadVertices.position(0)
            GLES20.glEnableVertexAttribArray(positionHandle)
            GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 0, quadVertices)
            GLES20.glUniform1f(timeHandle, (SystemClock.elapsedRealtime() - startedAt) / 1000f)

            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(positionHandle)
        }

        private fun loadShader(type: Int, source: String): Int {
            val shaderHandle = GLES20.glCreateShader(type)
            if (shaderHandle != 0) {
                GLES20.glShaderSource(shaderHandle, source)
                GLES20.glCompileShader(shaderHandle)
                val compileStatus = IntArray(1)
                GLES20.glGetShaderiv(shaderHandle, GLES20.GL_COMPILE_STATUS, compileStatus, 0)
                if (compileStatus[0] == 0) {
                    GLES20.glDeleteShader(shaderHandle)
                    return 0
                }
            }
            return shaderHandle
        }

        private fun linkProgram(vertexShader: Int, fragmentShader: Int): Int {
            if (vertexShader == 0 || fragmentShader == 0) return 0
            val program = GLES20.glCreateProgram()
            if (program != 0) {
                GLES20.glAttachShader(program, vertexShader)
                GLES20.glAttachShader(program, fragmentShader)
                GLES20.glLinkProgram(program)
                val linkStatus = IntArray(1)
                GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
                if (linkStatus[0] == 0) {
                    GLES20.glDeleteProgram(program)
                    return 0
                }
            }
            return program
        }

        companion object {
            private val quadData = floatArrayOf(
                -1f, -1f,
                1f, -1f,
                -1f, 1f,
                1f, 1f
            )

            private val vertexShaderSource = """
                attribute vec4 aPosition;
                varying vec2 vUv;
                void main() {
                    gl_Position = aPosition;
                    vUv = aPosition.xy * 0.5 + 0.5;
                }
            """.trimIndent()

            private val fragmentShaderSource = """
                precision highp float;
                varying vec2 vUv;
                uniform float uTime;

                float hash(vec2 p) {
                    p = fract(p * vec2(123.34, 456.21));
                    p += dot(p, p + 45.32);
                    return fract(p.x * p.y);
                }

                void main() {
                    float n = hash(vUv + uTime);
                    float blocks = hash(floor(vUv * vec2(20.0, 50.0)) + uTime * 0.1);
                    float glitch = step(0.98, hash(vec2(uTime, floor(vUv.y * 10.0))));
                    
                    vec3 color = vec3(0.08, 0.08, 0.1); 
                    if (n > 0.5) {
                        color += vec3(0.1, 0.08, 0.15) * blocks;
                    }
                    if (glitch > 0.0) {
                        color += vec3(0.2, 0.15, 0.3);
                    }
                    gl_FragColor = vec4(color, 1.0);
                }
            """.trimIndent()
        }
    }
}
