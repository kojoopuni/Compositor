import CoreGraphics

/// A picture repeated in a grid, for judging how a texture tiles: shown by View > Tile Preview and written by the
/// command-line tool.
nonisolated enum TileSheet {
    /// `tile` repeated `count` times each way, no more than `limit` pixels across. Each tile is drawn at a whole
    /// number of pixels so the sheet shows no seams of its own.
    static func image(of tile: CGImage, count: Int, limit: Int) throws -> CGImage {
        let wide = max(1, min(tile.width, limit / count))
        let tall = max(1, Int((Double(tile.height) * Double(wide) / Double(tile.width)).rounded()))
        let context = try BrushRaster.context(width: wide * count, height: tall * count, mask: false)
        context.interpolationQuality = .high
        for row in 0..<count { for column in 0..<count {
            context.saveGState()
            // BrushRaster.draw copies pixels exactly; here the tile is being resized, so it is drawn smoothly instead.
            context.translateBy(x: CGFloat(column * wide), y: CGFloat((row + 1) * tall))
            context.scaleBy(x: 1, y: -1)
            context.draw(tile, in: CGRect(x: 0, y: 0, width: wide, height: tall))
            context.restoreGState()
        } }
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
}
