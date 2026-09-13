import Foundation

/// What a followed turn produced.
public struct RunResult: Sendable, Equatable {
  public let conversationID: String
  /// Where a human reads the transcript.
  public let url: URL
  public let turnNumber: Int
  /// The answer: tool noise dropped, paragraphs joined.
  public let text: String
  /// Tools in the order they were first used.
  public let toolsUsed: [String]
  public let state: TurnState
  public let exitCode: Int?
  public let reason: String?
  /// The conversation's status once the turn ended; nil if it couldn't be
  /// re-read (the turn's own outcome is already in `state`).
  public let status: ConversationStatus?

  /// A turn that ended any way other than `done`. It is still a result,
  /// not an error — the agent ran and reported.
  public var isFailure: Bool { state != .done }
}

/// One turn, followed from the log stream: the answer, the tools, the end
/// state. Build one with `FountainClient.run` or `ConversationsResource.run`.
///
/// ```swift
/// let run = try await client.run("Review this repo", agent: agentID)
/// for try await event in run.events {
///     if case .text(let chunk) = event { print(chunk, terminator: "") }
/// }
/// let result = try await run.value()
/// ```
///
/// `events` and `value()` may each be called any number of times, from
/// anywhere: the turn is followed once and every subscriber sees the whole
/// stream from the beginning. Failures of the *turn* arrive as a `RunResult`
/// with a non-`done` state; failures of the *client* (HTTP, transport, the
/// deadline) are thrown.
public final class Run: @unchecked Sendable {
  public let conversationID: String
  /// The conversation as it was when the turn was queued.
  public let conversation: Conversation
  /// Which turn of the conversation this is (1 for a fresh one).
  public let turnNumber: Int
  /// Where a human reads the transcript.
  public let url: URL

  private let client: APIClient
  private let after: Int
  private let timeout: TimeInterval?

  private let lock = NSLock()
  private var follower: TurnFollower
  private var log: [TurnEvent] = []
  private var subscribers: [UUID: AsyncThrowingStream<TurnEvent, any Error>.Continuation] = [:]
  private var outcome: Result<RunResult, any Error>?
  private var waiters: [CheckedContinuation<RunResult, any Error>] = []
  /// Set when the conversation ended under the turn rather than with it.
  private var failureReason: String?
  private var task: Task<Void, Never>?

  init(
    client: APIClient,
    conversation: Conversation,
    turnNumber: Int,
    after: Int,
    timeout: TimeInterval?
  ) {
    self.client = client
    self.conversation = conversation
    self.conversationID = conversation.id
    self.turnNumber = turnNumber
    self.after = after
    self.timeout = timeout
    self.url = client.config.conversationURL(conversation.id)
    self.follower = TurnFollower(turnNumber: turnNumber)
    self.task = Task { [weak self] in await self?.follow() }
  }

  deinit { task?.cancel() }

  /// Every piece of the turn, from the beginning. A late subscriber gets
  /// what it missed replayed before the live remainder.
  public var events: AsyncThrowingStream<TurnEvent, any Error> {
    AsyncThrowingStream { continuation in
      let id = UUID()
      lock.lock()
      let replay = log
      let settled = outcome
      if settled == nil { subscribers[id] = continuation }
      lock.unlock()

      for event in replay { continuation.yield(event) }
      switch settled {
      case .success: continuation.finish()
      case .failure(let error): continuation.finish(throwing: error)
      case nil:
        continuation.onTermination = { [weak self] _ in self?.drop(id) }
      }
    }
  }

  /// Wait for the turn to end.
  public func value() async throws -> RunResult {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let outcome {
        lock.unlock()
        continuation.resume(with: outcome)
        return
      }
      waiters.append(continuation)
      lock.unlock()
    }
  }

  /// The text the agent has produced so far.
  public var partialText: String {
    lock.lock()
    defer { lock.unlock() }
    return follower.text
  }

  /// Answer a permission request with one of the options the agent offered.
  public func answer(requestID: String, optionID: String) async throws {
    try await ConversationsResource(client: client)
      .answer(conversationID, requestID: requestID, optionID: optionID)
  }

  /// Stop the current turn, server-side. The run then ends `interrupted`.
  public func interrupt() async throws {
    try await ConversationsResource(client: client).interrupt(conversationID)
  }

  /// Tear the sandbox down. Anything still streaming stops.
  public func terminate() async throws {
    try await ConversationsResource(client: client).terminate(conversationID)
  }

  /// Stop watching. The turn keeps running in the sandbox — use
  /// `interrupt()` to actually stop it.
  public func cancel() {
    lock.lock()
    let task = self.task
    lock.unlock()
    task?.cancel()
    settle(.failure(CancellationError()))
  }

  // MARK: following

  private func follow() async {
    emit(.conversation(conversation, url: url))
    do {
      try await withDeadline()
      let (ended, died) = read { ($0, failureReason) }
      // Re-read for the conversation's own status; the turn's outcome
      // is already known, so a failure here is not worth the run.
      let status = try? await ConversationsResource(client: client).get(conversationID).status
      // No turn-end of its own: failed if the conversation died under
      // it, otherwise the stream simply stopped arriving.
      let state = ended.state ?? (died == nil ? .timeout : .failed)
      if !ended.finished {
        emit(.turnEnd(state: state, exitCode: ended.exitCode, reason: died))
      }
      settle(
        .success(
          RunResult(
            conversationID: conversationID,
            url: url,
            turnNumber: turnNumber,
            text: ended.text,
            toolsUsed: ended.tools,
            state: state,
            exitCode: ended.exitCode,
            reason: ended.reason ?? died,
            status: status
          )))
    } catch is DeadlineReached {
      settle(.failure(FountainError.timedOut(partialText: partialText)))
    } catch {
      settle(.failure(error))
    }
  }

  /// The stream, racing the client-side deadline when there is one.
  private func withDeadline() async throws {
    guard let timeout else { return try await consume() }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await self.consume() }
      group.addTask {
        try await self.client.sleepForRunDeadline(UInt64(max(0, timeout) * 1_000_000_000))
        throw DeadlineReached()
      }
      // Whichever lands first decides; the group cancels the other.
      try await group.next()
      group.cancelAll()
    }
  }

  private func consume() async throws {
    let conversations = ConversationsResource(client: client)
    let stream = conversations.stream(conversationID, StreamRequest(after: after))
    for try await event in stream {
      guard case .log(let logEvent) = event else { continue }
      let (produced, finished) = mutate { follower -> ([TurnEvent], Bool) in
        let produced = follower.apply(logEvent)
        return (produced, follower.finished)
      }
      for turnEvent in produced { emit(turnEvent) }
      if finished { return }

      // A conversation can die without ever ending its turn — the
      // sandbox goes away, or the conversation server exits. Waiting
      // for a turn-end that will never arrive is the bug this avoids.
      if Self.mayEnd(logEvent),
        let status = try? await conversations.get(conversationID).status,
        status.isTerminal
      {
        died(of: Self.reason(logEvent))
        return
      }
      try Task.checkCancellation()
    }
    // A clean close with no turn-end: the tail gave up. Whatever the
    // follower saw is what there is.
  }

  /// Stage events that can mean the conversation itself is over.
  private static func mayEnd(_ event: LogEvent) -> Bool {
    guard event.kind == .stage, let stage = event.stage, stage != "turn" else { return false }
    return event.state == .failed || ["terminate", "sandbox", "server"].contains(stage)
  }

  private static func reason(_ event: LogEvent) -> String {
    let stage = event.stage ?? "stage"
    let state = event.state?.rawValue ?? "unknown"
    let detail =
      event.stageData?["message"]?.stringValue
      ?? event.stageData?["reason"]?.stringValue
    return detail.map { "\(stage)/\(state): \($0)" } ?? "\(stage)/\(state)"
  }

  // MARK: state

  private func died(of reason: String) {
    lock.lock()
    failureReason = reason
    lock.unlock()
  }

  private func read<T>(_ body: (TurnFollower) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(follower)
  }

  private func mutate<T>(_ body: (inout TurnFollower) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&follower)
  }

  private func emit(_ event: TurnEvent) {
    lock.lock()
    log.append(event)
    let listeners = Array(subscribers.values)
    lock.unlock()
    for listener in listeners { listener.yield(event) }
  }

  private func drop(_ id: UUID) {
    lock.lock()
    subscribers[id] = nil
    lock.unlock()
  }

  private func settle(_ result: Result<RunResult, any Error>) {
    lock.lock()
    guard outcome == nil else { return lock.unlock() }
    outcome = result
    let listeners = Array(subscribers.values)
    let pending = waiters
    subscribers = [:]
    waiters = []
    lock.unlock()

    for listener in listeners {
      switch result {
      case .success: listener.finish()
      case .failure(let error): listener.finish(throwing: error)
      }
    }
    for waiter in pending { waiter.resume(with: result) }
  }
}

private struct DeadlineReached: Error {}

extension FountainClient {
  /// Open a conversation and follow its first turn.
  ///
  /// `agent` is an agent id. A turn that fails is a `RunResult` with a
  /// non-`done` state, not a thrown error; `timeout` is client-side only —
  /// it stops the waiting, never the turn.
  public func run(
    _ prompt: String,
    agent: String,
    vault: String? = nil,
    environment: String? = nil,
    title: String? = nil,
    images: [ImageInput]? = nil,
    permissionPolicy: [String: String]? = nil,
    sandboxMode: SandboxMode? = nil,
    sandboxID: String? = nil,
    channelID: String? = nil,
    fresh: Bool? = nil,
    timeout: TimeInterval? = nil
  ) async throws -> Run {
    let opened = try await conversations.create(
      ConversationCreateRequest(
        agentID: agent,
        prompt: prompt,
        title: title,
        vaultID: vault,
        environmentID: environment,
        permissionPolicy: permissionPolicy,
        images: images,
        sandboxMode: sandboxMode,
        sandboxID: sandboxID,
        channelID: channelID,
        fresh: fresh
      ))
    // A channel id can land on an existing conversation, where the prompt
    // queued a later turn than the first. Nothing else resumes, so
    // nothing else pays for the extra round trip.
    var turnNumber = 1
    if channelID != nil, opened.resumed {
      turnNumber = try await nextTurnNumber(opened.conversation.id)
    }
    return Run(
      client: api,
      conversation: opened.conversation,
      turnNumber: turnNumber,
      after: 0,
      timeout: timeout
    )
  }

  private func nextTurnNumber(_ id: String) async throws -> Int {
    (try await conversations.turns(id).map(\.turnNumber).max() ?? 0) + 1
  }
}

extension ConversationsResource {
  /// Queue a follow-up turn and follow it.
  ///
  /// Reads the feed's head first, so the turn is followed from the present
  /// instead of replaying the transcript, and numbers the turn before
  /// queueing it — a `conversation_busy` throw then means nothing was sent.
  public func run(
    _ id: String,
    prompt: String,
    images: [ImageInput]? = nil,
    timeout: TimeInterval? = nil
  ) async throws -> Run {
    let after = await cursor(id)
    let turnNumber = (try await turns(id).map(\.turnNumber).max() ?? 0) + 1
    try await self.prompt(id, prompt, images: images)
    let conversation = try await get(id)
    return Run(
      client: client,
      conversation: conversation,
      turnNumber: turnNumber,
      after: after,
      timeout: timeout
    )
  }

  /// The newest log-event id on this conversation, or 0 when the feed is
  /// empty or unreadable — from `0` a follow just replays, which is safe.
  public func cursor(_ id: String) async -> Int {
    var last = 0
    do {
      for try await event in stream(
        id, StreamRequest(streams: [.stage], wait: false, maxRetries: 0))
      {
        if case .log(let logEvent) = event, let eventID = logEvent.id {
          last = max(last, eventID)
        }
      }
    } catch {
      return last
    }
    return last
  }
}
