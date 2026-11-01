import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

struct OCRLine {
    var text: String
    var box: CGRect
}

enum Capture {
    static func permission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func ensure() throws {
        guard permission() else {
            _ = CGRequestScreenCaptureAccess()
            throw Fail(7, "Screen Recording is not granted: System Settings → Privacy & Security → Screen & System Audio Recording → enable deskkontrol")
        }
    }

    private static func shareable() -> SCShareableContent? {
        var content: SCShareableContent?
        let sem = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, _ in
            content = c
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        return content
    }

    /// Captures one window, even when it is covered or on another Space, via ScreenCaptureKit.
    static func window(_ wid: CGWindowID) -> CGImage? {
        if let win = shareable()?.windows.first(where: { $0.windowID == wid }) {
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.width = Int(win.frame.width * 2)
            config.height = Int(win.frame.height * 2)
            config.showsCursor = false
            config.capturesAudio = false
            var image: CGImage?
            let sem = DispatchSemaphore(value: 0)
            Task {
                image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                sem.signal()
            }
            if sem.wait(timeout: .now() + 4) == .success, let image { return image }
        }
        // Fallback for an old or unusual window server state.
        return CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.bestResolution, .boundsIgnoreFraming])
    }

    static func crop(_ image: CGImage, to rect: CGRect, windowFrame: CGRect) -> CGImage? {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return image }
        let scaleX = CGFloat(image.width) / windowFrame.width
        let scaleY = CGFloat(image.height) / windowFrame.height
        let r = CGRect(
            x: (rect.minX - windowFrame.minX) * scaleX,
            y: (rect.minY - windowFrame.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r.integral)
    }

    static func save(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Fail(5, "could not encode PNG")
        }
        try data.write(to: url)
    }

    /// Vision OCR. Boxes are converted from image pixels to screen points.
    static func ocr(_ image: CGImage, windowFrame: CGRect) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.005
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let observations = request.results ?? []

        struct Word {
            var text: String
            var box: CGRect
        }
        let words: [Word] = observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Word(text: text, box: obs.boundingBox)
        }

        var rows: [[Word]] = []
        for w in words.sorted(by: { $0.box.midY > $1.box.midY }) {
            if var last = rows.last, let first = last.first, abs(first.box.midY - w.box.midY) < 0.012 {
                last.append(w)
                rows[rows.count - 1] = last
            } else {
                rows.append([w])
            }
        }

        // Vision boxes are normalised with the origin at the bottom left.
        let wf = windowFrame
        return rows.map { row -> OCRLine in
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            let box = sorted.dropFirst().reduce(sorted[0].box) { $0.union($1.box) }
            let rect = CGRect(
                x: wf.minX + box.minX * wf.width,
                y: wf.minY + (1 - box.maxY) * wf.height,
                width: box.width * wf.width,
                height: box.height * wf.height
            )
            return OCRLine(text: sorted.map(\.text).joined(separator: " "), box: rect)
        }
    }
}
