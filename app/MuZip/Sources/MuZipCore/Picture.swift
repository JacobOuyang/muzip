import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import libwebp

/// A photo the phone keeps, and the small pictures made from it (evac/smsimage.py, codes.crop_zoom): the sketch, a
/// grey picture of at most `side` px (contrast stretched, WebP quality 5), and close-ups cropped from the original.
public final class Photo {
    public static var side = 128
    public let image: CGImage           // upright, full size
    public var width: Int { image.width }
    public var height: Int { image.height }
    public let fileBytes: Int

    public init(image: CGImage, fileBytes: Int) { self.image = image; self.fileBytes = fileBytes }

    /// A photo file, turned upright (EXIF orientation applied), at full size.
    public convenience init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = Photo.upright(src) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        self.init(image: img, fileBytes: size)
    }

    /// A photo's file bytes (JPEG, HEIC, PNG...), turned upright, at full size.
    public convenience init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = Photo.upright(src) else { return nil }
        self.init(image: img, fileBytes: data.count)
    }

    static func upright(_ src: CGImageSource) -> CGImage? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// The size a picture of w x h is shrunk to, to fit in side x side (Pillow's thumbnail: never enlarged).
    public static func fit(_ w: Int, _ h: Int, side: Int) -> (Int, Int) {
        if w <= side && h <= side { return (w, h) }
        let aspect = Double(w) / Double(h)
        func pick(_ v: Double, _ key: (Double) -> Double) -> Int { max(Int([floor(v), ceil(v)].min(by: { key($0) < key($1) })!), 1) }
        if 1.0 >= aspect {  // taller than wide
            return (pick(Double(side) * aspect, { abs(aspect - $0 / Double(side)) }), side)
        }
        return (side, pick(Double(side) / aspect, { $0 == 0 ? 0 : abs(aspect - Double(side) / $0) }))
    }

    public var sketchSize: (Int, Int) { Photo.fit(width, height, side: Photo.side) }

    /// The sketch: the whole photo, grey, at most `side` px, WebP quality 5.
    public func sketch() -> Data { Picture.grey(image, side: Photo.side, quality: 5) }

    /// A close-up for a ZOOM box (in the sketch's pixels): -> (WebP bytes, the crop as a box in the sketch's pixels,
    /// the crop in the photo's pixels, the size it is sent at). Same arithmetic as codes.crop_zoom and kit.js cropBox.
    public func closeUp(_ z: Codes.Zoom) -> (data: Data, box: [Double], crop: CGRect, size: (Int, Int)) {
        let (w, h) = sketchSize
        let sx = Double(width) / Double(w), sy = Double(height) / Double(h)
        let (bx, by, bw, bh) = (Double(z.box[0]), Double(z.box[1]), Double(z.box[2]), Double(z.box[3]))
        let cx = (bx + bw / 2) * sx, cy = (by + bh / 2) * sy
        let hw = max(bw * sx * 0.6, Codes.minCrop / 2), hh = max(bh * sy * 0.6, Codes.minCrop / 2)
        let rx0 = max(0, cx - hw), ry0 = max(0, cy - hh)
        let rx1 = min(Double(width), cx + hw), ry1 = min(Double(height), cy + hh)
        let r = { (v: Double) in v.rounded(.toNearestOrEven) }
        let rect = CGRect(x: r(rx0), y: r(ry0), width: r(rx1) - r(rx0), height: r(ry1) - r(ry0))
        let crop = image.cropping(to: rect)!
        let side = z.high ? Codes.high : Photo.side
        let data = z.colour ? Picture.colour(crop, side: side, quality: 30) : Picture.grey(crop, side: side, quality: side > Photo.side ? 20 : 5)
        return (data, [rx0 / sx, ry0 / sy, (rx1 - rx0) / sx, (ry1 - ry0) / sy], rect, Photo.fit(crop.width, crop.height, side: side))
    }
}

public enum Picture {
    /// RGBA pixels of an image (sRGB, top row first).
    static func rgba(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return px
    }

    static func scale(_ src: inout [UInt8], _ w: Int, _ h: Int, to w2: Int, _ h2: Int, channels: Int) -> [UInt8] {
        if w == w2 && h == h2 { return src }
        var dst = [UInt8](repeating: 0, count: w2 * h2 * channels)
        src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * channels)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h2), width: vImagePixelCount(w2), rowBytes: w2 * channels)
                if channels == 1 { vImageScale_Planar8(&a, &b, nil, vImage_Flags(kvImageHighQualityResampling)) }
                else { vImageScale_ARGB8888(&a, &b, nil, vImage_Flags(kvImageHighQualityResampling)) }
            }
        }
        return dst
    }

    /// Pillow's ImageOps.autocontrast(cutoff=1) on grey pixels.
    static func autocontrast(_ px: inout [UInt8]) {
        var h = [Int](repeating: 0, count: 256)
        for v in px { h[Int(v)] += 1 }
        let n = px.count
        var cut = n / 100
        for lo in 0..<256 { if cut > h[lo] { cut -= h[lo]; h[lo] = 0 } else { h[lo] -= cut; cut = 0 }; if cut <= 0 { break } }
        cut = n / 100
        for hi in stride(from: 255, through: 0, by: -1) { if cut > h[hi] { cut -= h[hi]; h[hi] = 0 } else { h[hi] -= cut; cut = 0 }; if cut <= 0 { break } }
        guard let lo = h.firstIndex(where: { $0 > 0 }), let hi = h.lastIndex(where: { $0 > 0 }), hi > lo else { return }
        let s = 255.0 / Double(hi - lo), o = -Double(lo) * s
        let lut = (0..<256).map { UInt8(max(0, min(255, Int(Double($0) * s + o)))) }
        for i in px.indices { px[i] = lut[Int(px[i])] }
    }

    /// Grey (Pillow's "L"), shrunk to fit in `side`, contrast stretched, WebP.
    public static func grey(_ img: CGImage, side: Int, quality: Float) -> Data {
        let c = rgba(img)
        var g = [UInt8](repeating: 0, count: img.width * img.height)
        for i in g.indices {
            let r = UInt32(c[4 * i]), gr = UInt32(c[4 * i + 1]), b = UInt32(c[4 * i + 2])
            g[i] = UInt8((r * 19595 + gr * 38470 + b * 7471 + 0x8000) >> 16)
        }
        let (w2, h2) = Photo.fit(img.width, img.height, side: side)
        var small = scale(&g, img.width, img.height, to: w2, h2, channels: 1)
        autocontrast(&small)
        var rgb = [UInt8](repeating: 0, count: w2 * h2 * 3)
        for i in small.indices { rgb[3 * i] = small[i]; rgb[3 * i + 1] = small[i]; rgb[3 * i + 2] = small[i] }
        return webp(rgb, w2, h2, quality: quality)
    }

    /// Colour, shrunk to fit in `side`, WebP.
    public static func colour(_ img: CGImage, side: Int, quality: Float) -> Data {
        var c = rgba(img)
        let (w2, h2) = Photo.fit(img.width, img.height, side: side)
        let small = scale(&c, img.width, img.height, to: w2, h2, channels: 4)
        var rgb = [UInt8](repeating: 0, count: w2 * h2 * 3)
        for i in 0..<(w2 * h2) { rgb[3 * i] = small[4 * i]; rgb[3 * i + 1] = small[4 * i + 1]; rgb[3 * i + 2] = small[4 * i + 2] }
        return webp(rgb, w2, h2, quality: quality)
    }

    static func webp(_ rgb: [UInt8], _ w: Int, _ h: Int, quality: Float) -> Data {
        var config = WebPConfig()
        guard WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, quality) != 0 else { return Data() }
        config.method = 6
        var pic = WebPPicture()
        guard WebPPictureInit(&pic) != 0 else { return Data() }
        pic.width = Int32(w); pic.height = Int32(h)
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer); WebPPictureFree(&pic) }
        _ = rgb.withUnsafeBufferPointer { WebPPictureImportRGB(&pic, $0.baseAddress, Int32(w * 3)) }
        return withUnsafeMutablePointer(to: &writer) { wp -> Data in
            pic.writer = WebPMemoryWrite
            pic.custom_ptr = UnsafeMutableRawPointer(wp)
            guard WebPEncode(&config, &pic) != 0 else { return Data() }
            return Data(bytes: wp.pointee.mem, count: wp.pointee.size)
        }
    }
}
