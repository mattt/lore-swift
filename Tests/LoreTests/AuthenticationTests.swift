import CryptoKit
import Foundation
import Testing

@testable import Lore

/// Tests of logging in and of the token store.
///
/// The token store belongs to the process,
/// so these tests run one at a time,
/// and each starts with an empty store.
/// No test prints a token:
/// expectations compare ``Authentication/Token`` values,
/// whose descriptions omit the token.
@Suite(.serialized) struct AuthenticationTests {
    let authenticationURL = "ucs-auth://auth.example.test"

    init() async throws {
        _ = isolatedHome
        try await Authentication.removeAllCredentials()
    }

    @Test func storeStartsEmpty() async throws {
        #expect(try await Authentication.credentials().isEmpty)
        #expect(try await Authentication.localUsers(authenticationURL: authenticationURL).isEmpty)
        let users = try await Authentication.localUsers(withIDs: ["bob"], authenticationURL: authenticationURL)
        #expect(users == [Authentication.User(id: "bob", name: "bob")])
    }

    @Test func tokenLoginStoresTheToken() async throws {
        let expiration = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 3600).rounded(.down))
        let token = try makeToken(
            subject: "alice",
            name: "Alice Liddell",
            preferredUsername: "alice.liddell",
            rootDomains: ["example.test"],
            expiration: expiration
        )
        let user = try await Authentication.logIn(token: token, authenticationURL: authenticationURL)
        #expect(user == Authentication.User(id: "alice", name: "alice.liddell"))

        let credentials = try await Authentication.credentials()
        #expect(credentials.count == 1)
        let credential = try #require(credentials.first)
        #expect(credential.authenticationURL == authenticationURL)
        #expect(credential.resource == nil)
        #expect(credential.userID == "alice")
        #expect(credential.authorizedDomains == ["example.test", "auth.example.test"])
        #expect(credential.expirationDate == expiration)
        #expect(credential.token == nil)

        let withTokens = try await Authentication.credentials(includingTokens: true)
        #expect(withTokens.first?.token == Authentication.Token(token))
    }

    @Test func localUsersReadStoredTokens() async throws {
        let expiration = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 3600).rounded(.down))
        let token = try makeToken(
            subject: "alice",
            name: "Alice Liddell",
            preferredUsername: "alice.liddell",
            rootDomains: ["example.test"],
            expiration: expiration
        )
        try await Authentication.logIn(token: token, authenticationURL: authenticationURL)

        let current = try await Authentication.localUsers(authenticationURL: authenticationURL)
        #expect(current.map(\.id) == ["alice"])
        #expect(current.first?.identityToken == nil)

        let users = try await Authentication.localUsers(
            withIDs: ["alice", "bob"],
            authenticationURL: authenticationURL,
            includingTokens: true
        )
        #expect(users.map(\.id) == ["alice", "bob"])
        #expect(users.last == Authentication.User(id: "bob", name: "bob"))
        let alice = try #require(users.first)
        #expect(alice.name == "Alice Liddell")
        #expect(
            alice.identityToken
                == Authentication.IdentityToken(
                    token: Authentication.Token(token),
                    preferredUsername: "alice.liddell",
                    isServiceAccount: false,
                    expirationDate: expiration
                )
        )

        let otherService = try await Authentication.localUsers(
            withIDs: ["alice"],
            authenticationURL: "ucs-auth://other.example.test"
        )
        #expect(otherService == [Authentication.User(id: "alice", name: "alice")])
    }

    @Test func logOutRemovesCredentials() async throws {
        let otherURL = "https://auth.other.test"
        try await Authentication.logIn(
            token: try makeToken(subject: "alice", rootDomains: ["example.test"]),
            authenticationURL: authenticationURL
        )
        try await Authentication.logIn(
            token: try makeToken(subject: "bob", rootDomains: ["example.test"]),
            authenticationURL: authenticationURL
        )
        try await Authentication.logIn(
            token: try makeToken(subject: "carol", rootDomains: ["other.test"]),
            authenticationURL: otherURL
        )
        #expect(try await Authentication.credentials().map(\.userID).sorted() == ["alice", "bob", "carol"])

        try await Authentication.logOut(from: authenticationURL, user: "alice")
        #expect(try await Authentication.credentials().map(\.userID).sorted() == ["bob", "carol"])

        try await Authentication.logOut(from: authenticationURL)
        #expect(try await Authentication.credentials().map(\.userID) == ["carol"])

        try await Authentication.logOut(from: authenticationURL)
        try await Authentication.removeAllCredentials()
        #expect(try await Authentication.credentials().isEmpty)
    }

    @Test func tokenLoginChecksTheDomain() async throws {
        let token = try makeToken(subject: "alice", rootDomains: ["elsewhere.test"])
        let error = await #expect(throws: LoreError.self) {
            try await Authentication.logIn(token: token, authenticationURL: authenticationURL)
        }
        #expect(error?.code == .internal)
        #expect(error?.message.contains("example.test") == true)
        #expect(try await Authentication.credentials().isEmpty)

        let unnamed = try makeToken(subject: "alice", rootDomains: nil)
        await #expect(throws: LoreError.self) {
            try await Authentication.logIn(token: unnamed, authenticationURL: authenticationURL)
        }
        await #expect(throws: LoreError.self) {
            try await Authentication.logIn(token: "not a token", authenticationURL: authenticationURL)
        }
    }

    @Test func tokenLoginNeedsAServer() async throws {
        let token = try makeToken(subject: "alice", rootDomains: ["example.test"])
        let error = await #expect(throws: LoreError.self) {
            try await Authentication.logIn(token: token)
        }
        #expect(error?.code == .noRemote)
    }

    @Test func repositoryWithoutServer() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.logOut()
        }
        #expect(error?.code == .noRemote)
        await #expect(throws: LoreError.self) {
            try await repository.localUsers()
        }
    }

    @Test func descriptionsOmitTokens() async throws {
        let token = try makeToken(subject: "alice", rootDomains: ["example.test"])
        try await Authentication.logIn(token: token, authenticationURL: authenticationURL)
        let credential = try #require(try await Authentication.credentials(includingTokens: true).first)
        let users = try await Authentication.localUsers(
            withIDs: ["alice"],
            authenticationURL: authenticationURL,
            includingTokens: true
        )
        let user = try #require(users.first)
        #expect(user.identityToken != nil)

        var dumped = ""
        dump(credential, to: &dumped)
        dump(user, to: &dumped)
        let descriptions = [
            String(describing: credential),
            String(reflecting: credential),
            String(describing: user),
            String(reflecting: user),
            String(describing: credential.token),
            "\(Authentication.Token(token))",
            dumped,
        ]
        for description in descriptions {
            #expect(!description.contains(token), "A description includes the token")
            #expect(!description.contains(token.prefix(20)), "A description includes the token")
        }
        #expect(String(describing: Authentication.Token(token)) == "Token(redacted)")
    }

    /// Tests against the local server that accepts every request.
    @Suite(.integration) struct OpenServer {
        @Test func tokenLoginNeedsAnAuthenticationService() async throws {
            _ = isolatedHome
            let token = try makeToken(subject: "alice", rootDomains: ["127.0.0.1"])
            let error = await #expect(throws: LoreError.self) {
                try await Authentication.logIn(token: token, server: serverURL)
            }
            #expect(error?.code == .notSupported)

            let interactive = await #expect(throws: LoreError.self) {
                for try await _ in Authentication.logInInteractively(server: serverURL) {}
            }
            #expect(interactive?.code == .notSupported)
        }

        @Test func usersHaveTheirIDsAsNames() async throws {
            let path = temporaryRepositoryPath("users")
            let repository = try await Repository.create(
                at: path,
                name: "\(serverURL)/\(URL(filePath: path).lastPathComponent)",
                options: Repository.Options(identity: "alice@example.com")
            )
            let users = try await repository.users(withIDs: ["alice@example.com", "bob@example.com"])
            #expect(
                users.sorted { $0.id < $1.id } == [
                    Authentication.User(id: "alice@example.com", name: "alice@example.com"),
                    Authentication.User(id: "bob@example.com", name: "bob@example.com"),
                ]
            )
        }
    }

    /// Tests against the local server that requires tokens
    /// from the stub identity provider that `Scripts/run-integration-tests.sh` starts.
    @Suite(.authenticatedServer) struct AuthenticatedServer {
        let server: String
        let issuer: String
        let key: P256.Signing.PrivateKey

        init() async throws {
            _ = isolatedHome
            try await Authentication.removeAllCredentials()
            let environment = ProcessInfo.processInfo.environment
            server = try #require(environment["LORE_AUTHENTICATED_SERVER_URL"])
            issuer = try #require(environment["LORE_IDENTITY_PROVIDER_URL"])
            let keyPath = try #require(environment["LORE_SIGNING_KEY"])
            key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: keyPath, encoding: .utf8))
        }

        /// The URL under which the library stores the provider's tokens.
        var authenticationURL: String {
            "oidc+\(issuer)"
        }

        /// Makes a token that the server accepts.
        func token(for subject: String, name: String? = nil) throws -> String {
            try makeToken(subject: subject, name: name, issuer: issuer, rootDomains: ["127.0.0.1"], key: key)
        }

        @Test func tokenLoginAuthenticatesOperations() async throws {
            let path = temporaryRepositoryPath("authenticated")
            let url = "\(server)/\(URL(filePath: path).lastPathComponent)"
            let options = Repository.Options(identity: "alice")

            let unauthenticated = await #expect(throws: LoreError.self) {
                try await Repository.create(at: path, name: url, options: options)
            }
            #expect(unauthenticated?.code == .notAuthenticated)

            let user = try await Authentication.logIn(token: try token(for: "alice", name: "Alice"), server: server)
            #expect(user == Authentication.User(id: "alice", name: "Alice"))
            let credentials = try await Authentication.credentials()
            #expect(credentials.map(\.authenticationURL) == [authenticationURL])
            #expect(credentials.map(\.userID) == ["alice"])

            try? FileManager.default.removeItem(atPath: path)
            let repository = try await Repository.create(at: path, name: url, options: options)
            try repository.write("hello\n", to: "a.txt")
            try await repository.stage(["a.txt"])
            try await repository.commit(message: "First")
            try await repository.push()
            #expect(try await repository.info().creator == "alice")

            let users = try await repository.users(withIDs: ["alice", "bob"])
            #expect(
                users.sorted { $0.id < $1.id } == [
                    Authentication.User(id: "alice", name: "Alice"), Authentication.User(id: "bob", name: "bob"),
                ]
            )
            #expect(try await repository.localUsers().map(\.id) == ["alice"])

            let access = try await repository.accessCredential()
            #expect(access.authenticationURL == authenticationURL)
            #expect(access.userID == "alice")
            #expect(access.resource == (try await repository.info().id.description))
            #expect(access.token != nil)
            #expect(try await Authentication.credentials().compactMap(\.resource) == [access.resource])

            try await repository.logOut(user: "alice")
            #expect(try await Authentication.credentials().isEmpty)
            let unauthorized = await #expect(throws: LoreError.self) {
                try await repository.push()
            }
            #expect(unauthorized?.code == .notAuthorized)
        }

        @Test func repositoryLoginUsesItsServer() async throws {
            try await Authentication.logIn(token: try token(for: "alice"), server: server)
            let path = temporaryRepositoryPath("authenticated")
            let repository = try await Repository.create(
                at: path,
                name: "\(server)/\(URL(filePath: path).lastPathComponent)",
                options: Repository.Options(identity: "alice")
            )
            try await Authentication.removeAllCredentials()

            let user = try await repository.logIn(token: try token(for: "alice", name: "Alice"))
            #expect(user == Authentication.User(id: "alice", name: "Alice"))
            #expect(try await Authentication.credentials().map(\.authenticationURL) == [authenticationURL])
        }

        @Test func interactiveLogin() async throws {
            let token = try token(for: "dana", name: "Dana")
            var progress: [Authentication.LoginProgress] = []
            var result: Authentication.User?
            for try await update in Authentication.logInInteractively(server: server) {
                switch update {
                case .progress(let update):
                    progress.append(update)
                    if case .openURL(_, let userCode?) = update {
                        try await approve(userCode: userCode, token: token)
                    }
                case .completed(let user):
                    result = user
                }
            }
            #expect(result == Authentication.User(id: "dana", name: "Dana"))
            guard case .openURL(let url, let userCode)? = progress.first else {
                Issue.record("The login reported no URL")
                return
            }
            #expect(url == "\(issuer)/activate")
            #expect(userCode?.count == 9)
            #expect(try await Authentication.credentials().map(\.userID) == ["dana"])
        }

        /// Approves a login at the stub identity provider, as the user would.
        private func approve(userCode: String, token: String) async throws {
            var request = URLRequest(url: try #require(URL(string: "\(issuer)/approve")))
            request.httpMethod = "POST"
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "user_code", value: userCode), URLQueryItem(name: "access_token", value: token),
            ]
            request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
    }
}

/// Makes a JSON Web Token with the claims that Lore reads,
/// signed with ES256.
///
/// The library doesn't check signatures when it stores a token;
/// a server that requires tokens checks them against the key
/// that its identity provider publishes.
func makeToken(
    subject: String,
    name: String? = nil,
    preferredUsername: String? = nil,
    issuer: String = "https://issuer.example.test",
    audience: [String] = ["lore-tests"],
    rootDomains: [String]?,
    expiration: Date = .now + 3600,
    key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()
) throws -> String {
    var claims: [String: Any] = [
        "iss": issuer,
        "sub": subject,
        "aud": audience,
        "iat": Int(Date.now.timeIntervalSince1970),
        "exp": Int(expiration.timeIntervalSince1970),
    ]
    claims["name"] = name
    claims["preferred_username"] = preferredUsername
    claims["root_domains"] = rootDomains
    let header: [String: Any] = ["alg": "ES256", "typ": "JWT", "kid": "test"]
    func encode(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    let input = "\(try encode(header)).\(try encode(claims))"
    let signature = try key.signature(for: Data(input.utf8))
    return "\(input).\(base64URL(signature.rawRepresentation))"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
