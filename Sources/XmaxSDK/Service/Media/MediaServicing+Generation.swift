import CoreGraphics

public extension MediaServicing {
    /// Resolves a generation canvas using this service's model rules by default.
    func resolveGenerationSize(_ size: CGSize) throws -> CGSize {
        try MediaService(model: model).resolveGenerationSize(size)
    }
}
