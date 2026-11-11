import ContactsUI
import SwiftUI

/// The system contact picker, limited to email addresses. It runs outside the app: Muninn gets only the one email
/// the owner picks, and the contact's name. Nothing else is read and nothing is stored.
struct ContactEmailPicker: UIViewControllerRepresentable {
    let picked: (_ email: String, _ name: String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey]
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0")
        // One email: a tap on the contact picks it. More than one: the owner picks the address.
        picker.predicateForSelectionOfContact = NSPredicate(format: "emailAddresses.@count == 1")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == 'emailAddresses'")
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let picked: (String, String?) -> Void
        init(picked: @escaping (String, String?) -> Void) { self.picked = picked }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            guard let email = contact.emailAddresses.first?.value as String? else { return }
            picked(email, CNContactFormatter.string(from: contact, style: .fullName))
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            guard let email = property.value as? String else { return }
            picked(email, CNContactFormatter.string(from: property.contact, style: .fullName))
        }
    }
}
