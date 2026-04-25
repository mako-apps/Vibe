import MetalKit
import SwiftUI

struct MetalKeyMaskView: UIViewRepresentable {
  let isRevealed: Bool
  let palette: AppThemePalette

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> SecureParticleMaskView {
    let view = SecureParticleMaskView(frame: .zero, device: context.coordinator.device)
    view.delegate = context.coordinator
    view.alpha = isRevealed ? 0 : 1
    return view
  }

  func updateUIView(_ uiView: SecureParticleMaskView, context: Context) {
    UIView.animate(withDuration: 0.35) {
      uiView.alpha = isRevealed ? 0 : 1
    }
  }

  final class Coordinator: NSObject, MTKViewDelegate {
    let device: MTLDevice?

    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private let quadBuffer: MTLBuffer?
    private let particleBuffer: MTLBuffer?
    private let particleCount: Int
    private var startTime = CACurrentMediaTime()

    override init() {
      device = MTLCreateSystemDefaultDevice()
      commandQueue = device?.makeCommandQueue()
      let quadVertices: [SIMD2<Float>] = [
        SIMD2(-1, -1),
        SIMD2(1, -1),
        SIMD2(-1, 1),
        SIMD2(1, 1),
      ]
      let particles = Self.makeParticles()
      particleCount = particles.count
      quadBuffer = device?.makeBuffer(
        bytes: quadVertices,
        length: MemoryLayout<SIMD2<Float>>.stride * quadVertices.count
      )
      particleBuffer = device?.makeBuffer(
        bytes: particles,
        length: MemoryLayout<Particle>.stride * particles.count
      )
      super.init()
      setupPipeline()
    }

    private func setupPipeline() {
      guard let device else { return }

      let shaderSource = """
      #include <metal_stdlib>
      using namespace metal;

      struct Particle {
          float2 basePosition;
          float speed;
          float wobble;
          float size;
          float timeOffset;
          float4 color;
      };

      struct Uniforms {
          float2 viewportSize;
          float time;
          float baseRadius;
      };

      struct VertexOut {
          float4 position [[position]];
          float2 localPoint;
          float4 color;
          float alpha;
      };

      vertex VertexOut vertex_main(
          uint vertexID [[vertex_id]],
          uint instanceID [[instance_id]],
          constant float2 *quadVertices [[buffer(0)]],
          constant Particle *particles [[buffer(1)]],
          constant Uniforms &uniforms [[buffer(2)]]
      ) {
          Particle particle = particles[instanceID];
          float2 quad = quadVertices[vertexID];

          float width = uniforms.viewportSize.x;
          float height = uniforms.viewportSize.y;
          float halfWidth = width * 0.5;
          float halfHeight = height * 0.5;

          float rawX = particle.basePosition.x + (uniforms.time * particle.speed) + particle.timeOffset;
          float wrappedX = fmod(rawX + halfWidth, width);
          if (wrappedX < 0.0) {
              wrappedX += width;
          }
          wrappedX -= halfWidth;

          float waveY = sin((uniforms.time * 2.0) + particle.timeOffset) * particle.wobble;
          float2 center = float2(wrappedX, particle.basePosition.y + waveY);
          float radius = uniforms.baseRadius * particle.size;
          float2 point = center + quad * radius;

          float2 ndc = float2(point.x / halfWidth, point.y / halfHeight);

          VertexOut out;
          out.position = float4(ndc.x, ndc.y, 0.0, 1.0);
          out.localPoint = quad;
          out.color = particle.color;

          float edgeDist = abs(wrappedX) / halfWidth;
          out.alpha = 1.0 - smoothstep(0.8, 1.0, edgeDist);
          return out;
      }

      fragment float4 fragment_main(VertexOut in [[stage_in]]) {
          float dist = length(in.localPoint);
          float circle = 1.0 - smoothstep(0.72, 1.0, dist);
          float alpha = in.color.a * circle * in.alpha;
          return float4(in.color.rgb, alpha);
      }
      """

      do {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
      } catch {
        print("Failed to create particle pipeline: \\(error)")
      }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
      guard
        let drawable = view.currentDrawable,
        let descriptor = view.currentRenderPassDescriptor,
        let pipelineState,
        let commandQueue,
        let quadBuffer,
        let particleBuffer
      else {
        return
      }

      var uniforms = Uniforms(
        viewportSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)),
        time: Float(CACurrentMediaTime() - startTime),
        baseRadius: 1.2
      )

      let commandBuffer = commandQueue.makeCommandBuffer()
      let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: descriptor)
      encoder?.setRenderPipelineState(pipelineState)
      encoder?.setVertexBuffer(quadBuffer, offset: 0, index: 0)
      encoder?.setVertexBuffer(particleBuffer, offset: 0, index: 1)
      encoder?.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
      encoder?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: particleCount)
      encoder?.endEncoding()

      commandBuffer?.present(drawable)
      commandBuffer?.commit()
    }

    private static func makeParticles() -> [Particle] {
      (0..<800).map { _ in
        let rand = Float.random(in: 0...1)
        let yBase = Float.random(in: -1...1)
        let yCluster = (yBase >= 0 ? 1 : -1) * pow(abs(yBase), 2) * 16.0
        let lightness: Float = rand > 0.6 ? 1.0 : Float.random(in: 0.3...0.6)
        let size: Float = rand > 0.8 ? Float.random(in: 1.2...1.8) : Float.random(in: 0.4...0.9)

        return Particle(
          basePosition: SIMD2(Float.random(in: -300...300), yCluster),
          speed: Float.random(in: 5...15),
          wobble: Float.random(in: 0.5...3.0),
          size: size,
          timeOffset: Float.random(in: 0...1000),
          color: SIMD4(lightness, lightness, lightness, 0.9)
        )
      }
    }
  }
}

private struct Particle {
  let basePosition: SIMD2<Float>
  let speed: Float
  let wobble: Float
  let size: Float
  let timeOffset: Float
  let color: SIMD4<Float>
}

private struct Uniforms {
  let viewportSize: SIMD2<Float>
  let time: Float
  let baseRadius: Float
}

final class SecureParticleMaskView: MTKView {
  private let highlightLayer = CAGradientLayer()

  override init(frame: CGRect, device: MTLDevice?) {
    super.init(frame: frame, device: device)

    backgroundColor = UIColor(red: 35 / 255, green: 39 / 255, blue: 47 / 255, alpha: 1)
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    colorPixelFormat = .bgra8Unorm
    framebufferOnly = false
    isOpaque = false
    preferredFramesPerSecond = 60
    enableSetNeedsDisplay = false
    isPaused = false

    layer.cornerRadius = 12
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    layer.borderWidth = 1 / UIScreen.main.scale
    layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor

    highlightLayer.colors = [
      UIColor.white.withAlphaComponent(0.05).cgColor,
      UIColor.clear.cgColor,
    ]
    highlightLayer.locations = [0, 0.35]
    highlightLayer.startPoint = CGPoint(x: 0.5, y: 0)
    highlightLayer.endPoint = CGPoint(x: 0.5, y: 1)
    layer.addSublayer(highlightLayer)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    highlightLayer.frame = bounds
  }
}
