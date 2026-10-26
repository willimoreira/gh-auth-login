import Contacts
import Foundation

/// Busca nos Contatos do iPhone, para "mande para a Ana" saber quem é a Ana.
@MainActor
final class ContactsService {
    struct Match: Sendable {
        let name: String
        let phones: [String]
        let emails: [String]
    }

    private let store = CNContactStore()
    private var granted = false

    func requestAccess() async {
        granted = (try? await store.requestAccess(for: .contacts)) ?? false
    }

    func find(_ name: String) throws -> [Match] {
        guard granted else {
            throw ServiceError.permission(
                "Sem permissão para os contatos. Libere em Ajustes › Privacidade e Segurança › Contatos.")
        }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        return contacts.prefix(5).map { contact in
            Match(
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? name,
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                emails: contact.emailAddresses.map { $0.value as String })
        }
    }
}
