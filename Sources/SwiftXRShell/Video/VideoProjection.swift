import CoreGraphics
import Foundation
import simd
import SwiftXR

enum VideoProjectionMode: Int32, CaseIterable, CustomStringConvertible {
    case flat = 0
    case vr180Equirect = 1
    case vr180Fisheye = 2
    case eac360 = 3

    var description: String {
        switch self {
        case .flat: return "flat virtual screen"
        case .vr180Equirect: return "VR180 half-equirectangular"
        case .vr180Fisheye: return "VR180 equidistant fisheye"
        case .eac360: return "YouTube/FFmpeg EAC 360"
        }
    }

    static func resolve(inputPath: String, youtubeEACHint: Bool) -> VideoProjectionMode {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["SWIFTXR_VIDEO_PROJECTION"]
            ?? environment["GAV_MONADO_PROJECTION"]

        if let value = value?.lowercased(), !value.isEmpty {
            switch value {
            case "flat", "screen", "2d": return .flat
            case "vr180", "180", "equirect", "equirect180": return .vr180Equirect
            case "fisheye", "vr180-fisheye": return .vr180Fisheye
            case "eac", "eac360", "youtube360", "360": return .eac360
            default:
                fputs("swiftxr-shell: unknown projection '\(value)'; using automatic detection\n", stderr)
            }
        }

        let name = URL(fileURLWithPath: inputPath).lastPathComponent.lowercased()
        if youtubeEACHint || name.contains("eac360") ||
            (name.contains("360") && !name.contains("180")) {
            return .eac360
        }
        if name.contains("fisheye") { return .vr180Fisheye }
        if name.contains("vr180") || name.contains("180") || name.contains("sbs") ||
            name.contains("topbottom") || name.contains("overunder") {
            return .vr180Equirect
        }
        return .flat
    }
}

enum VideoStereoLayout: Int32, CaseIterable, CustomStringConvertible {
    case mono = 0
    case sideBySide = 1
    case topBottom = 2

    var description: String {
        switch self {
        case .mono: return "mono"
        case .sideBySide: return "stereo SBS"
        case .topBottom: return "stereo top/bottom"
        }
    }

    var shortLabel: String {
        switch self {
        case .mono: return "Mono"
        case .sideBySide: return "SBS"
        case .topBottom: return "Top/Bottom"
        }
    }

    static func resolve(
        inputPath: String,
        projectionMode: VideoProjectionMode,
        displaySize: CGSize
    ) -> VideoStereoLayout {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["SWIFTXR_VIDEO_STEREO"]
            ?? environment["GAV_MONADO_STEREO"]

        if let value = value?.lowercased(), !value.isEmpty {
            switch value {
            case "mono", "2d": return .mono
            case "sbs", "lr", "left-right", "sidebyside", "side-by-side": return .sideBySide
            case "tb", "ou", "topbottom", "top-bottom", "overunder", "over-under": return .topBottom
            default:
                fputs("swiftxr-shell: unknown stereo layout '\(value)'; using automatic detection\n", stderr)
            }
        }

        if projectionMode == .flat || projectionMode == .eac360 { return .mono }

        let name = URL(fileURLWithPath: inputPath).lastPathComponent.uppercased()
        if name.contains("_TB") || name.contains("OVERUNDER") ||
            name.contains("_OU") || name.contains("TOPBOTTOM") ||
            name.contains("TOP-BOTTOM") || name.contains("TOP_BOTTOM") {
            return .topBottom
        }
        if name.contains("SBS") || name.contains("_LR") ||
            name.contains("SIDEBYSIDE") || name.contains("SIDE-BY-SIDE") ||
            name.contains("SIDE_BY_SIDE") {
            return .sideBySide
        }

        let width = max(Double(displaySize.width), 1)
        let height = max(Double(displaySize.height), 1)
        let aspect = width / height
        if aspect < 0.78 { return .topBottom }
        if aspect > 1.28 { return .sideBySide }
        return .sideBySide
    }
}

struct VideoProjectionAnchor {
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var forward: SIMD3<Float>

    static func from(view: XRView) -> VideoProjectionAnchor {
        let q = simd_quatf(
            ix: view.pose.orientation.x,
            iy: view.pose.orientation.y,
            iz: view.pose.orientation.z,
            r: view.pose.orientation.w
        )
        return VideoProjectionAnchor(
            right: simd_normalize(q.act(SIMD3<Float>(1, 0, 0))),
            up: simd_normalize(q.act(SIMD3<Float>(0, 1, 0))),
            forward: simd_normalize(q.act(SIMD3<Float>(0, 0, -1)))
        )
    }

    mutating func tilt(yawRadians: Float, pitchRadians: Float) {
        if abs(yawRadians) > 0.000_001 {
            let rotation = simd_quatf(angle: yawRadians, axis: simd_normalize(up))
            right = simd_normalize(rotation.act(right))
            forward = simd_normalize(rotation.act(forward))
        }
        if abs(pitchRadians) > 0.000_001 {
            let rotation = simd_quatf(angle: pitchRadians, axis: simd_normalize(right))
            up = simd_normalize(rotation.act(up))
            forward = simd_normalize(rotation.act(forward))
        }
    }
}
