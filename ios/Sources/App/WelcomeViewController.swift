import MetalKit
import UIKit

final class WelcomeViewController: UIViewController {
  private let backgroundView = WelcomeMetalBackgroundView()
  private let messageLabel = AnimatedRevealLabel()

  private let footerContainerView = UIView()
  private let buttonStack = UIStackView()
  private let signUpButton = UIButton(type: .system)
  private let signInButton = UIButton(type: .system)
  private var footerButtonsBottomConstraint: NSLayoutConstraint?

  private let messages = [
    "Unbreakable Encryption.",
    "Autonomous AI Agents.",
    "Your Private Sanctuary.",
  ]

  private var animationTimer: Timer?

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .lightContent
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureView()
    setupSyncAnimation()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: false)
    backgroundView.isPaused = false
    if animationTimer == nil {
      setupSyncAnimation()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    backgroundView.isPaused = true
    animationTimer?.invalidate()
    animationTimer = nil
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    footerButtonsBottomConstraint?.constant = -(view.safeAreaInsets.bottom + 24)
  }

  private func configureView() {
    // Pure deep dark base canvas
    view.backgroundColor = UIColor(red: 0.012, green: 0.012, blue: 0.02, alpha: 1.0)

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(backgroundView)

    // Centered, Single-Line text
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    messageLabel.font = .systemFont(ofSize: 26, weight: .light)
    messageLabel.textColor = UIColor(white: 0.88, alpha: 1.0)
    messageLabel.numberOfLines = 1  // nowrap
    messageLabel.textAlignment = .center
    messageLabel.adjustsFontSizeToFitWidth = true
    messageLabel.minimumScaleFactor = 0.8
    view.addSubview(messageLabel)
    messageLabel.text = messages[0]

    footerContainerView.translatesAutoresizingMaskIntoConstraints = false
    footerContainerView.clipsToBounds = true
    footerContainerView.backgroundColor = .clear

    signUpButton.translatesAutoresizingMaskIntoConstraints = false
    signUpButton.addTarget(self, action: #selector(handleSignUp), for: .touchUpInside)
    var primary = UIButton.Configuration.filled()
    primary.title = "Create Account"
    primary.cornerStyle = .capsule
    primary.baseBackgroundColor = UIColor(white: 0.95, alpha: 1)
    primary.baseForegroundColor = .black
    signUpButton.configuration = primary

    signInButton.translatesAutoresizingMaskIntoConstraints = false
    signInButton.addTarget(self, action: #selector(handleSignIn), for: .touchUpInside)
    var secondary = UIButton.Configuration.filled()
    secondary.title = "Sign In"
    secondary.cornerStyle = .capsule
    secondary.baseBackgroundColor = UIColor(white: 1.0, alpha: 0.05)
    secondary.baseForegroundColor = UIColor(white: 0.9, alpha: 1)
    secondary.background.strokeColor = UIColor(white: 1.0, alpha: 0.15)
    secondary.background.strokeWidth = 1
    signInButton.configuration = secondary

    buttonStack.translatesAutoresizingMaskIntoConstraints = false
    buttonStack.axis = .vertical
    buttonStack.spacing = 12
    buttonStack.addArrangedSubview(signUpButton)
    buttonStack.addArrangedSubview(signInButton)

    footerContainerView.addSubview(buttonStack)
    view.addSubview(footerContainerView)

    footerButtonsBottomConstraint = buttonStack.bottomAnchor.constraint(
      equalTo: footerContainerView.bottomAnchor,
      constant: -(view.safeAreaInsets.bottom + 24)
    )

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
      messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
      messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),

      footerContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footerContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footerContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      buttonStack.leadingAnchor.constraint(
        equalTo: footerContainerView.leadingAnchor, constant: 32),
      buttonStack.trailingAnchor.constraint(
        equalTo: footerContainerView.trailingAnchor, constant: -32),
      buttonStack.topAnchor.constraint(equalTo: footerContainerView.topAnchor, constant: 22),
      footerButtonsBottomConstraint!,
      signUpButton.heightAnchor.constraint(equalToConstant: 54),
      signInButton.heightAnchor.constraint(equalToConstant: 54),
    ])

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.messageLabel.reveal(duration: 1.2)
    }
  }

  private func setupSyncAnimation() {
    var currentIndex = 0
    animationTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      currentIndex = (currentIndex + 1) % self.messages.count
      self.messageLabel.transition(to: self.messages[currentIndex], duration: 1.2)
    }
  }

  @objc private func handleSignIn() {
    presentAuth(mode: .signIn)
  }

  @objc private func handleSignUp() {
    presentAuth(mode: .signUp)
  }

  private func presentAuth(mode: AuthViewController.Mode) {
    AuthViewController.present(from: self, mode: mode) { [weak self] in
      self?.navigationController?.setNavigationBarHidden(false, animated: false)
      AppRootControllerFactory.showAuthenticatedRoot()
    }
  }
}

// MARK: - Smooth Reveal Label

private final class AnimatedRevealLabel: UILabel {
  override init(frame: CGRect) {
    super.init(frame: frame)
    self.alpha = 0.0
    self.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
  }

  required init?(coder: NSCoder) { nil }

  func reveal(duration: TimeInterval) {
    UIView.animate(withDuration: duration, delay: 0.1, options: [.curveEaseOut]) {
      self.alpha = 1.0
      self.transform = .identity
    }
  }

  func transition(to newText: String, duration: TimeInterval) {
    UIView.animate(
      withDuration: 0.5, delay: 0, options: [.curveEaseIn],
      animations: {
        self.alpha = 0.0
        self.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
      }
    ) { _ in
      self.text = newText
      UIView.animate(withDuration: duration, delay: 0.1, options: [.curveEaseOut]) {
        self.alpha = 1.0
        self.transform = .identity
      }
    }
  }
}

// MARK: - Direct Metal 3D Particle Implementation (Tuned Bronze Torus)

private final class WelcomeMetalBackgroundView: UIView, MTKViewDelegate {
  private var metalView: MTKView!
  private var commandQueue: MTLCommandQueue!
  private var pipelineState: MTLRenderPipelineState!

  private let startedAt = CACurrentMediaTime()
  private let particleCount = 60_000

  var isPaused: Bool {
    get { metalView.isPaused }
    set { metalView.isPaused = newValue }
  }

  private let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    float hash(uint n) {
        n = (n << 13U) ^ n;
        n = n * (n * n * 15731U + 789221U) + 1376312589U;
        return float(n & 0x7fffffffU) / float(0x7fffffff);
    }

    float3 hsl2rgb(float3 c) {
        float3 rgb = clamp(abs(fmod(c.x*6.0+float3(0.0,4.0,2.0),6.0)-3.0)-1.0, 0.0, 1.0);
        return c.z + c.y * (rgb-0.5)*(1.0-abs(2.0*c.z-1.0));
    }

    float3 cubicBezier(float3 p0, float3 c0, float3 c1, float3 p1, float t) {
        float tn = 1.0 - t;
        return tn * tn * tn * p0 + 3.0 * tn * tn * t * c0 + 3.0 * tn * t * t * c1 + t * t * t * p1;
    }

    struct ParticleOut {
        float4 position [[position]];
        float pointSize [[point_size]];
        float3 color;
        float alpha;
    };

    vertex ParticleOut vertex_main(uint vertexID [[vertex_id]],
                                   constant float& uTime [[buffer(0)]],
                                   constant float2& uResolution [[buffer(1)]]) {
        
        float rand1 = hash(vertexID * 3);
        float rand2 = hash(vertexID * 3 + 1);
        float rand3 = hash(vertexID * 3 + 2);
        
        float angle = rand1 * 6.2831853; 
        float radius = 150.0 + rand2 * 550.0; // Scaled slightly to match the 150-700 from ThreeJS
        
        // TALLER HEIGHT matches the tuned HTML (±1400)
        float3 startPos = float3(0.0, -1400.0, 0.0);
        float3 endPos   = float3(0.0, 1400.0, 0.0);
        
        float3 c1 = float3(cos(angle) * radius * 1.5, -600.0, sin(angle) * radius * 1.5);
        float3 c2 = float3(cos(angle) * radius * 1.5,  600.0, sin(angle) * radius * 1.5);
        
        // SLOWER SPEED matches the tuned HTML (32.0s)
        float duration = 32.0;
        float tProgress = fmod((uTime + rand3 * duration), duration) / duration;
        
        float3 pos = cubicBezier(startPos, c1, c2, endPos, tProgress);
        
        // Very slow system rotation to reduce noise
        float sysAngle = uTime * 0.05;
        float cosA = cos(sysAngle);
        float sinA = sin(sysAngle);
        float newX = pos.x * cosA - pos.z * sinA;
        float newZ = pos.x * sinA + pos.z * cosA;
        pos.x = newX; pos.z = newZ;
        
        // Z-axis camera pushback (1800) matches the updated HTML camera position
        float cameraZ = 1800.0;
        float zDist = cameraZ - pos.z;
        float scale = 1400.0 / zDist;
        
        float2 screenPos = pos.xy * scale;
        screenPos.x /= (uResolution.x * 0.5);
        screenPos.y /= (uResolution.y * 0.5);
        
        // REFINED COLORS: Slightly more visible Bronze / Copper
        float h = 0.08 + rand1 * 0.04; 
        float s = 0.38; 
        float l = 0.32; 
        
        float tAlpha = smoothstep(0.0, 0.22, tProgress) * smoothstep(1.0, 0.78, tProgress);
        
        ParticleOut out;
        out.position = float4(screenPos, 0.0, 1.0);
        out.pointSize = 18.0 * scale * tAlpha; 
        out.color = hsl2rgb(float3(h, s, l));
        out.alpha = tAlpha;
        
        return out;
    }

    fragment float4 fragment_main(ParticleOut in [[stage_in]],
                                  float2 pointCoord [[point_coord]]) {
        float dist = length(pointCoord - float2(0.5, 0.5));
        if (dist > 0.5) { discard_fragment(); }
        
        float intensity = 1.0 - (dist * 2.0);
        intensity = intensity * intensity; 
        
        // REFINED CONTRAST: 0.40 multiplier for a subtle but visible blended effect
        float finalAlpha = intensity * in.alpha * 0.40; 
        
        return float4(in.color * finalAlpha, finalAlpha);
    }
    """

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupMetal()
  }

  required init?(coder: NSCoder) { nil }

  private func setupMetal() {
    guard let device = MTLCreateSystemDefaultDevice() else { return }

    metalView = MTKView(frame: bounds, device: device)
    metalView.delegate = self
    metalView.framebufferOnly = true
    metalView.colorPixelFormat = .bgra8Unorm
    metalView.preferredFramesPerSecond = 60
    metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    metalView.clearColor = MTLClearColor(red: 0.012, green: 0.012, blue: 0.02, alpha: 1.0)
    metalView.isPaused = false
    addSubview(metalView)

    commandQueue = device.makeCommandQueue()

    do {
      let library = try device.makeLibrary(source: shaderSource, options: nil)
      let vertexFunction = library.makeFunction(name: "vertex_main")
      let fragmentFunction = library.makeFunction(name: "fragment_main")

      let pipelineDescriptor = MTLRenderPipelineDescriptor()
      pipelineDescriptor.vertexFunction = vertexFunction
      pipelineDescriptor.fragmentFunction = fragmentFunction

      if let attachment = pipelineDescriptor.colorAttachments[0] {
        attachment.pixelFormat = metalView.colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
      }

      pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    } catch {
      print("Failed to compile custom Metal shader: \(error)")
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
      let renderPassDescriptor = view.currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
      let pipelineState = pipelineState
    else {
      return
    }

    var time = Float(CACurrentMediaTime() - startedAt)
    var resolution = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))

    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setVertexBytes(&time, length: MemoryLayout<Float>.size, index: 0)
    renderEncoder.setVertexBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

    renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
