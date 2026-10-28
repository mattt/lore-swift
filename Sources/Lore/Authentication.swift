import CLore
import Foundation

/// Logging in to Lore servers and managing the credentials
/// that the library stores for the current user.
///
/// The library keeps credentials in a token store in its per-user directory,
/// encrypted with a key that it keeps in the login keychain when it can.
/// When it can't store the key in the keychain,
/// it writes the key to a plain-text file next to the token store.
/// Set `LORE_AUTH_STORE` to `fallback` in the environment
/// to always keep the key in that file.
/// The file isn't protected,
/// so anyone who can read the directory can decrypt the stored tokens;
/// the setting is meant for tests and continuous integration.
/// Set `LORE_AUTH_PATH` to move the token store to another directory.
///
/// Each credential belongs to an authentication service,
/// which a server advertises to its clients.
/// Methods that take an `authenticationURL` use that service directly;
/// the methods of ``Repository`` with the same names
/// find the service from the repository's server.
public enum Authentication {}

extension Authentication {
    /// A user that the library identifies.
    public struct User: Sendable, Hashable, Identifiable {
        /// The identifier of the user.
        public var id: String

        /// The display name of the user,
        /// or the identifier if the library has no name for the user.
        public var name: String

        /// Details of the user's stored identity token,
        /// for a user that ``Authentication/localUsers(withIDs:authenticationURL:includingTokens:)``
        /// or ``Repository/localUsers(withIDs:includingTokens:)``
        /// returns with `includingTokens` set,
        /// or `nil`.
        public var identityToken: IdentityToken?

        init(id: String, name: String, identityToken: IdentityToken? = nil) {
            self.id = id
            self.name = name
            self.identityToken = identityToken
        }
    }

    /// A stored identity token and the claims that the library reads from it.
    public struct IdentityToken: Sendable, Hashable {
        /// The token.
        public var token: Token

        /// The preferred username in the token,
        /// or `nil` if the token has none.
        public var preferredUsername: String?

        /// A Boolean value that indicates whether the token
        /// identifies a service account.
        public var isServiceAccount: Bool

        /// The time the token expires,
        /// or `nil` if the token doesn't say.
        public var expirationDate: Date?
    }

    /// A credential in the library's token store.
    ///
    /// The store holds two kinds of credential:
    /// an authentication token, which proves the user's identity
    /// to an authentication service and has no ``resource``,
    /// and an authorization token, which grants access to one resource,
    /// such as a repository.
    public struct Credential: Sendable, Hashable {
        /// The URL of the authentication service that the credential belongs to.
        ///
        /// For a server that uses an OpenID Connect provider,
        /// this is the provider's issuer URL with the prefix `oidc+`,
        /// such as `oidc+https://accounts.example.com`.
        public var authenticationURL: String

        /// The resource that an authorization token grants access to,
        /// such as the identifier of a repository,
        /// or `nil` for an authentication token.
        public var resource: String?

        /// The identifier of the user.
        public var userID: String

        /// The root domains of the servers that the library may send the token to.
        public var authorizedDomains: [String]

        /// The time the token expires,
        /// or `nil` if the library doesn't know.
        public var expirationDate: Date?

        /// The token,
        /// or `nil` if you didn't ask for it.
        public var token: Token?
    }

    /// A secret token.
    ///
    /// The ``description`` and ``debugDescription`` of a token
    /// don't include its value,
    /// so printing, logging, or dumping a value that holds a token
    /// doesn't reveal the token.
    /// Read ``value`` to use it.
    public struct Token: Sendable, Hashable {
        /// The text of the token.
        public var value: String

        /// Creates a token with the given text.
        public init(_ value: String) {
            self.value = value
        }
    }

    /// The kind of token that a token login presents.
    ///
    /// The library stores a ``lore`` token as it is.
    /// It exchanges a token of another kind,
    /// such as an API key that the authentication service accepts,
    /// for a Lore token at the authentication service.
    public struct TokenType: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral {
        /// The name of the kind of token.
        public var rawValue: String

        /// Creates a token type from its name.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.init(rawValue: value)
        }

        /// A Lore token: a JSON Web Token that the authentication service issued.
        public static let lore: Self = "lore"
    }

    /// The progress of an interactive login.
    public enum LoginProgress: Sendable, Hashable {
        /// The login waits for the user to open a URL and approve the login,
        /// entering or confirming the code if there is one.
        case openURL(String, userCode: String?)

        /// The user hasn't approved the login yet,
        /// and the library is about to wait before it asks the service again.
        ///
        /// - Parameters:
        ///   - elapsed: The time since the library started to ask.
        ///   - nextPoll: The time until the library asks again.
        ///   - remaining: The time left before the login expires.
        case pending(elapsed: Duration, nextPoll: Duration, remaining: Duration)
    }
}

extension Authentication.Token: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A description that doesn't include the token.
    public var description: String {
        "Token(redacted)"
    }

    /// A description that doesn't include the token.
    public var debugDescription: String {
        description
    }

    /// A mirror with no children,
    /// so that `dump(_:)` doesn't show the token.
    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

// MARK: - Logging in

extension Authentication {
    /// Logs in to a server with a token and stores it for later operations.
    ///
    /// The library asks the server for its authentication service.
    /// It accepts a ``TokenType/lore`` token
    /// only if the token names the server's domain
    /// in its `root_domains` claim or its audience.
    /// The library doesn't check the token's signature;
    /// the server checks it when an operation presents the token.
    ///
    /// - Parameters:
    ///   - token: The token.
    ///   - type: The kind of token.
    ///   - server: The URL of the server,
    ///     such as `lore://lore.example.com:41337`.
    /// - Returns: The user that the token identifies.
    /// - Throws: ``LoreError`` if the library can't log in,
    ///   such as ``LoreError/Code/notSupported``
    ///   for a server that doesn't use authentication,
    ///   or ``LoreError/Code/invalidArguments`` for an empty server URL.
    @discardableResult
    public static func logIn(
        token: String,
        type: TokenType = .lore,
        server: String
    ) async throws -> User {
        try requireURL(server, "server URL")
        return try await context.logIn(token: token, type: type, server: server, authenticationURL: nil)
    }

    /// Logs in at an authentication service with a token
    /// and stores it for later operations.
    ///
    /// The library doesn't contact the service for a ``TokenType/lore`` token.
    /// It accepts the token only if the token names the service's domain
    /// in its `root_domains` claim or its audience,
    /// and it doesn't check the token's signature;
    /// a server checks it when an operation presents the token.
    ///
    /// - Parameters:
    ///   - token: The token.
    ///   - type: The kind of token.
    ///   - authenticationURL: The URL of the authentication service,
    ///     such as `ucs-auth://auth.example.com`.
    /// - Returns: The user that the token identifies.
    /// - Throws: ``LoreError`` if the library can't log in,
    ///   or ``LoreError/Code/invalidArguments``
    ///   for an empty authentication URL.
    @discardableResult
    public static func logIn(
        token: String,
        type: TokenType = .lore,
        authenticationURL: String
    ) async throws -> User {
        try requireURL(authenticationURL, "authentication URL")
        return try await context.logIn(token: token, type: type, server: nil, authenticationURL: authenticationURL)
    }

    /// Logs in through the authentication service of a server,
    /// with a URL that the user opens and approves,
    /// and stores the resulting token for later operations.
    ///
    /// The library doesn't open a browser.
    /// The stream reports the URL for the user to open
    /// and the code, if any, for the user to enter or confirm there.
    /// Then it reports each wait while the library asks the service
    /// whether the user approved the login,
    /// and ends with the user who logged in.
    ///
    /// ```swift
    /// for try await update in Authentication.logInInteractively(server: url) {
    ///     switch update {
    ///     case .progress(.openURL(let url, let userCode)):
    ///         print("Open", url, "and enter", userCode ?? "nothing")
    ///     case .progress(.pending):
    ///         break
    ///     case .completed(let user):
    ///         print("Logged in as", user.name)
    ///     }
    /// }
    /// ```
    ///
    /// The login starts when you call this method,
    /// whether or not you iterate the stream,
    /// and continues until the user approves it or it expires.
    ///
    /// - Parameter server: The URL of the server,
    ///   such as `lore://lore.example.com:41337`.
    /// - Returns: A stream of the login's progress, then the user.
    ///   The stream throws ``LoreError`` if the login fails or expires,
    ///   such as ``LoreError/Code/notSupported``
    ///   for a server that doesn't use authentication,
    ///   or ``LoreError/Code/invalidArguments`` for an empty server URL.
    public static func logInInteractively(
        server: String
    ) -> AsyncThrowingStream<OperationUpdate<LoginProgress, User>, any Error> {
        do {
            try requireURL(server, "server URL")
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return context.logInInteractively(server: server)
    }

    /// Returns the credentials in the token store.
    ///
    /// - Parameter includingTokens: Whether to decrypt the tokens
    ///   and include them in the result.
    /// - Returns: The stored credentials.
    /// - Throws: ``LoreError`` if the library can't read the token store.
    public static func credentials(includingTokens: Bool = false) async throws -> [Credential] {
        try await context.perform(
            lore_auth_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_auth_list_args_t>, _) in
                arguments.pointee.with_token = UInt8(includingTokens)
            },
            transform: { event -> Credential? in
                guard event.pointee.tag == LORE_EVENT_AUTH_IDENTITY.rawValue else {
                    return nil
                }
                return Credential(event.pointee.auth_identity)
            }
        )
    }

    /// Removes stored credentials for an authentication service.
    ///
    /// The library removes nothing, and doesn't throw,
    /// if it has no credentials for the URL.
    ///
    /// - Parameters:
    ///   - authenticationURL: The URL of the authentication service,
    ///     as the ``Credential/authenticationURL`` of its credentials gives it,
    ///     including the `oidc+` prefix for an OpenID Connect provider.
    ///     A server's URL doesn't match its credentials.
    ///   - userID: The identifier of the user whose credentials to remove,
    ///     or `nil` for every user.
    ///   - resource: The resource whose authorization token to remove,
    ///     or `nil` for the user's authentication token
    ///     and all of the user's authorization tokens.
    ///     The library ignores the resource if `userID` is `nil`.
    /// - Throws: ``LoreError`` if the library can't update the token store,
    ///   or ``LoreError/Code/invalidArguments``
    ///   for an empty authentication URL.
    public static func logOut(
        authenticationURL: String,
        userID: String? = nil,
        resource: String? = nil
    ) async throws {
        try requireURL(authenticationURL, "authentication URL")
        try await context.logOut(authenticationURL: authenticationURL, userID: userID, resource: resource)
    }

    /// Removes every credential from the token store.
    ///
    /// - Throws: ``LoreError`` if the library can't update the token store.
    public static func removeAllCredentials() async throws {
        _ = try await context.perform(
            lore_auth_clear_async,
            configure: { (_: UnsafeMutablePointer<lore_auth_clear_args_t>, _) in },
            transform: { _ -> Never? in nil }
        )
    }

    /// Returns the users with the given identifiers,
    /// with the names that the stored tokens give them.
    ///
    /// This method doesn't contact a server.
    /// A user without a stored token has the identifier as its name.
    ///
    /// - Parameters:
    ///   - ids: The identifiers of the users,
    ///     or an empty array for the first user
    ///     with a stored token for the service.
    ///   - authenticationURL: The URL of the authentication service.
    ///   - includingTokens: Whether to include the stored identity token
    ///     of each user who has one.
    /// - Returns: The users,
    ///   or an empty array if `ids` is empty and no user has a stored token.
    /// - Throws: ``LoreError`` if the library can't read the token store,
    ///   or ``LoreError/Code/invalidArguments``
    ///   for an empty authentication URL.
    public static func localUsers(
        withIDs ids: [String] = [],
        authenticationURL: String,
        includingTokens: Bool = false
    ) async throws -> [User] {
        try requireURL(authenticationURL, "authentication URL")
        return try await context.localUsers(
            withIDs: ids,
            authenticationURL: authenticationURL,
            includingTokens: includingTokens
        )
    }

    /// The context for calls that don't belong to a repository.
    ///
    /// Its empty path gives the library an empty repository path
    /// and working directory.
    /// The library resolves an empty server or authentication URL
    /// from the repository in the current directory of the process,
    /// so the methods that use this context reject empty URLs
    /// with `requireURL(_:_:)`.
    private static var context: Repository {
        Repository(path: "")
    }

    /// Throws ``LoreError/Code/invalidArguments`` for an empty URL.
    private static func requireURL(_ url: String, _ name: String) throws {
        if url.isEmpty {
            throw LoreError(code: .invalidArguments, message: "The \(name) is empty.")
        }
    }
}

// MARK: - Repository

extension Repository {
    /// Logs in to the repository's server with a token
    /// and stores it for later operations.
    ///
    /// See ``Authentication/logIn(token:type:server:)``.
    ///
    /// - Parameters:
    ///   - token: The token.
    ///   - type: The kind of token.
    /// - Returns: The user that the token identifies.
    /// - Throws: ``LoreError`` if the library can't log in,
    ///   such as ``LoreError/Code/notSupported``
    ///   for a server that doesn't use authentication.
    @discardableResult
    public func logIn(
        token: String,
        type: Authentication.TokenType = .lore
    ) async throws -> Authentication.User {
        try await logIn(token: token, type: type, server: nil, authenticationURL: nil)
    }

    /// Logs in to the repository's server
    /// with a URL that the user opens and approves.
    ///
    /// See ``Authentication/logInInteractively(server:)``.
    ///
    /// - Returns: A stream of the login's progress, then the user.
    ///   The stream throws ``LoreError`` if the login fails or expires.
    public func logInInteractively() -> AsyncThrowingStream<
        OperationUpdate<Authentication.LoginProgress, Authentication.User>, any Error
    > {
        logInInteractively(server: nil)
    }

    /// Removes stored credentials for the authentication service
    /// of the repository's server.
    ///
    /// The library asks the server for its authentication service.
    ///
    /// - Parameters:
    ///   - userID: The identifier of the user whose credentials to remove,
    ///     or `nil` for every user.
    ///   - resource: The resource whose authorization token to remove,
    ///     or `nil` for the user's authentication token
    ///     and all of the user's authorization tokens.
    ///     The library ignores the resource if `userID` is `nil`.
    /// - Throws: ``LoreError`` if the library can't update the token store,
    ///   such as ``LoreError/Code/noRemote`` for a repository without a server.
    public func logOut(userID: String? = nil, resource: String? = nil) async throws {
        try await logOut(authenticationURL: nil, userID: userID, resource: resource)
    }

    /// Returns the users with the given identifiers,
    /// with the names that the server's user directory gives them.
    ///
    /// A server without a user directory
    /// names the user that the stored token identifies after the token,
    /// and every other user after its identifier.
    ///
    /// - Parameter ids: The identifiers of the users,
    ///   or an empty array for the current user,
    ///   whom ``localUsers(withIDs:includingTokens:)`` resolves.
    /// - Returns: The users, in no particular order.
    /// - Throws: ``LoreError`` if the library can't resolve the users.
    public func users(withIDs ids: [String] = []) async throws -> [Authentication.User] {
        try await perform(
            lore_auth_user_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_auth_user_info_args_t>, arena) in
                arguments.pointee.user_ids = arena.strings(ids)
            },
            transform: AuthenticationEvent.user
        )
    }

    /// Returns the users with the given identifiers,
    /// with the names that the stored tokens give them.
    ///
    /// The library asks the repository's server for its authentication service,
    /// then reads the tokens of that service.
    /// A user without a stored token has the identifier as its name.
    ///
    /// - Parameters:
    ///   - ids: The identifiers of the users,
    ///     or an empty array for the current user:
    ///     the identity in the repository's options if it has one,
    ///     or else the first user with a stored token for the service.
    ///   - includingTokens: Whether to include the stored identity token
    ///     of each user who has one.
    /// - Returns: The users.
    /// - Throws: ``LoreError`` if the library can't read the token store,
    ///   such as ``LoreError/Code/noRemote`` for a repository without a server.
    public func localUsers(
        withIDs ids: [String] = [],
        includingTokens: Bool = false
    ) async throws -> [Authentication.User] {
        try await localUsers(withIDs: ids, authenticationURL: nil, includingTokens: includingTokens)
    }

    /// Returns the current user's authorization token for the repository,
    /// which operations on the repository present to the server.
    ///
    /// The library uses a stored token that hasn't expired.
    /// Otherwise it gets one from the authentication service
    /// and stores it.
    ///
    /// - Returns: The credential, with its token.
    /// - Throws: ``LoreError`` if the library can't get a token.
    public func accessCredential() async throws -> Authentication.Credential {
        let events = try await perform(
            lore_auth_local_user_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_auth_local_user_info_args_t>, _) in
                arguments.pointee.with_access_token = 1
            },
            transform: AuthenticationEvent.init
        )
        for case .credential(let credential) in events.reversed() {
            return credential
        }
        throw LoreError.missingEvent("an authorization token")
    }
}

// MARK: - Implementation

extension Repository {
    fileprivate func logIn(
        token: String,
        type: Authentication.TokenType,
        server: String?,
        authenticationURL: String?
    ) async throws -> Authentication.User {
        let users = try await perform(
            lore_auth_login_with_token_async,
            configure: { (arguments: UnsafeMutablePointer<lore_auth_login_with_token_args_t>, arena) in
                arguments.pointee.remote_url = arena.string(server)
                arguments.pointee.token = arena.string(token)
                arguments.pointee.token_type = arena.string(type.rawValue)
                arguments.pointee.auth_url = arena.string(authenticationURL)
            },
            transform: AuthenticationEvent.user
        )
        guard let user = users.last else {
            throw LoreError.missingEvent("the user")
        }
        return user
    }

    fileprivate func logInInteractively(
        server: String?
    ) -> AsyncThrowingStream<OperationUpdate<Authentication.LoginProgress, Authentication.User>, any Error> {
        updates(
            lore_auth_login_interactive_async,
            configure: { (arguments: UnsafeMutablePointer<lore_auth_login_interactive_args_t>, arena) in
                arguments.pointee.remote_url = arena.string(server)
                // The caller shows the URL; the binding never opens a browser.
                arguments.pointee.no_browser = 1
            },
            transform: AuthenticationEvent.init,
            progress: { event in
                if case .progress(let progress) = event { progress } else { nil }
            },
            result: { events in
                for case .user(let user) in events.reversed() {
                    return user
                }
                throw LoreError.missingEvent("the user")
            }
        )
    }

    fileprivate func logOut(authenticationURL: String?, userID: String?, resource: String?) async throws {
        _ = try await perform(
            lore_auth_logout_async,
            configure: { (arguments: UnsafeMutablePointer<lore_auth_logout_args_t>, arena) in
                arguments.pointee.auth_url = arena.string(authenticationURL)
                arguments.pointee.user_id = arena.string(userID)
                arguments.pointee.resource = arena.string(resource)
            },
            transform: { _ -> Never? in nil }
        )
    }

    fileprivate func localUsers(
        withIDs ids: [String],
        authenticationURL: String?,
        includingTokens: Bool
    ) async throws -> [Authentication.User] {
        try await perform(
            lore_auth_local_user_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_auth_local_user_info_args_t>, arena) in
                arguments.pointee.auth_endpoint = arena.string(authenticationURL)
                arguments.pointee.user_ids = arena.strings(ids)
                arguments.pointee.with_identity_token = UInt8(includingTokens)
            },
            transform: AuthenticationEvent.user
        )
    }
}

/// An event of an authentication call.
private enum AuthenticationEvent: Sendable {
    case user(Authentication.User)
    case credential(Authentication.Credential)
    case progress(Authentication.LoginProgress)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_AUTH_USER_INFO.rawValue:
            let data = event.pointee.auth_user_info
            self = .user(Authentication.User(id: String(data.id), name: String(data.name)))
        case LORE_EVENT_AUTH_USER_TOKEN.rawValue:
            let data = event.pointee.auth_user_token
            let preferredUsername = String(data.preferred_username)
            self = .user(
                Authentication.User(
                    id: String(data.id),
                    name: String(data.name),
                    identityToken: Authentication.IdentityToken(
                        token: Authentication.Token(String(data.token)),
                        preferredUsername: preferredUsername.isEmpty ? nil : preferredUsername,
                        isServiceAccount: Bool(data.flag_service_account),
                        expirationDate: data.expires == 0 ? nil : Date(millisecondsSince1970: data.expires)
                    )
                )
            )
        case LORE_EVENT_AUTH_IDENTITY.rawValue:
            self = .credential(Authentication.Credential(event.pointee.auth_identity))
        case LORE_EVENT_AUTH_URL.rawValue:
            let data = event.pointee.auth_url
            let userCode = String(data.user_code)
            self = .progress(.openURL(String(data.url), userCode: userCode.isEmpty ? nil : userCode))
        case LORE_EVENT_AUTH_PENDING.rawValue:
            let data = event.pointee.auth_pending
            self = .progress(
                .pending(
                    elapsed: .seconds(data.elapsed_secs),
                    nextPoll: .seconds(data.interval_secs),
                    remaining: .seconds(data.remaining_secs)
                )
            )
        default:
            return nil
        }
    }

    /// Converts the events that carry a user.
    @Sendable static func user(_ event: UnsafePointer<lore_event_t>) -> Authentication.User? {
        if case .user(let user) = AuthenticationEvent(event) { user } else { nil }
    }
}

extension Authentication.Credential {
    /// Copies the data of an identity event.
    init(_ data: lore_auth_identity_event_data_t) {
        let resource = String(data.resource)
        let token = String(data.token)
        self.init(
            authenticationURL: String(data.auth_url),
            resource: resource.isEmpty ? nil : resource,
            userID: String(data.user_id),
            // The library joins the domains with ", ".
            authorizedDomains: String(data.authorized_domains)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            expirationDate: data.expires == 0 ? nil : Date(millisecondsSince1970: data.expires),
            token: token.isEmpty ? nil : Authentication.Token(token)
        )
    }
}
