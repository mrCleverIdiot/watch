import Foundation
import Contacts

/// Manages contact syncing to Samsung Galaxy Watch
class ContactsManager {
    static let shared = ContactsManager()
    
    private let contactStore = CNContactStore()
    
    // MARK: - Public Methods
    
    func requestContactsPermission(completion: @escaping (Bool) -> Void) {
        contactStore.requestAccess(for: .contacts) { granted, error in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    func syncContactsToWatch() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            print("Contacts permission not granted")
            return
        }
        
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        var contacts: [ContactData] = []
        
        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                
                guard !name.isEmpty else { return }
                
                let phoneNumbers = contact.phoneNumbers.map { $0.value.stringValue }
                let emailAddresses = contact.emailAddresses.map { $0.value as String }
                
                contacts.append(ContactData(
                    name: name,
                    phoneNumbers: phoneNumbers,
                    emailAddresses: emailAddresses
                ))
            }
            
            // Send contacts to watch via BLE
            BLEManager.shared.sendContacts(contacts)
            
            print("Synced \(contacts.count) contacts to watch")
            
        } catch {
            print("Error fetching contacts: \(error.localizedDescription)")
        }
    }
    
    func findContact(phoneNumber: String) -> String? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return nil
        }
        
        let cleanPhoneNumber = phoneNumber.filter { $0.isNumber }
        
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        do {
            var foundName: String?
            try contactStore.enumerateContacts(with: request) { contact, _ in
                for phone in contact.phoneNumbers {
                    let contactNumber = phone.value.stringValue.filter { $0.isNumber }
                    if contactNumber.contains(cleanPhoneNumber) || contactNumber.contains(phoneNumber) {
                        foundName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                        return
                    }
                }
            }
            return foundName
        } catch {
            print("Error finding contact: \(error.localizedDescription)")
            return nil
        }
    }
}

