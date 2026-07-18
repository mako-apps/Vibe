import UIKit

enum ChatImageEditEventType: String {
  case reply = "mediaReplyRequested"
  case edit = "mediaEditRequested"
  case resend = "mediaResendRequested"
  case sendNew = "mediaSendNewRequested"
}

struct ChatImageEditActionPayload {
  let eventType: ChatImageEditEventType
  let messageId: String?
  let mediaURL: String
  let caption: String?
  let editedImageURL: URL?
}

/// One page in the native image open sheet (single image or multi-image set).
struct ChatImageEditGalleryPage {
  let mediaURL: String
  let image: UIImage?
}

enum ChatImageEditModule {
  static func presentEditor(
    from presenter: UIViewController,
    sourceView: UIView? = nil,
    messageId: String?,
    mediaURL: String,
    initialImage: UIImage?,
    initialCaption: String?,
    headerTitle: String? = nil,
    dismissPresenterOnSend: Bool = false,
    galleryPages: [ChatImageEditGalleryPage] = [],
    startIndex: Int = 0,
    /// When true, open directly in markup mode (draw/text). Default is view-only until Edit.
    startInEditMode: Bool = false,
    onAction: @escaping (ChatImageEditActionPayload) -> Void
  ) {
    let pages: [ChatImageEditGalleryPage] = {
      if galleryPages.count > 1 { return galleryPages }
      if !galleryPages.isEmpty { return galleryPages }
      return [ChatImageEditGalleryPage(mediaURL: mediaURL, image: initialImage)]
    }()
    let controller = ChatImageEditViewController(
      messageId: messageId,
      mediaURL: mediaURL,
      initialImage: initialImage,
      initialCaption: initialCaption,
      headerTitle: headerTitle,
      dismissPresenterOnSend: dismissPresenterOnSend,
      galleryPages: pages,
      startIndex: startIndex,
      startInEditMode: startInEditMode
    )
    // Opaque full-screen so chat / cell message never shows through.
    controller.modalPresentationStyle = .fullScreen
    if #available(iOS 18.0, *), let sourceView = sourceView {
      let options = UIViewController.Transition.ZoomOptions()
      controller.preferredTransition = .zoom(options: options) { _ in
        return sourceView
      }
    } else {
      controller.modalTransitionStyle = .crossDissolve
    }
    controller.onAction = onAction
    presenter.present(controller, animated: true)
  }
}
