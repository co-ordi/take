import CoreImage
import Foundation

/// Everything about the camera bubble you can change, remembered between launches.
/// The popover edits it; the bubble redraws whenever it changes.
@MainActor
final class CameraSettings: ObservableObject {
    static let shared = CameraSettings()
    private var observers: [() -> Void] = []

    /// Called on every change (the bubble and the camera-only recorder both redraw from it).
    func observe(_ handler: @escaping () -> Void) { observers.append(handler) }

    @Published var size: Double { didSet { store(size, "bubbleSize") } }               // 0 small ... 1 large
    @Published var shape: BubbleShape { didSet { store(shape.rawValue, "bubbleShape") } }
    @Published var mirrored: Bool { didSet { store(mirrored, "bubbleMirrored") } }
    @Published var border: Bool { didSet { store(border, "bubbleBorder") } }
    @Published var preset: LookPreset { didSet { store(preset.rawValue, "lookPreset") } }
    @Published var light: Double { didSet { store(light, "lookLight") } }              // -1 ... 1
    @Published var warmth: Double { didSet { store(warmth, "lookWarmth") } }
    @Published var contrast: Double { didSet { store(contrast, "lookContrast") } }

    var look: Look {
        Look(light: light, warmth: warmth, contrast: contrast,
             saturation: preset.saturation, softness: preset.softness)
    }

    /// One tap: the preset's own feel, with the sliders moved to its starting point for fine-tuning.
    func choose(_ preset: LookPreset) {
        self.preset = preset
        light = preset.light
        warmth = preset.warmth
        contrast = preset.contrast
    }

    func resetLook() { choose(.natural) }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "bubbleSize": 0.3, "bubbleShape": BubbleShape.circle.rawValue,
            "bubbleMirrored": true, "bubbleBorder": true,
            "lookPreset": LookPreset.natural.rawValue, "lookLight": 0.0, "lookWarmth": 0.0, "lookContrast": 0.0,
        ])
        size = defaults.double(forKey: "bubbleSize")
        shape = BubbleShape(rawValue: defaults.string(forKey: "bubbleShape") ?? "") ?? .circle
        mirrored = defaults.bool(forKey: "bubbleMirrored")
        border = defaults.bool(forKey: "bubbleBorder")
        preset = LookPreset(rawValue: defaults.string(forKey: "lookPreset") ?? "") ?? .natural
        light = defaults.double(forKey: "lookLight")
        warmth = defaults.double(forKey: "lookWarmth")
        contrast = defaults.double(forKey: "lookContrast")
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        observers.forEach { $0() }
    }
}

enum BubbleShape: String, CaseIterable, Identifiable {
    case circle, roundedSquare, portrait, wide
    var id: Self { self }

    var title: String {
        switch self {
        case .circle: "Circle"
        case .roundedSquare: "Rounded square"
        case .portrait: "Portrait (3:4)"
        case .wide: "Wide (16:9)"
        }
    }

    var symbol: String {
        switch self {
        case .circle: "circle"
        case .roundedSquare: "app"
        case .portrait: "rectangle.portrait"
        case .wide: "rectangle"
        }
    }

    /// The bubble's size in points for a size slider value between 0 and 1.
    func points(for size: Double) -> CGSize {
        let base = 120 + 220 * CGFloat(min(max(size, 0), 1))
        switch self {
        case .circle, .roundedSquare: return CGSize(width: base, height: base)
        case .portrait: return CGSize(width: (base * 0.87).rounded(), height: (base * 0.87 * 4 / 3).rounded())
        case .wide: return CGSize(width: (base * 1.33).rounded(), height: (base * 1.33 * 9 / 16).rounded())
        }
    }

    func cornerRadius(for size: CGSize) -> CGFloat {
        let side = min(size.width, size.height)
        switch self {
        case .circle: return side / 2
        case .roundedSquare: return side * 0.22
        case .portrait, .wide: return side * 0.12
        }
    }
}

enum LookPreset: String, CaseIterable, Identifiable {
    case natural, bright, warm, cool, soft, mono
    var id: Self { self }
    var title: String { rawValue.capitalized }

    /// Where the three sliders start, plus saturation, which only a preset sets.
    private var values: (light: Double, warmth: Double, contrast: Double, saturation: Double) {
        switch self {
        case .natural: (0, 0, 0, 1)
        case .bright: (0.55, 0.05, 0.1, 1.05)
        case .warm: (0.15, 0.5, 0.05, 1.05)
        case .cool: (0.1, -0.45, 0.05, 1)
        case .soft: (0.25, 0.15, -0.3, 0.95)
        case .mono: (0.25, 0, 0.12, 0)
        }
    }

    var light: Double { values.light }
    var warmth: Double { values.warmth }
    var contrast: Double { values.contrast }
    var saturation: Double { values.saturation }
    var softness: Double { self == .soft ? 1 : 0 }
}

/// The filters applied to every camera frame before it's drawn in the bubble (and so recorded).
struct Look: Equatable {
    var light = 0.0, warmth = 0.0, contrast = 0.0, saturation = 1.0, softness = 0.0

    func apply(to input: CIImage) -> CIImage {
        let extent = input.extent
        var image = input

        // Light: lift the shadows, then raise the mid-tones on a curve that keeps white pinned at white,
        // so a dim face brightens without the window behind blowing out.
        if light > 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": light * 0.6])
        }
        if light != 0 {
            let k = CGFloat(light)
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + 0.12 * k),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.12 * k),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.07 * k),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }

        // Warmth: telling Core Image the light was bluer than it was warms the picture, and the other way round.
        if warmth != 0 {
            let neutral = 6500 + warmth * (warmth > 0 ? 3000 : 2000)
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: neutral, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }

        if contrast != 0 || saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + contrast * 0.35,
                kCIInputSaturationKey: saturation,
                kCIInputBrightnessKey: 0,
            ])
        }

        if softness > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 6, kCIInputIntensityKey: 0.3 * softness])
        }

        return image.cropped(to: extent)
    }
}

extension CIImage {
    /// Scales a camera frame to cover `size` completely (cropping the overflow), centred, optionally mirrored.
    func filling(_ size: CGSize, mirrored: Bool) -> CIImage {
        let source = mirrored ? transformed(by: CGAffineTransform(scaleX: -1, y: 1)) : self
        let extent = source.extent
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = CGRect(x: extent.minX * scale, y: extent.minY * scale,
                            width: extent.width * scale, height: extent.height * scale)
        return source.clampedToExtent()            // so the edges stay crisp after scaling
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            .transformed(by: CGAffineTransform(translationX: -scaled.minX - (scaled.width - size.width) / 2,
                                               y: -scaled.minY - (scaled.height - size.height) / 2))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}
