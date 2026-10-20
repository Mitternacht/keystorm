import ApplicationServices
import Foundation
import Testing
@testable import Keystorm

/// AXEnabled handling for real editors. TextEdit's text view omits the attribute entirely.
struct DictationFieldMetadataTests {
    @Test(arguments: [AXError.attributeUnsupported, .noValue])
    func `An editor that does not report AXEnabled is not treated as disabled`(status: AXError) {
        #expect(DictationFieldMetadata.resolvedEnabled(status: status, value: nil))
    }

    @Test func `An explicit AXEnabled value is respected`() {
        #expect(DictationFieldMetadata.resolvedEnabled(status: .success, value: kCFBooleanTrue))
        #expect(!DictationFieldMetadata.resolvedEnabled(status: .success, value: kCFBooleanFalse))
        #expect(!DictationFieldMetadata.resolvedEnabled(status: .success, value: nil))
    }

    @Test(arguments: [AXError.cannotComplete, .failure, .apiDisabled, .invalidUIElement, .notImplemented])
    func `Other Accessibility errors fail closed`(status: AXError) {
        #expect(!DictationFieldMetadata.resolvedEnabled(status: status, value: nil))
    }

    @Test func `An unreported AXEnabled still needs an editable text role to qualify`() {
        let textEdit = DictationFieldMetadata(processIdentifier: 1, role: "AXTextArea", subrole: "",
            isEnabled: DictationFieldMetadata.resolvedEnabled(status: .attributeUnsupported, value: nil),
            isProtected: false, selectedTextIsSettable: true, supportsPaste: true, valueIsSettable: true)
        #expect(textEdit.supportsInsertion)
        #expect(textEdit.acceptsPasteFallback)
        var readOnly = textEdit
        readOnly.selectedTextIsSettable = false
        readOnly.supportsPaste = false
        readOnly.valueIsSettable = false
        #expect(!readOnly.supportsInsertion)
        #expect(!readOnly.acceptsPasteFallback)
        var group = textEdit
        group.role = "AXGroup"
        #expect(!group.supportsInsertion)
        #expect(!group.acceptsPasteFallback)
    }

    // MARK: Secure hints

    @Test(arguments: [AXError.success, .attributeUnsupported, .noValue])
    func `An absent or present security marker is known`(status: AXError) {
        #expect(DictationFieldMetadata.optionalAttributeIsKnown(status: status))
    }

    @Test(arguments: [AXError.cannotComplete, .failure, .apiDisabled, .invalidUIElement, .notImplemented, .illegalArgument])
    func `An unreadable security marker is unknown and fails closed`(status: AXError) {
        #expect(!DictationFieldMetadata.optionalAttributeIsKnown(status: status))
    }

    @Test(arguments: ["AXSecureTextField", " axsecuretextfield ", "AXSECURETEXTFIELD", "AXPasswordField", "CustomSecureInput"])
    func `A role or subrole naming a secure or password element is secure`(name: String) {
        #expect(DictationFieldMetadata.isSecureRoleName(name))
        let asSubrole = DictationFieldMetadata(processIdentifier: 1, role: "AXTextField", subrole: name,
            isEnabled: true, isProtected: false, selectedTextIsSettable: true, valueIsSettable: true)
        #expect(asSubrole.secureFailure == .secureField)
        #expect(!asSubrole.supportsInsertion)
        #expect(!asSubrole.acceptsPasteFallback)
    }

    @Test(arguments: ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", ""])
    func `Ordinary text roles are not secure by name`(name: String) {
        #expect(!DictationFieldMetadata.isSecureRoleName(name))
        #expect(!DictationFieldMetadata.isSecureRoleName(nil))
    }

    @Test(arguments: [["Password"], ["Confirm your password"], ["Passwort"], ["Kennwort eingeben"], ["PASSCODE"],
                      ["Recovery passphrase"], ["Search", "New password"]])
    func `A label, title or placeholder naming a password is a secure hint`(labels: [String]) {
        #expect(DictationFieldMetadata.isSecureLabel(labels))
    }

    @Test(arguments: [[], [""], ["Message #general"], ["Subject"], ["Terminal input"], ["Pass the salt"]])
    func `Ordinary labels are not secure hints`(labels: [String]) {
        #expect(!DictationFieldMetadata.isSecureLabel(labels))
    }

    @Test func `Any one secure marker refuses the field, and secure keyboard entry is reported separately`() {
        let plain = DictationFieldMetadata(processIdentifier: 1, role: "AXTextField", subrole: nil,
            isEnabled: true, isProtected: false, selectedTextIsSettable: true, valueIsSettable: true)
        #expect(plain.secureFailure == nil)
        #expect(plain.supportsInsertion && plain.acceptsPasteFallback)
        var label = plain
        label.hasSecureLabel = true
        #expect(label.secureFailure == .secureField)
        var keyboard = plain
        keyboard.secureEventInput = true
        #expect(keyboard.secureFailure == .secureInput)
        #expect(!keyboard.supportsInsertion && !keyboard.acceptsPasteFallback)
        var both = keyboard
        both.isProtected = true
        #expect(both.secureFailure == .secureField, "A field-level marker names the field itself.")
        #expect(DictationCaptureFailure.secureInput.blocksRecording)
        #expect(DictationCaptureFailure.secureInput.withholdsContext)
    }
}
