import SwiftUI
import UIKit

/// Holds the one direct reference to the composer UITextField.
/// `sendMessage()` reads the field's own `.text` — the single source of truth —
/// never the SwiftUI binding snapshot.
///
/// Why this exists (build 90 lesson): the old composer was a SwiftUI `TextField`
/// with `axis: .vertical`, which SwiftUI backs with a **UITextView**, not a
/// UITextField. Build 90's fix (`UIResponder.currentFirstResponder as? UITextField`)
/// therefore *always* failed its cast and silently fell back to the stale
/// `messageText` binding — the fix was dead code. Chinese Pinyin composition
/// (marked text) never syncs to the binding until confirmed, so sending right
/// after typing read a lagging snapshot and dropped the tail ("打车去苏州中心" → "打车").
/// A real UITextField wrapped in UIViewRepresentable removes the guesswork:
/// the View owns the field instance and reads its `.text` directly.
final class ComposerTextFieldStore: ObservableObject {
    weak var textField: UITextField?

    /// The text to send: commits any in-flight Pinyin marked text, then reads
    /// the field's own text (every character currently displayed).
    /// Returns nil only when the field isn't attached yet.
    func committedText() -> String? {
        guard let field = textField else { return nil }
        // Commit unconfirmed Pinyin composition so its characters are included.
        // unmarkText() commits in place: no resign, no keyboard flicker, no jump.
        if field.markedTextRange != nil {
            field.unmarkText()
        }
        return field.text ?? ""
    }

    /// Current visible text WITHOUT committing marked text (read-only).
    /// Used by the send button's enabled state so it stays enabled while the
    /// user is still composing Pinyin.
    var visibleText: String {
        textField?.text ?? ""
    }

    /// Clear the field (and, via the editingChanged event, the SwiftUI binding).
    func clear() {
        guard let field = textField else { return }
        field.text = ""
        field.sendActions(for: .editingChanged)
    }
}

/// A real UITextField in SwiftUI, so send can read the field directly.
///
/// Layout is unchanged from the old SwiftUI TextField: it lives in the same
/// HStack inside the rounded composer, with the send button nested on its
/// right. Trade-off vs. the old field: UITextField is single-line, so the
/// 1–4 line vertical growth is replaced by horizontal scrolling inside the
/// field. Reliability (never dropping typed characters) wins over growth.
struct ComposerTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var store: ComposerTextFieldStore
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "给小智发消息"
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = false
        field.clearButtonMode = .never
        field.autocorrectionType = .default
        field.autocapitalizationType = .none
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        // The direct reference: send reads this field's .text, never the binding.
        store.textField = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // Keep the Coordinator's submit closure fresh (ConversationView is a
        // struct; the closure captured at makeCoordinator time may go stale).
        context.coordinator.onSubmit = onSubmit
        context.coordinator.isFocused = $isFocused
        // Sync binding -> field only when they differ, so the cursor never jumps.
        if uiView.text != text {
            uiView.text = text
        }
        // Drive focus from SwiftUI state (Live2D tap / mode switches set it).
        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        var isFocused: Binding<Bool>
        var onSubmit: () -> Void

        init(text: Binding<String>, isFocused: Binding<Bool>, onSubmit: @escaping () -> Void) {
            _text = text
            self.isFocused = isFocused
            self.onSubmit = onSubmit
        }

        @objc func textDidChange(_ sender: UITextField) {
            // Sync field -> binding (drives isComposerEmpty / send-button state).
            // sender.text includes marked-text characters, so the button stays
            // enabled while the user is still composing Pinyin.
            text = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit()
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            // Keep SwiftUI focus state in sync when the user taps the field.
            if !isFocused.wrappedValue {
                isFocused.wrappedValue = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if isFocused.wrappedValue {
                isFocused.wrappedValue = false
            }
        }
    }
}
