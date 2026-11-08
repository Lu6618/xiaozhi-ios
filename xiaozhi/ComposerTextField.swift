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
///
/// NOTE: deliberately NOT an ObservableObject — it publishes nothing (the
/// `messageText` binding drives UI updates). Swift only synthesizes
/// ObservableObject conformance for classes with @Published properties, so
/// declaring it ObservableObject without one fails to compile.
/// @MainActor: it only ever touches UIKit objects from SwiftUI (main actor).
@MainActor
final class ComposerTextFieldStore {
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

    /// Focus the field (e.g. returning to text mode). Direct UIKit call —
    /// never via a SwiftUI state round-trip (see updateUIView note below).
    func focusKeyboard() {
        textField?.becomeFirstResponder()
    }

    /// Dismiss the keyboard (e.g. entering push-to-talk, tapping Live2D).
    func resignKeyboard() {
        textField?.resignFirstResponder()
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

    /// Pin the height. A bare UIViewRepresentable UITextField has no usable
    /// intrinsic height for SwiftUI's layout, so without this SwiftUI offers
    /// it the full available height and it stretches to fill it — in build 96
    /// the composer became a full-screen rounded rectangle that covered the
    /// chat transcript (the "blank screen" in Lu's 16:26 screenshot). A
    /// single-line 17pt field is 36pt tall (matches the 36pt "+" button).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 36)
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // Keep the Coordinator's submit closure fresh (ConversationView is a
        // struct; the closure captured at makeCoordinator time may go stale).
        context.coordinator.onSubmit = onSubmit
        context.coordinator.isFocused = $isFocused
        // Sync binding -> field ONLY when the field is not being edited.
        // While the user is typing the field is the source of truth; writing
        // the (possibly lagging) binding back here wipes in-flight keystrokes.
        if !uiView.isFirstResponder && uiView.text != text {
            uiView.text = text
        }
        // NOTE: focus is deliberately NOT driven here. build 99 drove focus
        // from the round-tripped SwiftUI isFocused state in updateUIView
        // (become/resignFirstResponder based on it), and updateUIView runs on
        // every keystroke (each keystroke writes the binding -> parent
        // re-renders -> updateUIView). Since build 96 dropped SwiftUI's
        // `.focused($isComposerFocused)` modifier, the @FocusState is no
        // longer owned by SwiftUI's focus system, so the value updateUIView
        // reads can be false while the field is actually first responder —
        // and updateUIView then called resignFirstResponder() on a live
        // field: the keyboard dismissed itself on the first keystroke and
        // the typed character was lost. Focus is now managed only by UIKit
        // (user taps the field) and by explicit store.focusKeyboard() /
        // resignKeyboard() calls for mode switches; the delegate callbacks
        // below only mirror the state for SwiftUI, they never drive it.
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
