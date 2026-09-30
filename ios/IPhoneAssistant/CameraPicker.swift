import SwiftUI
import UIKit

/// 相机拍照。SwiftUI 没有内置的相机入口，只能把 UIImagePickerController 包一层。
///
/// 用 Binding 控制关闭而不是 `@Environment(\.dismiss)`：相机是全屏弹出的，
/// 由调用方持有开关，状态不会出现两边不一致的情况。
struct CameraPicker: UIViewControllerRepresentable {

    @Binding var isPresented: Bool
    /// 拍到照片后回调。回调在主线程。
    let onPick: (UIImage) -> Void

    /// 模拟器上根本没有相机，调用方要先问这个再决定要不要弹
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        // 相机界面由系统接管，没有需要同步的状态
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
