import CoreGraphics
import Foundation

enum DisplayGeometryError: Error, Equatable {
    case invalidPrimaryFrame
    case invalidFrame
}

enum DisplayGeometry {
    static func globalFrame(from cocoaFrame: CGRect, primaryFrame: CGRect) throws -> CGRect {
        guard isFinite(primaryFrame), primaryFrame.width > 0, primaryFrame.height > 0 else {
            throw DisplayGeometryError.invalidPrimaryFrame
        }
        guard isFinite(cocoaFrame), cocoaFrame.width > 0, cocoaFrame.height > 0 else { throw DisplayGeometryError.invalidFrame }
        let top = primaryFrame.maxY
        let globalOriginY = top - cocoaFrame.maxY
        guard globalOriginY.isFinite else { throw DisplayGeometryError.invalidFrame }
        let result = CGRect(x: cocoaFrame.minX, y: globalOriginY, width: cocoaFrame.width, height: cocoaFrame.height)
        guard isFinite(result) else { throw DisplayGeometryError.invalidFrame }
        return result
    }

    static func cocoaFrame(from globalFrame: CGRect, primaryFrame: CGRect) throws -> CGRect {
        guard isFinite(primaryFrame), primaryFrame.width > 0, primaryFrame.height > 0 else {
            throw DisplayGeometryError.invalidPrimaryFrame
        }
        guard isFinite(globalFrame), globalFrame.width > 0, globalFrame.height > 0 else {
            throw DisplayGeometryError.invalidFrame
        }
        let cocoaOriginY = primaryFrame.maxY - globalFrame.maxY
        guard cocoaOriginY.isFinite else { throw DisplayGeometryError.invalidFrame }
        let result = CGRect(x: globalFrame.minX, y: cocoaOriginY, width: globalFrame.width, height: globalFrame.height)
        guard isFinite(result) else { throw DisplayGeometryError.invalidFrame }
        return result
    }

    static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width >= 0 && rect.height >= 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
