// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import LibSignalClient
import Security
import SignalCore
import SignalMessaging
import SignalStorage

/// Assembled live stack: every piece the running app needs, built once at
/// link time from the device credentials.
private struct LiveStack {
    let database: SignalDatabase
    let pipe: MessagePipe
    let receiver: EnvelopeReceiver
    let chat: ChatSession
    let conversations: ConversationStore
    let contacts: ContactStore
    let messages: MessageStore
}

/// Application state: onboarding → linked → conversations. Lives on the
/// main actor; the receive pump forwards pipe messages into the thread view
/// model and conversation list. 1:1 conversations only — group threads
/// light up when group sync lands (sender-key distribution already works).
@MainActor
public final class AppState: ObservableObject {
    @Published public var linkedAci: String?
    @Published public var address: String?
    @Published public var conversations: [StoredConversation] = []
    @Published public var selection: String?
    @Published public var clockSkewed = false
    @Published public var error: String?

    public let thread = ConversationViewModel()
    public let composer = ComposerState()

    private let environment: AppEnvironment
    private var stack: LiveStack?
    private var pumpTask: Task<Void, Never>?

    /// Alert policy for inbound messages; `locked` flips to title-only
    /// when the device locks (device-lock wiring arrives later).
    private let notificationPolicy = NotificationPolicy()
    private let notifications = Notifications()

    public init(environment: AppEnvironment) {
        self.environment = environment
        composer.onSend = { [weak self] text in
            Task {
                await self?.send(text: text)
            }
        }
        notifications.onTap = { [weak self] conversationId in
            self?.select(conversationId)
        }
    }

    public var isLinked: Bool {
        linkedAci != nil
    }

    /// Runs the link flow: provisioning address → user scans → envelope →
    /// registration → full stack. Safe to call once; further calls are
    /// ignored.
    public func link() async {
        guard stack == nil else {
            return
        }
        do {
            let host =
                environment == .production
                ? ChatTransport.productionHost
                : ChatTransport.stagingHost
            let transport = try ChatTransport(host: host)
            let ourKey = PrivateKey.generate()
            let session = try await transport.connect()
            session.start()
            for await event in session.events {
                switch event {
                case .address(let address):
                    self.address = Provisioning.linkURL(
                        address: address,
                        publicKey: ourKey.publicKey
                    ).absoluteString
                case .envelope(let envelope):
                    let account = try Provisioning(ourPrivateKey: ourKey)
                        .decrypt(envelope: envelope)
                    try? await session.disconnect()
                    try await self.registerAndBuild(account: account)
                    return
                }
            }
            self.error = "Session closed before an envelope arrived. Re-run to retry."
        } catch {
            self.error = String(describing: error)
        }
    }

    public func send(text: String) async {
        guard
            let stack,
            let selection,
            selection.hasPrefix("aci:"),
            !text.isEmpty
        else {
            return
        }
        let aci = String(selection.dropFirst(4))
        do {
            try await stack.pipe.sendText(text, to: aci)
            // Persist our side so the thread shows both directions.
            if let ownAci = linkedAci {
                _ = try stack.messages.save(
                    senderAci: ownAci,
                    body: text,
                    timestamp: Self.nowMs(),
                    conversationId: selection
                )
            }
            _ = try stack.conversations.conversation(forAci: aci)
            try stack.conversations.touch(selection, timestamp: Self.nowMs())
            refreshConversations()
            await reloadThread()
        } catch {
            self.error = String(describing: error)
        }
    }

    public func select(_ id: String?) {
        selection = id
        Task {
            await reloadThread()
        }
    }

    public func cachedName(for aci: String) -> String {
        guard let stack else {
            return aci
        }
        return stack.contacts.cachedName(for: aci)
    }

    public func conversationTitle(for conversation: StoredConversation) -> String {
        if let name = conversation.name, !name.isEmpty {
            return name
        }
        if conversation.id.hasPrefix("aci:") {
            return cachedName(for: String(conversation.id.dropFirst(4)))
        }
        return conversation.id
    }

    public func toggleMute(_ conversation: StoredConversation) {
        guard let stack else {
            return
        }
        do {
            try stack.conversations.setMuted(conversation.id, muted: !conversation.muted)
            refreshConversations()
        } catch {
            self.error = String(describing: error)
        }
    }

    public func refreshConversations() {
        guard let stack else {
            return
        }
        do {
            conversations = try stack.conversations.allConversations()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func registerAndBuild(account: ProvisionedAccount) async throws {
        let netEnv: Net.Environment = environment == .production ? .production : .staging
        let net = Net(env: netEnv, userAgent: "signal-macos/0.0.0", buildVariant: .production)
        let unauth = try await net.connectUnauthenticatedChat()
        let database = try SignalDatabase.open(
            path: Self.databasePath(environment: environment),
            key: try Self.databaseKey(environment: environment)
        )
        let identityStore = GRDBIdentityStore(queue: database.queue)
        let sessionStore = GRDBSessionStore(queue: database.queue)
        let senderKeys = GRDBSenderKeyStore(queue: database.queue)
        let protocolStore = GRDBProtocolStore(
            identity: identityStore,
            session: sessionStore,
            senderKeys: senderKeys
        )
        let registration = LinkedDeviceRegistration(
            transport: LiveRegistrationTransport(connection: unauth),
            store: protocolStore,
            identityStore: identityStore,
            accounts: AccountTable(queue: database.queue)
        )
        let creds = try await registration.register(account: account, environment: netEnv)

        let certFetcher = SenderCertFetcher(fetch: { [unauth] path in
            let response = try await unauth.send(
                ChatRequest(method: "GET", pathAndQuery: path, timeout: 30)
            )
            guard (200..<300).contains(response.status) else {
                throw LinkRegistrationError.rejected(status: response.status)
            }
            struct CertJSON: Decodable {
                let certificate: String
            }
            guard let json = try? JSONDecoder().decode(CertJSON.self, from: response.body),
                  let bytes = Data(base64Encoded: json.certificate)
            else {
                throw LinkRegistrationError.invalidResponse
            }
            return bytes
        })
        let certs = SenderCertService(fetch: { try await certFetcher.fetchCertificate() })
        let keyService = LivePreKeyService(keys: unauth)
        let sessions = SessionSetup(
            keys: keyService,
            store: protocolStore,
            ourAddress: try ProtocolAddress(name: creds.aci, deviceId: creds.deviceId)
        )

        let chat = ChatSession()
        let live = LiveTransport(messages: unauth, incoming: chat.incoming())
        let messages = MessageStore(queue: database.queue)
        let trustRoots = TrustRoots.forEnvironment(environment)
        let receiver = try EnvelopeReceiver(
            store: protocolStore,
            unprocessed: UnprocessedStore(queue: database.queue),
            messages: messages,
            ourAci: creds.aci,
            ourDeviceId: creds.deviceId,
            trustRoots: trustRoots
        )
        let pipe = MessagePipe(
            transport: live,
            certs: certs,
            store: protocolStore,
            ourAddress: try ProtocolAddress(name: creds.aci, deviceId: creds.deviceId),
            trustRoots: trustRoots,
            receiver: receiver,
            incomingSource: nil,
            devicesForRecipient: { recipient in
                try await sessions.ensureAllSessions(with: recipient).map { device in
                    (deviceId: device.deviceId, registrationId: device.registrationId)
                }
            }
        )
        // Envelopes acked last session but not yet committed replay BEFORE
        // the socket opens, so they land ahead of anything new.
        await receiver.replayUnprocessed()
        try await chat.connect(credentials: creds)
        let conversations = ConversationStore(queue: database.queue)
        let contacts = ContactStore(
            contacts: ContactTable(queue: database.queue),
            profiles: ProfileFetcher { _ in nil }
        )
        stack = LiveStack(
            database: database,
            pipe: pipe,
            receiver: receiver,
            chat: chat,
            conversations: conversations,
            contacts: contacts,
            messages: messages
        )
        linkedAci = creds.aci
        // The receive pump never runs unless the pipe's envelope pump is
        // started: without this the app sends but never receives.
        await pipe.start()
        pumpTask = Task {
            await self.pump()
        }
        refreshConversations()
        // Best-effort: denial just means no alerts (policy still runs).
        _ = try? await notifications.requestAuthorization()
    }

    private func pump() async {
        guard let stack else {
            return
        }
        for await message in stack.pipe.incoming() {
            do {
                // The receiver already committed the row, the conversation
                // link, recency and unread count in the decrypt transaction.
                refreshConversations()
                guard let conversation = conversations.first(where: { $0.id == message.conversationId })
                else {
                    continue
                }
                if selection == conversation.id {
                    if !message.isOutgoing {
                        try stack.conversations.markRead(conversation.id)
                    }
                    refreshConversations()
                    await reloadThread()
                } else if !message.isOutgoing {
                    await deliverNotification(
                        message: DecryptedMessage(
                            senderAci: message.senderAci,
                            body: message.body,
                            timestamp: message.timestamp
                        ),
                        conversation: conversation
                    )
                }
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    private func deliverNotification(message: DecryptedMessage, conversation: StoredConversation) async {
        guard let stack else {
            return
        }
        let title = conversationTitle(for: conversation)
        let decision = notificationPolicy.decide(
            message: message,
            displayName: title,
            muted: conversation.muted
        )
        guard decision != .silent else {
            return
        }
        do {
            try await notifications.deliver(decision, conversationId: conversation.id)
        } catch {
            // Notification delivery is best-effort; never fails the pump.
        }
    }

    private func reloadThread() async {
        guard let stack, let selection else {
            return
        }
        do {
            // Thread-scoped: only messages linked to this conversation.
            // Group scoping by conversation id arrives with group sync.
            let stored = try stack.messages.page(in: selection, limit: 500)
            thread.replaceAll(
                with: stored.map {
                    ThreadMessage(
                        rowId: $0.rowId,
                        senderAci: $0.senderAci,
                        body: $0.body,
                        timestamp: $0.timestamp
                    )
                }
            )
            try stack.conversations.markRead(selection)
            refreshConversations()
        } catch {
            self.error = String(describing: error)
        }
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private static func databasePath(environment: AppEnvironment) throws -> String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = base
            .appending(path: "SignalMac", directoryHint: .isDirectory)
            .appending(path: environment == .production ? "production" : "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "db.sqlite").path
    }

    private static func databaseKey(environment: AppEnvironment) throws -> String {
        let account = environment == .production ? "db-key-production" : "db-key-staging"
        if let existing = try KeychainStore.load(service: "org.signal.signal-mac", account: account),
           let key = String(data: existing, encoding: .utf8)
        {
            return key
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ProvisioningError.envelopeInvalid
        }
        let key = Data(bytes).base64EncodedString()
        try KeychainStore.save(Data(key.utf8), service: "org.signal.signal-mac", account: account)
        return key
    }
}
