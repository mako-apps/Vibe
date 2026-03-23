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

enum ChatImageEditModule {
  static func presentEditor(
    from presenter: UIViewController,
    messageId: String?,
    mediaURL: String,
    initialImage: UIImage?,
    initialCaption: String?,
    headerTitle: String? = nil,
    dismissPresenterOnSend: Bool = false,
    onAction: @escaping (ChatImageEditActionPayload) -> Void
  ) {
    let controller = ChatImageEditViewController(
      messageId: messageId,
      mediaURL: mediaURL,
      initialImage: initialImage,
      initialCaption: initialCaption,
      headerTitle: headerTitle,
      dismissPresenterOnSend: dismissPresenterOnSend
    )
    controller.modalPresentationStyle = .overFullScreen
    controller.onAction = onAction
    presenter.present(controller, animated: true)
  }
}
