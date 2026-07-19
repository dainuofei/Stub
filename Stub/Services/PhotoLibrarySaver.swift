import Foundation
import Photos
import UIKit

enum PhotoSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed

    var label: String {
        switch self {
        case .idle, .failed: return "保存到相册"
        case .saving: return "保存中…"
        case .saved: return "已保存"
        }
    }
}

enum PhotoLibrarySaveError: LocalizedError {
    case permissionDenied
    case saveFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有照片权限，请在系统设置中允许 Stub 添加照片。"
        case .saveFailed(let error):
            return error?.localizedDescription ?? "保存照片失败，请稍后重试。"
        }
    }
}

enum PhotoLibrarySaver {
    static func save(_ image: UIImage) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibrarySaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.saveFailed(error))
                }
            }
        }
    }
}
