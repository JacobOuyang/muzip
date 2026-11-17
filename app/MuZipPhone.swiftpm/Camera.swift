import MuZipCore
import SwiftUI
import UIKit

/// The iPhone camera: takes one photo and hands it back as a Photo (upright, full size). Its size is what the camera's
/// JPEG would be, for the "texts sent against the photo" count.
struct CameraView: UIViewControllerRepresentable {
    let done: (Photo?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.cameraCaptureMode = .photo
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (Photo?) -> Void
        init(done: @escaping (Photo?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let ui = info[.originalImage] as? UIImage, let jpeg = ui.jpegData(compressionQuality: 0.9) else { return done(nil) }
            done(Photo(data: jpeg))   // the JPEG carries the orientation; Photo turns it upright
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

extension UIImagePickerController {
    static var hasCamera: Bool { isSourceTypeAvailable(.camera) }
}
