import simd

struct Volume3DOrbitCamera: Equatable {
    var target: SIMD3<Float>
    var offset: SIMD3<Float>
    var up: SIMD3<Float>
}

struct Volume3DOrbitState: Equatable {
    static let rotationSensitivity: Float = 0.008
    static let pitchLimits: ClosedRange<Float> = -1.35...1.35

    var target: SIMD3<Float>
    private var initialOffsetDirection: SIMD3<Float>
    private var initialUp: SIMD3<Float>
    private(set) var yaw: Float
    private(set) var pitch: Float
    private(set) var roll: Float
    private(set) var distance: Float
    private var distanceLimits: ClosedRange<Float>

    init(target: SIMD3<Float> = SIMD3<Float>(repeating: 0.5),
         offset: SIMD3<Float> = SIMD3<Float>(0, -2, 0),
         up: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
         distanceLimits: ClosedRange<Float> = 0.1...16) {
        self.target = target
        self.initialOffsetDirection = Self.safeNormalize(offset, fallback: SIMD3<Float>(0, -1, 0))
        self.initialUp = Self.safeNormalize(up, fallback: SIMD3<Float>(0, 0, 1))
        self.yaw = 0
        self.pitch = 0
        self.roll = 0
        self.distanceLimits = distanceLimits
        self.distance = Self.clamp(Self.lengthOrFallback(offset, fallback: 2), to: distanceLimits)
    }

    var camera: Volume3DOrbitCamera {
        let yawRotation = simd_quatf(angle: yaw, axis: initialUp)
        let yawedDirection = Self.safeNormalize(yawRotation.act(initialOffsetDirection),
                                                fallback: initialOffsetDirection)
        let yawedUp = Self.safeNormalize(yawRotation.act(initialUp), fallback: initialUp)
        let forward = Self.safeNormalize(-yawedDirection, fallback: -initialOffsetDirection)
        let right = Self.safeNormalize(simd_cross(forward, yawedUp),
                                       fallback: Self.safePerpendicular(to: forward))
        let pitchRotation = simd_quatf(angle: pitch, axis: right)
        let offsetDirection = Self.safeNormalize(pitchRotation.act(yawedDirection),
                                                 fallback: yawedDirection)
        var up = Self.safeNormalize(pitchRotation.act(yawedUp), fallback: yawedUp)
        if abs(roll) > Float.ulpOfOne {
            let rolledForward = Self.safeNormalize(-offsetDirection, fallback: forward)
            let rollRotation = simd_quatf(angle: roll, axis: rolledForward)
            up = Self.safeNormalize(rollRotation.act(up), fallback: up)
        }
        return Volume3DOrbitCamera(target: target,
                                   offset: offsetDirection * distance,
                                   up: up)
    }

    mutating func reset(target: SIMD3<Float>,
                        offset: SIMD3<Float>,
                        up: SIMD3<Float>,
                        distanceLimits: ClosedRange<Float>) -> Volume3DOrbitCamera {
        self = Volume3DOrbitState(target: target,
                                  offset: offset,
                                  up: up,
                                  distanceLimits: distanceLimits)
        return camera
    }

    mutating func rotate(deltaX: Float, deltaY: Float) -> Volume3DOrbitCamera? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        let nextYaw = yaw - deltaX * Self.rotationSensitivity
        let nextPitch = Self.clamp(pitch - deltaY * Self.rotationSensitivity,
                                   to: Self.pitchLimits)
        guard abs(nextYaw - yaw) > Float.ulpOfOne ||
                abs(nextPitch - pitch) > Float.ulpOfOne else {
            return nil
        }
        yaw = nextYaw
        pitch = nextPitch
        return camera
    }

    mutating func tilt(roll deltaRoll: Float, pitch deltaPitch: Float) -> Volume3DOrbitCamera? {
        guard deltaRoll.isFinite, deltaPitch.isFinite else { return nil }
        let nextRoll = roll + deltaRoll
        let nextPitch = Self.clamp(pitch + deltaPitch, to: Self.pitchLimits)
        guard abs(nextRoll - roll) > Float.ulpOfOne ||
                abs(nextPitch - pitch) > Float.ulpOfOne else {
            return nil
        }
        roll = nextRoll
        pitch = nextPitch
        return camera
    }

    mutating func zoom(scale: Float) -> Volume3DOrbitCamera? {
        guard scale.isFinite, scale > 0 else { return nil }
        let nextDistance = Self.clamp(distance / scale, to: distanceLimits)
        guard abs(nextDistance - distance) > Float.ulpOfOne else { return nil }
        distance = nextDistance
        return camera
    }

    mutating func syncTarget(_ target: SIMD3<Float>) {
        self.target = target
    }

    mutating func syncDistance(from offset: SIMD3<Float>) {
        distance = Self.clamp(Self.lengthOrFallback(offset, fallback: distance), to: distanceLimits)
    }

    mutating func syncDistanceLimits(_ limits: ClosedRange<Float>) {
        distanceLimits = limits
        distance = Self.clamp(distance, to: limits)
    }

    private static func lengthOrFallback(_ vector: SIMD3<Float>, fallback: Float) -> Float {
        let length = simd_length(vector)
        guard length.isFinite, length > Float.ulpOfOne else { return fallback }
        return length
    }

    private static func clamp(_ value: Float, to range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func safeNormalize(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        guard lengthSquared.isFinite, lengthSquared > Float.ulpOfOne else { return fallback }
        return vector / sqrt(lengthSquared)
    }

    private static func safePerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(vector.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return safeNormalize(simd_cross(vector, axis), fallback: SIMD3<Float>(0, 0, 1))
    }
}
