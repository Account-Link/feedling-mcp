import PhotosUI
import SwiftUI
import UIKit

/// Single-image picker backed by PHPickerViewController. Returns JPEG data
/// already compressed for sending — caller doesn't deal with UIImage.
///
/// Compression target: ≤ 400 KB. We start at quality 0.85 and step down
/// until the encoded bytes fit, with a hard floor at 0.4 (any lower and
/// the photo looks badly degraded — better to fail than send garbage).
struct PhotoPicker: UIViewControllerRepresentable {
    /// Called on the main queue with compressed JPEG bytes; nil if the
    /// user cancelled or compression couldn't hit the size target.
    let onPicked: (Data?) -> Void

    /// 400 KB target. Empirically fine for chat-bubble display, keeps
    /// the v1 envelope payload manageable.
    private static let targetByteCount = 400 * 1024

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onPicked(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { obj, _ in
                let img = obj as? UIImage
                let jpeg = img.flatMap { PhotoPicker.compressForSend($0) }
                DispatchQueue.main.async { self.parent.onPicked(jpeg) }
            }
        }

        // MARK: - Compression
    }

    /// Resize so the longest side is ≤ 1600 px, then JPEG-encode at
    /// progressively lower quality until under the size target.
    /// Returns nil if even quality 0.4 still exceeds the budget.
    static func compressForSend(_ image: UIImage) -> Data? {
        let resized = resize(image, maxLongSide: 1600)
        let qualities: [CGFloat] = [0.85, 0.75, 0.65, 0.55, 0.45, 0.4]
        for q in qualities {
            guard let data = resized.jpegData(compressionQuality: q) else { continue }
            if data.count <= targetByteCount { return data }
        }
        // Fall back to lowest-quality even if oversize, so the user gets
        // *something* sent. Bigger envelope is acceptable; total silence isn't.
        return resized.jpegData(compressionQuality: 0.4)
    }

    private static func resize(_ image: UIImage, maxLongSide: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let longest = max(w, h)
        guard longest > maxLongSide else { return image }
        let scale = maxLongSide / longest
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
