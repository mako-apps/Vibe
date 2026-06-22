import UIKit
if #available(iOS 18.0, *) {
    let options = UIZoomTransitionOptions()
    let transition = UIViewControllerTransition.zoom(options: options) { context in
        return UIView()
    }
}
