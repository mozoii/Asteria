import AsteriaKit

extension ClientIdentityVault {
    static var appKeychain: ClientIdentityVault {
        ClientIdentityVault(
            secretStore: KeychainSecretStore(service: "io.github.mozoii.Asteria")
        )
    }
}
