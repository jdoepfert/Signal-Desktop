// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Combine
import Foundation
import LibSignalClient
import SignalCore
import SignalLogging
import SignalMessaging
import SignalStorage

/// Assembled live stack: every piece the running app needs, built once at
/// link time from the device credentials.
private struct LiveStack {
    let database: SignalDatabase
    let pipe: MessagePipe
    let sender: OutgoingSender
    let receiver: EnvelopeReceiver
    let chat: ChatSession
    let unauth: UnauthChat
    let conversations: ConversationStore
    let contacts: ContactStore
    let messages: MessageStore
    let attachments: AttachmentService
    let attachmentTable: AttachmentTable
    let groups: GroupManager
    let protocolStore: GRDBProtocolStore
}

/// Where the app is in its account lifecycle.
public enum AppPhase: Equatable, Sendable {
    /// Deciding (reading the keychain and database).
    case starting
    /// Fresh install (or after "Start over"): showing the QR link flow.
    case needsLink
    /// Stored data exists but cannot be used; offers "Start over".
    case needsReLink(reason: String)
    case linked
    /// The phone removed this device; offers "Start over".
    case unlinked
    /// Launch hit something a retry can fix (keychain prompt refused,
    /// database busy). Offers Retry; never offers "Start over".
    case couldNotStart(message: String)
}

/// A send refused because the contact's safety number changed; the user
/// can accept the new key and resend.
public struct IdentityChangePrompt: Equatable, Identifiable {
    public let aci: String
    /// `sent_timestamp` of the failed outgoing row to resend.
    public let timestamp: UInt64
    public var id: String { aci }
}

/// Application state: onboarding → linked → conversations. Lives on the
/// main actor; the receive pump forwards pipe messages into the thread view
/// model and conversation list. 1:1 conversations only — group threads
/// light up when group sync lands (sender-key distribution already works).
@MainActor
public final class AppState: ObservableObject {
    @Published public private(set) var phase: AppPhase = .starting
    @Published public var linkedAci: String?
    @Published public var address: String?
    @Published public var conversations: [StoredConversation] = []
    /// The sidebar list binds directly to this property, so loading the
    /// thread must hang off the change itself (`select` is only a helper).
    @Published public var selection: String? {
        didSet {
            guard selection != oldValue else {
                return
            }
            Task {
                await reloadThread()
            }
        }
    }
    @Published public var clockSkewed = false
    @Published public var error: String?
    @Published public var identityPrompt: IdentityChangePrompt?

    public let thread = ConversationViewModel()
    public let composer = ComposerState()
    /// Downloaded attachment bytes by digest (in-memory; the table is the
    /// durable cache). The thread view reads through this.
    public private(set) var attachmentBytes: [Data: Data] = [:]
    /// Threads auto-fetch attachments up to this size on open; larger ones
    /// show as file rows without bytes.
    public static let autoDownloadMaxBytes: UInt64 = 25 * 1024 * 1024

    private let environment: AppEnvironment
    private let lifecycle: AccountLifecycle
    private var stack: LiveStack?
    private var pumpTask: Task<Void, Never>?
    private var launching = false
    private var linkTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "app", category: "lifecycle")

    /// Alert policy for inbound messages; `locked` flips to title-only
    /// when the device locks (device-lock wiring arrives later).
    private let notificationPolicy = NotificationPolicy()
    /// Lazy: `Notifications()` touches `UNUserNotificationCenter`, which
    /// traps outside a running app (e.g. the test harness). First use is
    /// always post-link, in the app.
    private lazy var notifications: Notifications = {
        let notifications = Notifications()
        notifications.onTap = { [weak self] conversationId in
            self?.select(conversationId)
        }
        return notifications
    }()

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.lifecycle = AccountLifecycle(
            databasePath: Self.databasePath(environment: environment),
            keys: KeychainDatabaseKeyStore(
                account: environment == .production ? "db-key-production" : "db-key-staging"
            ),
            environment: environment == .production ? .production : .staging
        )
        composer.onSend = { [weak self] text in
            Task {
                await self?.send(text: text)
            }
        }
        composer.onAttach = { [weak self] in
            Task {
                await self?.attachFile()
            }
        }
    }

    public var isLinked: Bool {
        phase == .linked
    }

    /// Starts `start()` in a task that outlives the calling view.
    public func begin() {
        Task {
            await self.start()
        }
    }

    /// Launch decision: restore a linked account, start the QR flow, or
    /// explain why stored data cannot be used. Runs once per attempt;
    /// further calls while one is running are ignored.
    public func start() async {
        guard phase == .starting, !launching else {
            return
        }
        launching = true
        defer { launching = false }
        switch await lifecycle.launch() {
        case .needsLink:
            beginLink()
        case .restored(let credentials):
            guard let database = await lifecycle.database else {
                phase = .couldNotStart(message: TransientLaunchReason.databaseUnavailable.message)
                return
            }
            // No network yet: the unauthenticated socket connects lazily on
            // first use, and the authenticated one retries in the
            // background, so an offline launch still opens the app.
            let unauth = UnauthChat.live(net: Self.makeNet(environment))
            do {
                try await assemble(credentials: credentials, database: database, unauth: unauth)
            } catch {
                Self.logger.error("start failed (\(ErrorReason.describe(error)))")
                phase = .couldNotStart(
                    message: "Signal could not start (\(ErrorReason.describe(error)))."
                )
            }
        case .needsReLink(let reason):
            phase = .needsReLink(reason: reason)
        case .transientFailure(let reason):
            Self.logger.error("start deferred: \(String(describing: reason))")
            phase = .couldNotStart(message: reason.message)
        }
    }

    /// "Retry" on the could-not-start screen: nothing was changed, so just
    /// launch again.
    public func retry() async {
        guard case .couldNotStart = phase else {
            return
        }
        phase = .starting
        await start()
    }

    /// "Start over": stops everything, deletes the local database and its
    /// key, and returns to the QR link flow. The phone still lists this
    /// Mac under Linked devices until it is removed there.
    public func startOver() async {
        Self.logger.info("start over requested")
        linkTask?.cancel()
        linkTask = nil
        connectTask?.cancel()
        connectTask = nil
        stateTask?.cancel()
        stateTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        if let stack {
            await stack.chat.disconnect()
            await stack.unauth.disconnect()
        }
        stack = nil
        conversations = []
        selection = nil
        thread.replaceAll(with: [])
        linkedAci = nil
        address = nil
        error = nil
        identityPrompt = nil
        do {
            try await lifecycle.reset()
        } catch {
            Self.logger.error("reset failed (\(type(of: error)))")
            self.error = "Could not remove local data: \(type(of: error))"
            phase = .needsReLink(reason: "Removing the local data failed.")
            return
        }
        phase = .starting
        await start()
    }

    private func beginLink() {
        phase = .needsLink
        linkTask?.cancel()
        linkTask = Task {
            await self.link()
        }
    }

    /// Runs the link flow: provisioning address → user scans → envelope →
    /// registration → full stack. Safe to call once; further calls are
    /// ignored.
    public func link() async {
        guard stack == nil, phase == .needsLink else {
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
            if Task.isCancelled {
                try? await session.disconnect()
            } else {
                self.error = "Session closed before an envelope arrived. Re-run to retry."
            }
        } catch {
            if !Task.isCancelled {
                Self.logger.error("link failed (\(type(of: error)))")
                self.error = String(describing: error)
            }
        }
    }

    public func send(text: String) async {
        guard
            let stack,
            let selection,
            !text.isEmpty
        else {
            return
        }
        if selection.hasPrefix("aci:") {
            await sendDirect(text: text, selection: selection)
        } else if selection.hasPrefix("group:") {
            await sendGroup(text: text, selection: selection)
        }
    }

    private func sendDirect(text: String, selection: String) async {
        guard let stack else {
            return
        }
        let aci = String(selection.dropFirst(4))
        do {
            // OutgoingSender writes the outgoing row (status pending) before
            // the network call, updates it to sent/failed, and returns the
            // timestamp that is the row's sent_timestamp.
            _ = try await stack.sender.sendText(text, to: aci)
        } catch SendError.identityChanged(let changedAci) {
            // The failed row is the newest in the thread: offer to accept
            // the new key and resend that row.
            let failed = try? stack.messages.page(in: selection, limit: 1).first
            if let failed, failed.status == MessageStatus.failed {
                identityPrompt = IdentityChangePrompt(aci: changedAci, timestamp: failed.timestamp)
            } else {
                self.error = String(describing: SendError.identityChanged(changedAci))
            }
        } catch {
            self.error = String(describing: error)
        }
        // Success or failure, the row (sent or failed) is in the store.
        refreshConversations()
        await reloadThread()
    }

    /// Group send: the manager fans out sealed sender-key envelopes, then
    /// the sent row persists for the thread. Manager failures (unknown
    /// group) surface as a banner; there is no failed-row retry for groups.
    private func sendGroup(text: String, selection: String) async {
        guard let stack, let linkedAci else {
            return
        }
        let hex = String(selection.dropFirst(6))
        guard let masterKey = Self.masterKey(hex: hex) else {
            self.error = "Cannot send: malformed group conversation."
            return
        }
        do {
            let timestamp = try await stack.groups.sendTextToGroup(text, group: masterKey)
            let message = NewMessage(
                senderAci: linkedAci.lowercased(),
                body: text,
                sentTimestamp: timestamp,
                target: .group(masterKey: masterKey),
                kind: MessageKind.text,
                status: MessageStatus.sent
            )
            try stack.protocolStore.withTransaction { transaction in
                _ = try stack.messages.persist(message, in: transaction)
            }
        } catch {
            self.error = String(describing: error)
        }
        refreshConversations()
        await reloadThread()
    }

    /// Attach button: picks one file, uploads it, and sends it with the
    /// composer's current text as the caption. Upload-first (like Desktop):
    /// a failed upload sends nothing and shows the error instead.
    public func attachFile() async {
        guard
            let stack,
            let selection,
            selection.hasPrefix("aci:")
        else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let contentType =
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?
                .preferredMIMEType) ?? "application/octet-stream"
        do {
            let data = try Data(contentsOf: url)
            guard UInt64(data.count) <= AttachmentService.maxBytes else {
                self.error = "File is larger than 100 MB."
                return
            }
            let caption = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let pointer = try await stack.attachments.upload(data, contentType: contentType)
            composer.text = ""
            _ = try await stack.sender.sendAttachment(
                NewAttachment(
                    digest: pointer.digest,
                    cdnKey: pointer.cdnKey,
                    cdnNumber: pointer.cdnNumber,
                    size: pointer.size,
                    contentType: pointer.contentType,
                    key: pointer.key
                ),
                caption: caption,
                to: String(selection.dropFirst(4))
            )
        } catch SendError.identityChanged(let changedAci) {
            let failed = try? stack.messages.page(in: selection, limit: 1).first
            if let failed, failed.status == MessageStatus.failed {
                identityPrompt = IdentityChangePrompt(aci: changedAci, timestamp: failed.timestamp)
            } else {
                self.error = String(describing: SendError.identityChanged(changedAci))
            }
        } catch {
            self.error = String(describing: error)
        }
        refreshConversations()
        await reloadThread()
    }

    /// "Send anyway" on the safety-number alert: trust the key the server
    /// presents now, then resend the failed message.
    public func acceptIdentityChange(_ prompt: IdentityChangePrompt) async {
        guard let stack else {
            return
        }
        identityPrompt = nil
        do {
            try await stack.sender.acceptNewIdentity(aci: prompt.aci)
            try await stack.sender.resendText(timestamp: prompt.timestamp, to: prompt.aci)
        } catch {
            self.error = String(describing: error)
        }
        refreshConversations()
        await reloadThread()
    }

    public func dismissIdentityChange() {
        identityPrompt = nil
    }

    public func select(_ id: String?) {
        // `selection`'s observer reloads the thread.
        selection = id
    }

    public func cachedName(for aci: String) -> String {
        guard let stack else {
            return aci
        }
        return stack.contacts.cachedName(for: aci)
    }

    public func conversationTitle(for conversation: StoredConversation) -> String {
        // Desktop titles the self thread "Note to Self", never a name or UUID.
        if let linkedAci, conversation.id.lowercased() == "aci:\(linkedAci.lowercased())" {
            return "Note to Self"
        }
        if let name = conversation.name, !name.isEmpty {
            return name
        }
        // Server group titles arrive with a later milestone; until then a
        // stable short handle instead of the raw id.
        if conversation.kind == "group", conversation.id.hasPrefix("group:") {
            return "Group \(conversation.id.dropFirst(6).prefix(8))"
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
            // The "sync" conversation holds phone bookkeeping, never chats.
            conversations = try stack.conversations.allConversations().filter { $0.id != "sync" }
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Ingests pending phone contact-sync batches: downloads each sync
    /// blob by digest and merges its entries. Idempotent (upserts merge),
    /// so crash recovery just re-runs it; failures stay silent and retry
    /// on the next batch.
    private func ingestContactSync() async {
        guard let stack else {
            return
        }
        do {
            let rows = try stack.messages.page(in: "sync", limit: 100)
            var imported = false
            for row in rows {
                guard
                    let digest = row.attachmentDigest,
                    let record = try stack.attachmentTable.load(digest: digest)
                else {
                    continue
                }
                let pointer = AttachmentPointer(
                    cdnKey: record.cdnKey,
                    cdnNumber: record.cdnNumber,
                    digest: record.digest,
                    size: record.size,
                    contentType: record.contentType,
                    key: record.key
                )
                guard let blob = try? await stack.attachments.download(pointer) else {
                    continue
                }
                try ContactSync.ingest(blob: blob, into: stack.contacts)
                imported = true
            }
            if imported {
                refreshConversations()
                objectWillChange.send()
            }
        } catch {
            Self.logger.error("contact sync ingest failed (\(ErrorReason.describe(error)))")
        }
    }

    /// Resolves display names for the listed conversations and the open
    /// thread in the background: unknown ACIs flip to names once their
    /// profiles arrive, with no relink. Safe without a stack (launch
    /// before link) and silent per contact — display falls back to
    /// phone/ACI. Must go through `displayName(for:)` (never around the
    /// cache) so fetched names persist.
    private func resolveMissingNames() async {
        guard let stack else {
            return
        }
        var acis = Set<String>()
        for conversation in conversations where conversation.id.hasPrefix("aci:") {
            acis.insert(String(conversation.id.dropFirst(4)))
        }
        for message in thread.messages {
            acis.insert(message.senderAci)
        }
        guard !acis.isEmpty else {
            return
        }
        for aci in acis {
            // Errors (and unknown contacts) keep the ACI; next arrival retries.
            _ = try? await stack.contacts.displayName(for: aci)
        }
        refreshConversations()
        objectWillChange.send()
    }

    private static func makeNet(_ environment: AppEnvironment) -> Net {
        Net(env: netEnvironment(environment), userAgent: "signal-macos/0.0.0", buildVariant: .production)
    }

    private static func netEnvironment(_ environment: AppEnvironment) -> Net.Environment {
        environment == .production ? .production : .staging
    }

    /// Link path: register this device, then build the same stack a
    /// restore builds.
    private func registerAndBuild(account: ProvisionedAccount) async throws {
        let netEnv = Self.netEnvironment(environment)
        // Connects (and starts the connection) lazily at the link PUT.
        let unauth = UnauthChat.live(net: Self.makeNet(environment))
        let database = try await lifecycle.databaseForLinking()
        let identityStore = GRDBIdentityStore(queue: database.queue)
        let sessionStore = GRDBSessionStore(queue: database.queue)
        let senderKeys = GRDBSenderKeyStore(queue: database.queue)
        let protocolStore = GRDBProtocolStore(
            identity: identityStore,
            session: sessionStore,
            senderKeys: senderKeys
        )
        let registration = LinkedDeviceRegistration(
            transport: LiveRegistrationTransport(chat: unauth),
            store: protocolStore,
            identityStore: identityStore,
            accounts: AccountTable(queue: database.queue)
        )
        let creds = try await registration.register(account: account, environment: netEnv)
        // Desktop keeps the account's own profile key on the self
        // conversation: without it the self profile is unreachable and
        // Note to Self shows a UUID. Best-effort: a failed write must not
        // fail the link (names degrade to ACI).
        try? ContactTable(queue: database.queue).setProfileKey(
            aci: creds.aci.lowercased(),
            profileKey: account.profileKey
        )
        try await assemble(credentials: creds, database: database, unauth: unauth)
    }

    /// Builds the live stack from stored credentials. Shared by the link
    /// path (fresh credentials) and the restore path (credentials read
    /// back at launch); neither registers anything here.
    private func assemble(
        credentials creds: DeviceCredentials,
        database: SignalDatabase,
        unauth: UnauthChat
    ) async throws {
        let identityStore = GRDBIdentityStore(queue: database.queue)
        let sessionStore = GRDBSessionStore(queue: database.queue)
        let senderKeys = GRDBSenderKeyStore(queue: database.queue)
        let protocolStore = GRDBProtocolStore(
            identity: identityStore,
            session: sessionStore,
            senderKeys: senderKeys
        )

        // The delivery certificate needs device auth: it goes over the
        // AUTHENTICATED chat socket (Desktop's getSenderCertificate has no
        // unauthenticated option). The socket is connected below, before any
        // send can ask for the certificate.
        let chat = ChatSession()
        let certFetcher = SenderCertFetcher(send: { request in try await chat.send(request) })
        let certs = SenderCertService(fetch: { try await certFetcher.fetchCertificate() })
        // Prekey fetches fall back to the authenticated GET /v2/keys when
        // we hold no access key for the recipient or it is refused.
        let keyService = LivePreKeyService(
            keys: unauth,
            authenticatedSend: { request in try await chat.send(request) }
        )

        let live = LiveTransport(
            messages: unauth,
            incoming: chat.incoming(),
            authenticatedSend: { request in try await chat.send(request) }
        )
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
            incomingSource: nil
        )
        let conversations = ConversationStore(queue: database.queue)
        let contactTable = ContactTable(queue: database.queue)
        let attachmentTable = AttachmentTable(queue: database.queue)
        let groupTable = GroupStateTable(queue: database.queue)
        let cdn = LiveCDNClient(
            environment: environment,
            formSend: { [chat] request in try await chat.send(request) }
        )
        let attachmentService = AttachmentService(cdn: cdn, attachments: attachmentTable)
        let sender = OutgoingSender(
            store: protocolStore,
            identity: identityStore,
            messages: messages,
            contacts: contactTable,
            conversations: conversations,
            ourAci: creds.aci,
            ourDeviceId: creds.deviceId,
            certs: certs,
            bundles: keyService,
            submitter: live
        )
        // Envelopes acked last session but not yet committed replay BEFORE
        // the socket opens, so they land ahead of anything new.
        await receiver.replayUnprocessed()
        let liveProfiles = LiveProfileFetcher(
            profileKey: { [contactTable] aci in try? contactTable.profileKey(aci: aci) },
            send: { [chat] request in try await chat.send(request) }
        )
        let contacts = ContactStore(
            contacts: contactTable,
            profiles: ProfileFetcher { aci in try await liveProfiles.fetchProfile(for: aci) }
        )
        let ourAddress = try ProtocolAddress(name: creds.aci, deviceId: creds.deviceId)
        let groupSessions = SessionSetup(keys: keyService, store: protocolStore, ourAddress: ourAddress)
        let groupManager = GroupManager(
            store: protocolStore,
            groups: groupTable,
            ourAddress: ourAddress,
            certs: certs,
            sessions: groupSessions,
            sender: live
        )
        stack = LiveStack(
            database: database,
            pipe: pipe,
            sender: sender,
            receiver: receiver,
            chat: chat,
            unauth: unauth,
            conversations: conversations,
            contacts: contacts,
            messages: messages,
            attachments: attachmentService,
            attachmentTable: attachmentTable,
            groups: groupManager,
            protocolStore: protocolStore
        )
        linkedAci = creds.aci
        phase = .linked
        // The receive pump never runs unless the pipe's envelope pump is
        // started: without this the app sends but never receives.
        await pipe.start()
        pumpTask = Task {
            await self.pump()
        }
        // A rejected login (device removed on the phone) is terminal.
        stateTask = Task {
            for await state in chat.stateUpdates() where state == .deviceUnlinked {
                self.handleDeviceUnlinked()
            }
        }
        // Outbox recovery needs the socket (certificate and keys go over
        // it), so it runs after the first successful connect.
        connectTask = Task {
            await self.connectWithRetry(chat: chat, credentials: creds, sender: sender)
        }
        refreshConversations()
        // Best-effort: denial just means no alerts (policy still runs).
        _ = try? await notifications.requestAuthorization()
    }

    /// First connect, retried with backoff while the network is down.
    /// Rejected credentials end the loop (the state stream reports them).
    private func connectWithRetry(
        chat: ChatSession,
        credentials: DeviceCredentials,
        sender: OutgoingSender
    ) async {
        do {
            try await chat.connectRetrying(credentials: credentials) { _ in
                Task { @MainActor in
                    self.error = "Can't reach Signal. Retrying\u{2026}"
                }
            }
            self.error = nil
        } catch {
            // Rejected credentials (the state stream reports them) or
            // cancellation: nothing more to do here.
            return
        }
        if Task.isCancelled {
            return
        }
        // Outbox: rows a crash left pending (older than 30 s) get exactly
        // one retry, then fail.
        _ = await sender.recoverPending(now: Self.nowMs())
        await reloadThread()
        // First connect won: the socket is up, so contact profiles can
        // resolve now (resolution never runs pre-connect, where it could
        // only fail and — before transport errors threw — poison the cache).
        await self.resolveMissingNames()
        // Crash recovery for sync batches, then a first-time sync request:
        // an empty contacts table means the phone never sent its book.
        await self.ingestContactSync()
        if let stack, (try? stack.contacts.count()) == 0 {
            do {
                try await sender.requestContactSync()
            } catch {
                Self.logger.error("contact sync request failed (\(ErrorReason.describe(error)))")
            }
        }
    }

    private func handleDeviceUnlinked() {
        Self.logger.error("device unlinked by the server")
        pumpTask?.cancel()
        pumpTask = nil
        connectTask?.cancel()
        connectTask = nil
        phase = .unlinked
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
                if message.kind == MessageKind.contactSync {
                    // Bookkeeping, not chat: ingest in the background.
                    Task {
                        await self.ingestContactSync()
                    }
                }
                if !message.isOutgoing {
                    // Background: message display, read marks and
                    // notifications must not wait on profile network I/O.
                    Task {
                        await self.resolveMissingNames()
                    }
                }
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
                            body: MessageKind.displayBody(kind: message.kind, body: message.body),
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
        guard stack != nil else {
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
            let digests = stored.compactMap(\.attachmentDigest)
            let records = try stack.attachmentTable.loadMany(digests: digests)
            let byDigest = Dictionary(uniqueKeysWithValues: records.map { ($0.digest, $0) })
            // `thread` is a nested ObservableObject the views do not observe
            // directly: tell the views this object changed.
            objectWillChange.send()
            thread.replaceAll(
                with: stored.map { row in
                    let attachment = row.attachmentDigest.flatMap { digest in
                        byDigest[digest].map {
                            ThreadAttachment(
                                digest: digest,
                                contentType: $0.contentType,
                                size: $0.size
                            )
                        }
                    }
                    return ThreadMessage(
                        rowId: row.rowId,
                        senderAci: row.senderAci,
                        body: row.displayBody,
                        timestamp: row.timestamp,
                        isOutgoing: row.status != nil,
                        attachment: attachment
                    )
                }
            )
            await downloadMissingAttachments(records: records)
            try stack.conversations.markRead(selection)
            refreshConversations()
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Fetches attachment bytes for the open thread (bounded: oversized
    /// files stay as rows without bytes). Cached by digest in memory; the
    /// table is the durable cache. Failures stay silent — the row still
    /// renders as a file.
    private func downloadMissingAttachments(records: [StoredAttachment]) async {
        guard let stack else {
            return
        }
        var fetched = false
        for record in records {
            guard
                attachmentBytes[record.digest] == nil,
                record.size <= Self.autoDownloadMaxBytes
            else {
                continue
            }
            let pointer = AttachmentPointer(
                cdnKey: record.cdnKey,
                cdnNumber: record.cdnNumber,
                digest: record.digest,
                size: record.size,
                contentType: record.contentType,
                key: record.key
            )
            guard let bytes = try? await stack.attachments.download(pointer) else {
                continue
            }
            attachmentBytes[record.digest] = bytes
            fetched = true
        }
        if fetched {
            objectWillChange.send()
        }
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private static func masterKey(hex: String) -> Data? {
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        var bytes = Data()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func databasePath(environment: AppEnvironment) -> String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appending(path: "SignalMac", directoryHint: .isDirectory)
            .appending(path: environment == .production ? "production" : "staging", directoryHint: .isDirectory)
            .appending(path: "db.sqlite")
            .path
    }
}
