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

        // A URL that names no stored credentials, such as a server's, removes nothing.
        try await Authentication.logOut(authenticationURL: "lore://auth.example.test:41337")
        #expect(try await Authentication.credentials().count == 3)

        try await Authentication.logOut(authenticationURL: authenticationURL, userID: "alice")
        #expect(try await Authentication.credentials().map(\.userID).sorted() == ["bob", "carol"])

        try await Authentication.logOut(authenticationURL: authenticationURL, resource: "unknown")
        #expect(try await Authentication.credentials().map(\.userID) == ["carol"])

        try await Authentication.logOut(authenticationURL: authenticationURL)
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

    @Test func emptyURLsAreRejected() async throws {
        let token = try makeToken(subject: "alice", rootDomains: ["example.test"])
        let errors = [
            await #expect(throws: LoreError.self) {
                try await Authentication.logIn(token: token, remote: "")
            },
            await #expect(throws: LoreError.self) {
                try await Authentication.logIn(token: token, authenticationURL: "")
            },
            await #expect(throws: LoreError.self) {
                for try await _ in Authentication.logInInteractively(remote: "") {}
            },
            await #expect(throws: LoreError.self) {
                try await Authentication.logOut(authenticationURL: "")
            },
            await #expect(throws: LoreError.self) {
                try await Authentication.localUsers(authenticationURL: "")
            },
        ]
        #expect(errors.map { $0?.code } == Array(repeating: .invalidArguments, count: 5))
        #expect(try await Authentication.credentials().isEmpty)
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
            let leaked = description.contains(token) || description.contains(token.prefix(20))
            #expect(!leaked, "A description includes the token")
        }
        #expect(String(describing: Authentication.Token(token)) == "Token(redacted)")
    }

    /// Tests against the local server that accepts every request.
    @Suite(.integration) struct OpenServer {
        @Test func tokenLoginNeedsAnAuthenticationService() async throws {
            _ = isolatedHome
            let token = try makeToken(subject: "alice", rootDomains: ["127.0.0.1"])
            let error = await #expect(throws: LoreError.self) {
                try await Authentication.logIn(token: token, remote: serverURL)
            }
            #expect(error?.code == .notSupported)

            let interactive = await #expect(throws: LoreError.self) {
                for try await _ in Authentication.logInInteractively(remote: serverURL) {}
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

            let user = try await Authentication.logIn(token: try token(for: "alice", name: "Alice"), remote: server)
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
            #expect(try await repository.users() == [Authentication.User(id: "alice", name: "Alice")])
            #expect(try await repository.localUsers().map(\.id) == ["alice"])

            let authorization = try await repository.authorizationCredential()
            #expect(authorization.authenticationURL == authenticationURL)
            #expect(authorization.userID == "alice")
            #expect(authorization.resource == (try await repository.info().id.description))
            #expect(authorization.token != nil)
            #expect(try await Authentication.credentials().compactMap(\.resource) == [authorization.resource])

            try await repository.logOut(userID: "alice", resource: authorization.resource)
            let remaining = try await Authentication.credentials()
            #expect(remaining.map(\.userID) == ["alice"])
            #expect(remaining.map(\.resource) == [nil])
            #expect(try await repository.authorizationCredential().resource == authorization.resource)

            try await repository.logOut(resource: authorization.resource)
            #expect(try await Authentication.credentials().isEmpty)
            let unauthorized = await #expect(throws: LoreError.self) {
                try await repository.push()
            }
            #expect(unauthorized?.code == .notAuthorized)
        }

        @Test func repositoryLoginUsesItsServer() async throws {
            try await Authentication.logIn(token: try token(for: "alice"), remote: server)
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

        /// Deletes only a repository that this suite creates on the local server.
        @Test func onlyTheCreatorDeletesARepositoryFromTheServer() async throws {
            try await Authentication.logIn(token: try token(for: "alice"), remote: server)
            let alice = Repository.Options(identity: "alice")
            let path = temporaryRepositoryPath("deleted")
            let url = "\(server)/\(URL(filePath: path).lastPathComponent)"
            let repository = try await Repository.create(at: path, name: url, options: alice)
            try repository.write("hello\n", to: "a.txt")
            try await repository.stage(["a.txt"])
            try await repository.commit(message: "First")
            try await repository.push()
            try await Repository.clone(from: url, to: temporaryRepositoryPath("clone"), options: alice)

            try await Authentication.logIn(token: try token(for: "bob"), remote: server)
            let refused = await #expect(throws: LoreError.self) {
                try await Repository.deleteFromServer(url, options: Repository.Options(identity: "bob"))
            }
            #expect(refused?.code == .notAuthorized)

            try await repository.deleteFromServer()
            let clone = await #expect(throws: LoreError.self) {
                try await Repository.clone(from: url, to: temporaryRepositoryPath("clone"), options: alice)
            }
            #expect(clone?.code == .notFound)
            let again = await #expect(throws: LoreError.self) {
                try await Repository.deleteFromServer(url, options: alice)
            }
            #expect(again?.code == .notFound)
            #expect(try repository.read("a.txt") == "hello\n")

            // A push from the checkout still succeeds,
            // and the server still doesn't find the repository.
            try repository.write("two\n", to: "a.txt")
            try await repository.stage(["a.txt"])
            try await repository.commit(message: "Second")
            let push = try await repository.push()
            #expect(push.revisionNumber == 2)
            let afterPush = await #expect(throws: LoreError.self) {
                try await Repository.clone(from: url, to: temporaryRepositoryPath("clone"), options: alice)
            }
            #expect(afterPush?.code == .notFound)
            let info = await #expect(throws: LoreError.self) {
                try await repository.info()
            }
            #expect(info?.code == .notFound)
        }

        @Test func interactiveLogin() async throws {
            let (progress, user) = try await logInInteractively(
                Authentication.logInInteractively(remote: server),
                approvingWith: try token(for: "dana", name: "Dana")
            )
            #expect(user == Authentication.User(id: "dana", name: "Dana"))
            guard case .approvalRequested(let url, let userCode)? = progress.first else {
                Issue.record("The login reported no URL")
                return
            }
            #expect(url == "\(issuer)/activate")
            #expect(userCode?.count == 9)

            // The stub provider gives the login 60 seconds
            // and asks for a poll every second.
            let pending = progress.dropFirst()
            #expect(!pending.isEmpty)
            for update in pending {
                guard case .pending(let elapsed, let nextPoll, let remaining) = update else {
                    Issue.record("Unexpected update after the URL: \(update)")
                    continue
                }
                #expect(nextPoll == .seconds(1))
                #expect(remaining > .zero && remaining <= .seconds(60))
                #expect(elapsed < remaining)
            }
            #expect(try await Authentication.credentials().map(\.userID) == ["dana"])
        }

        @Test func repositoryInteractiveLoginUsesItsServer() async throws {
            try await Authentication.logIn(token: try token(for: "dana"), remote: server)
            let path = temporaryRepositoryPath("authenticated")
            let repository = try await Repository.create(
                at: path,
                name: "\(server)/\(URL(filePath: path).lastPathComponent)",
                options: Repository.Options(identity: "dana")
            )
            try await Authentication.removeAllCredentials()

            let (progress, user) = try await logInInteractively(
                repository.logInInteractively(),
                approvingWith: try token(for: "dana", name: "Dana")
            )
            #expect(user == Authentication.User(id: "dana", name: "Dana"))
            guard case .approvalRequested(let url, _)? = progress.first else {
                Issue.record("The login reported no URL")
                return
            }
            #expect(url == "\(issuer)/activate")
            #expect(try await Authentication.credentials().map(\.authenticationURL) == [authenticationURL])
        }

        @Test func repositoryLogOutRevokesTheRefreshToken() async throws {
            let repository = try await makeRepository()
            let refreshToken = "refresh-\(UUID().uuidString)"
            try await logInInteractively(
                repository.logInInteractively(),
                approvingWith: try token(for: "erin"),
                refreshToken: refreshToken
            )
            #expect(try await isRevoked(refreshToken) == false)

            try await repository.logOut(userID: "erin")
            #expect(try await isRevoked(refreshToken))
            #expect(try await Authentication.credentials().isEmpty)
        }

        @Test func failedRevocationThrowsAfterTheLogOut() async throws {
            let repository = try await makeRepository()
            // The stub provider refuses to revoke this token.
            try await logInInteractively(
                repository.logInInteractively(),
                approvingWith: try token(for: "erin"),
                refreshToken: "unrevocable-\(UUID().uuidString)"
            )

            await #expect(throws: LoreError.self) {
                try await repository.logOut(userID: "erin")
            }
            #expect(try await Authentication.credentials().isEmpty)
        }

        @Test func logOutWithAnAuthenticationURLDoesNotRevoke() async throws {
            let repository = try await makeRepository()
            let refreshToken = "refresh-\(UUID().uuidString)"
            try await logInInteractively(
                repository.logInInteractively(),
                approvingWith: try token(for: "erin"),
                refreshToken: refreshToken
            )

            try await Authentication.logOut(authenticationURL: authenticationURL, userID: "erin")
            #expect(try await isRevoked(refreshToken) == false)
            #expect(try await Authentication.credentials().isEmpty)
        }

        @Test func repositoryLogOutRevokesAServerLogin() async throws {
            let repository = try await makeRepository()
            let refreshToken = "refresh-\(UUID().uuidString)"
            try await logInInteractively(
                Authentication.logInInteractively(remote: server),
                approvingWith: try token(for: "erin"),
                refreshToken: refreshToken
            )

            try await repository.logOut(userID: "erin")
            #expect(try await isRevoked(refreshToken))
            #expect(try await Authentication.credentials().isEmpty)
        }

        /// Creates a repository on the server
        /// and leaves the token store empty.
        private func makeRepository() async throws -> Repository {
            try await Authentication.logIn(token: try token(for: "erin"), remote: server)
            let path = temporaryRepositoryPath("authenticated")
            let repository = try await Repository.create(
                at: path,
                name: "\(server)/\(URL(filePath: path).lastPathComponent)",
                options: Repository.Options(identity: "erin")
            )
            try await Authentication.removeAllCredentials()
            return repository
        }

        /// Runs an interactive login and approves it
        /// after the first pending update,
        /// so that the login reports at least one.
        @discardableResult
        private func logInInteractively(
            _ updates: AsyncThrowingStream<
                OperationUpdate<Authentication.LoginProgress, Authentication.User>, any Error
            >,
            approvingWith token: String,
            refreshToken: String? = nil
        ) async throws -> (progress: [Authentication.LoginProgress], user: Authentication.User?) {
            var progress: [Authentication.LoginProgress] = []
            var userCode: String?
            var user: Authentication.User?
            for try await update in updates {
                switch update {
                case .progress(let update):
                    progress.append(update)
                    switch update {
                    case .approvalRequested(_, let code):
                        userCode = code
                    case .pending:
                        if let code = userCode {
                            try await approve(userCode: code, token: token, refreshToken: refreshToken)
                            userCode = nil
                        }
                    }
                case .completed(let completed):
                    user = completed
                }
            }
            return (progress, user)
        }

        /// Approves a login at the stub identity provider, as the user would.
        private func approve(userCode: String, token: String, refreshToken: String?) async throws {
            var fields = ["user_code": userCode, "access_token": token]
            fields["refresh_token"] = refreshToken
            let (_, status) = try await post(fields, to: "approve")
            #expect(status == 200)
        }

        /// Returns whether the stub identity provider revoked a refresh token.
        private func isRevoked(_ refreshToken: String) async throws -> Bool {
            let (data, _) = try await post(["token": refreshToken], to: "revoked")
            let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return try #require(reply?["revoked"] as? Bool)
        }

        /// Posts a form to the stub identity provider
        /// and returns the reply and its status code.
        private func post(_ fields: [String: String], to path: String) async throws -> (Data, Int?) {
            var request = URLRequest(url: try #require(URL(string: "\(issuer)/\(path)")))
            request.httpMethod = "POST"
            var form = URLComponents()
            form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode)
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
