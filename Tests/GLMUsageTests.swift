import XCTest
@testable import Codenotch

/// Guards the shape of `GET /api/monitor/usage/quota/limit`. It is not a
/// published API, so these are the tests that will fail first if Z.ai changes
/// it.
final class GLMQuotaResponseTests: XCTestCase {
    private func parse(_ json: String) throws -> GLMUsage.Payload {
        try GLMUsage.parse(Data(json.utf8))
    }

    /// Trimmed from a real response: the envelope rides under HTTP 200, and
    /// the session window's reset time is milliseconds since the epoch.
    private let live = """
    { "code": 200, "success": true, "msg": "",
      "data": { "level": "pro",
        "limits": [
          { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12.5,
            "currentValue": 1250000, "usage": 12000000,
            "nextResetTime": 1788682200000 },
          { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 8.1,
            "nextResetTime": 1789190400000 },
          { "type": "TIME_LIMIT", "percentage": 4.0,
            "currentValue": 40, "usage": 1000 } ] } }
    """

    func testDecodesTheLiveShape() throws {
        let payload = try parse(live)
        XCTAssertEqual(payload.windows.map(\.duration), [18000, 604800, nil])
        XCTAssertEqual(payload.level, "pro")
        XCTAssertEqual(payload.windows.map(\.id), ["session", "weekly", "mcp"])
        XCTAssertEqual(payload.windows[0].label, "Current session")
        XCTAssertEqual(payload.windows[0].usedFraction ?? -1, 0.125, accuracy: 0.0001)
        XCTAssertEqual(payload.windows[1].label, "Weekly")
        XCTAssertEqual(payload.windows[2].label, "MCP (1 month)")
    }

    /// Milliseconds, not seconds — parsed as seconds the reset lands in
    /// January 1970 and the countdown reads as overdue forever.
    func testResetTimesAreMillisecondsSinceTheEpoch() throws {
        let windows = try parse(live).windows
        XCTAssertEqual(windows[0].resetsAt?.timeIntervalSince1970 ?? -1,
                       1_788_682_200, accuracy: 0.001)
    }

    func testSessionSortsFirstWhateverOrderTheEndpointLists() throws {
        let reversed = """
        { "code": 200, "success": true,
          "data": { "limits": [
            { "type": "TIME_LIMIT", "percentage": 4.0 },
            { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 8.1 },
            { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12.5 } ] } }
        """
        XCTAssertEqual(try parse(reversed).windows.map(\.id), ["session", "weekly", "mcp"])
    }

    /// Unlike Claude's windows, a row without a reset time is kept: the MCP
    /// allowance never carries one, and dropping it would hide a real quota.
    func testAWindowWithoutAResetTimeIsKept() throws {
        let noResets = """
        { "code": 200, "success": true,
          "data": { "limits": [ { "type": "TIME_LIMIT", "percentage": 4.0 } ] } }
        """
        let windows = try parse(noResets).windows
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].resetsAt)
    }

    /// A window that reports no percentage has nothing to draw — dropping it
    /// beats inventing a scale for a bare count.
    func testAWindowWithoutAPercentageIsDropped() throws {
        let json = """
        { "code": 200, "success": true,
          "data": { "limits": [ { "type": "TIME_LIMIT", "currentValue": 40 } ] } }
        """
        XCTAssertTrue(try parse(json).windows.isEmpty)
    }

    /// Over the limit is a reading, not an error: the ring sits at full and
    /// the tooltip says so.
    func testAPercentageOverOneHundredIsKept() throws {
        let json = """
        { "code": 200, "success": true,
          "data": { "limits": [ { "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
                                  "percentage": 128.0 } ] } }
        """
        let window = try XCTUnwrap(try parse(json).windows.first)
        XCTAssertEqual(window.usedFraction ?? -1, 1.28, accuracy: 0.0001)
    }

    /// A token window the encodings do not name yet still renders, with an
    /// identity derived from its own window length rather than a borrowed one.
    func testAnUnfamiliarWindowKeepsItsOwnIdentity() throws {
        let json = """
        { "code": 200, "success": true,
          "data": { "limits": [ { "type": "TOKENS_LIMIT", "unit": 4, "number": 2,
                                  "percentage": 10.0 } ] } }
        """
        let window = try XCTUnwrap(try parse(json).windows.first)
        XCTAssertEqual(window.id, "window-4x2")
        XCTAssertEqual(window.label, "Usage")
    }

    /// Recorded from a live credit plan — the Lite tier meters credits rather
    /// than tokens, answers `CREDIT_LIMIT` instead of `TOKENS_LIMIT`, and
    /// encodes the window length the same way. The identity has to come from
    /// the length, or a whole plan renders as an unlabelled row.
    func testACreditPlanDecodesWithTheSameWindowIdentities() throws {
        let credit = """
        { "code": 200, "success": true,
          "data": { "level": "lite",
            "limits": [
              { "type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 1,
                "currentValue": 1, "usage": 2000, "nextResetTime": 1788654095358 },
              { "type": "CREDIT_LIMIT", "unit": 6, "number": 1, "percentage": 17,
                "currentValue": 1775, "usage": 10000, "nextResetTime": 1789073479999 } ] } }
        """
        let payload = try parse(credit)
        XCTAssertEqual(payload.level, "lite")
        XCTAssertEqual(payload.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(payload.windows[0].usedFraction ?? -1, 0.01, accuracy: 0.0001)
        XCTAssertEqual(payload.windows[1].usedFraction ?? -1, 0.17, accuracy: 0.0001)
    }

    func testMissingEnvelopeKeysStillReadAsSuccess() throws {
        let bare = """
        { "data": { "limits": [ { "type": "TIME_LIMIT", "percentage": 4.0 } ] } }
        """
        XCTAssertEqual(try parse(bare).windows.count, 1)
    }
}

/// Errors ride in under an HTTP 200, so the envelope is read before the
/// payload is trusted. What each business code means is pinned here.
final class GLMEnvelopeFailureTests: XCTestCase {
    private func parse(_ json: String) throws -> GLMUsage.Payload {
        try GLMUsage.parse(Data(json.utf8))
    }

    /// `UsageProviderError` carries associated values, so equality here is
    /// case-by-case rather than `==`.
    private func assertError(
        _ body: String, matches expected: UsageProviderError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            _ = try parse(body)
            XCTFail("the envelope reported failure, but parse succeeded", file: file, line: line)
        } catch let actual as UsageProviderError {
            let same: Bool
            switch (actual, expected) {
            case (.needsAuth, .needsAuth):
                same = true
            case (.rateLimited(let a), .rateLimited(let b)):
                same = a == b
            case (.badResponse(let a), .badResponse(let b)):
                same = a == b
            default:
                same = false
            }
            XCTAssertTrue(same, "got \(actual), expected \(expected)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    /// Recorded verbatim from an expired-token request: HTTP 200, and the
    /// failure entirely inside the body.
    func testAnExpiredTokenRidesInUnderHTTP200() {
        assertError(#"{"code":401,"msg":"token expired or incorrect","success":false}"#,
                    matches: .needsAuth)
    }

    func testARefusedKeyIsNotAnErrorButASignOut() {
        assertError(#"{"code":403,"success":false}"#, matches: .needsAuth)
    }

    func testAThrottledAnswerReadsAsRateLimited() {
        assertError(#"{"code":429,"success":false}"#, matches: .rateLimited(retryAfter: 0))
    }

    func testAnUnrecognisedBusinessCodeIsABadResponse() {
        assertError(#"{"code":1305,"msg":"overloaded","success":false}"#,
                    matches: .badResponse(status: 1305))
    }
}

/// The key is borrowed from whichever tool holds it, and each source has its
/// own file, shape and failure mode. All of these run against fixture files,
/// never against a real one.
final class GLMCredentialsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GLMCredentialsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func write(_ json: String, to name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    /// The secret the encrypted fixtures below were sealed with — vectors
    /// generated by ZCode's own algorithm (AES-256-GCM, keyed by the SHA-256
    /// of this string), so a passing test proves interop rather than a
    /// round-trip with ourselves.
    private let testSecret = "codenotch-test-secret"
    private let sealedOAuthToken = "enc:v1:AAECAwQFBgcICQoL.Ry_i-Pdd5-Q9anxf-qmhuw.F8EQAm0pm9G8_FWoIA"
    private let sealedAccountKey = "enc:v1:EBESExQVFhcYGRob.uwR9hDp2bhbEHb7rLSi-4A.t8lOm_4Hb-lm_4iiqmz2L5hPZw"

    private func load(claude: String? = nil, zcodeConfig: String? = nil,
                      zcode: String? = nil,
                      openCode: String? = nil,
                      secret: String? = nil) throws -> GLMCredentials.Credential? {
        func fixture(_ contents: String?, _ name: String) throws -> URL? {
            guard let contents else { return nil }
            return try write(contents, to: name)
        }
        return GLMCredentials.load(
            claudeSettings: try fixture(claude, "claude.json"),
            zcodeConfig: try fixture(zcodeConfig, "zcode-config.json"),
            zcodeCredentials: try fixture(zcode, "zcode-credentials.json"),
            openCodeAuth: try fixture(openCode, "opencode.json"),
            zcodeSecret: secret
        )
    }

    // MARK: Claude Code

    func testReadsAClaudeCodeKeyPointedAtZDotAI() throws {
        let credential = try load(claude: """
        { "env": { "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
                   "ANTHROPIC_AUTH_TOKEN": "sk-glm-abc123" } }
        """)
        XCTAssertEqual(credential?.token, "sk-glm-abc123")
        XCTAssertEqual(credential?.source, "Claude Code")
        XCTAssertEqual(credential?.baseURL.host, "api.z.ai")
    }

    /// The base URL is what makes the token GLM's. A settings file aimed at
    /// Anthropic holds somebody's Anthropic key, and claiming it would read
    /// the wrong account under GLM's name.
    func testDoesNotClaimAClaudeCodeKeyAimedAtAnthropic() throws {
        let anthropic = try load(claude: """
        { "env": { "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
                   "ANTHROPIC_AUTH_TOKEN": "sk-ant-abc123" } }
        """)
        XCTAssertNil(anthropic)
    }

    func testDoesNotClaimATokenWithNoBaseURLAtAll() throws {
        let bare = try load(claude: #"{"env": {"ANTHROPIC_AUTH_TOKEN": "sk-glm-abc123"}}"#)
        XCTAssertNil(bare)
    }

    func testTheChinaConsoleKeyReadsFromTheChinaConsole() throws {
        let credential = try load(claude: """
        { "env": { "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
                   "ANTHROPIC_AUTH_TOKEN": "key-abc" } }
        """)
        XCTAssertEqual(credential?.baseURL.host, "open.bigmodel.cn")
    }

    // MARK: ZCode

    func testReadsAZCodePlanKeyFromTheConfiguredProvider() throws {
        let credential = try load(zcodeConfig: """
        { "provider": { "builtin:zai-coding-plan": {
            "kind": "anthropic", "enabled": true,
            "options": { "apiKey": "zai-plan-key",
                         "baseURL": "https://api.z.ai/api/anthropic" } } } }
        """)
        XCTAssertEqual(credential?.token, "zai-plan-key")
        XCTAssertEqual(credential?.source, "ZCode")
        XCTAssertEqual(credential?.baseURL.host, "api.z.ai")
    }

    /// The baseURL is the tool's own Anthropic endpoint; only its host
    /// decides the console. Asking the monitor under `/api/anthropic`
    /// answers a misleading 404, so the path is dropped.
    func testTheChinaConsolePlanKeyReadsFromTheChinaConsole() throws {
        let credential = try load(zcodeConfig: """
        { "provider": { "builtin:bigmodel-coding-plan": {
            "enabled": true,
            "options": { "apiKey": "cn-key",
                         "baseURL": "https://open.bigmodel.cn/api/anthropic" } } } }
        """)
        XCTAssertEqual(credential?.baseURL.host, "open.bigmodel.cn")
    }

    /// A provider switched off in ZCode is an account the user is not using;
    /// claiming its key would read an account they turned off.
    func testADisabledPlanProviderIsSkipped() throws {
        let credential = try load(zcodeConfig: """
        { "provider": { "builtin:zai-coding-plan": {
            "enabled": false,
            "options": { "apiKey": "zai-plan-key",
                         "baseURL": "https://api.z.ai/api/anthropic" } } } }
        """)
        XCTAssertNil(credential)
    }

    func testReadsAZCodeStartPlanKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zcode-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        { "provider": { "builtin:zai-start-plan": {
            "enabled": true,
            "options": { "apiKey": "start-key",
                         "baseURL": "https://zcode.z.ai/api/v1/zcode-plan/anthropic" } } } }
        """.write(to: url, atomically: true, encoding: .utf8)
        let credential = GLMCredentials.zcodePlanKey(url)
        XCTAssertEqual(credential?.token, "start-key")
        XCTAssertEqual(credential?.source, "ZCode")
        XCTAssertEqual(credential?.baseURL.host, "api.z.ai")
        XCTAssertTrue(GLMCredentials.zcodeHasStartPlan(url))

        try """
        { "provider": { "builtin:zai-start-plan": {
            "enabled": false, "options": { "apiKey": "start-key" } } } }
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(GLMCredentials.zcodeHasStartPlan(url), "a Start Plan switched off is not in use")
    }

    /// A plain API provider is pay-as-you-go, not the plan — the monitor
    /// reports plan quota, so an entry without `coding-plan` in its name is
    /// none of ours.
    func testAPlanlessZCodeProviderIsIgnored() throws {
        let credential = try load(zcodeConfig: """
        { "provider": { "builtin:zai": {
            "enabled": true,
            "options": { "apiKey": "payg-key",
                         "baseURL": "https://api.z.ai/api/anthropic" } } } }
        """)
        XCTAssertNil(credential)
    }

    func testReadsAZCodeOAuthKey() throws {
        let credential = try load(zcode: #"{"oauth:zai:access_token": "zai-token-xyz"}"#)
        XCTAssertEqual(credential?.token, "zai-token-xyz")
        XCTAssertEqual(credential?.source, "ZCode")
    }

    /// Recent ZCode encrypts every value at rest; the notch decrypts with
    /// ZCode's own construction rather than asking for a key of its own.
    func testDecryptsAZCodeKeyEncryptedAtRest() throws {
        let credential = try load(
            zcode: #"{"oauth:zai:access_token": "\#(sealedOAuthToken)"}"#,
            secret: testSecret
        )
        XCTAssertEqual(credential?.token, "zai-token-xyz")
        XCTAssertEqual(credential?.source, "ZCode")
    }

    /// A value sealed with another secret is a string we cannot read, so it
    /// is a string we must not send. The source is skipped rather than
    /// guessed at — a wrong guess would read as a signed-out plan.
    func testSkipsAZCodeKeySealedWithAnotherSecret() throws {
        let encrypted = try load(
            zcode: #"{"oauth:zai:access_token": "\#(sealedOAuthToken)"}"#,
            secret: "somebody-elses-secret"
        )
        XCTAssertNil(encrypted)
    }

    /// Malformed is unreadable too, whatever secret is offered.
    func testSkipsAMalformedEncryptedValue() throws {
        let malformed = try load(
            zcode: #"{"oauth:zai:access_token": "enc:v1:uJqn18qD-not-a-real-key"}"#,
            secret: testSecret
        )
        XCTAssertNil(malformed)
    }

    /// The plan's own key, filed per account, is the credential being
    /// metered; the sign-in token is what is left when there is no account
    /// key to read.
    func testThePerAccountPlanKeyWinsOverTheSignInToken() throws {
        let credential = try load(
            zcode: """
            {"account-provider:coding-plan:account:zai-individual-coding-plan:account:u1:api-key": "\
            \(sealedAccountKey)",
             "oauth:zai:access_token": "\(sealedOAuthToken)"}
            """,
            secret: testSecret
        )
        XCTAssertEqual(credential?.token, "plan-api-key.abc123")
        XCTAssertEqual(credential?.source, "ZCode")
        XCTAssertEqual(credential?.baseURL.host, "api.z.ai")
    }

    /// With several accounts the keys sort, so a machine with two holds a
    /// stable answer rather than a directory-listing lottery.
    func testAccountKeysAnswerInSortedOrder() throws {
        let credential = try load(
            zcode: """
            {"account-provider:coding-plan:account:zai-individual-coding-plan:account:zzz:api-key": "\
            \(sealedAccountKey)",
             "account-provider:coding-plan:account:zai-individual-coding-plan:account:aaa:api-key": "\
            \(sealedOAuthToken)"}
            """,
            secret: testSecret
        )
        // Both values decrypt; the `aaa` account sorts first.
        XCTAssertEqual(credential?.token, "zai-token-xyz")
    }

    /// An account key that does not decrypt is not the end of the file: the
    /// sign-in token below it may still read.
    func testAnUndecryptableAccountKeyFallsThroughToTheSignInToken() throws {
        let credential = try load(
            zcode: """
            {"account-provider:coding-plan:account:zai-individual-coding-plan:account:u1:api-key": "enc:v1:garbage",
             "oauth:zai:access_token": "\(sealedOAuthToken)"}
            """,
            secret: testSecret
        )
        XCTAssertEqual(credential?.token, "zai-token-xyz")
    }

    func testReadsABigModelSignInFromTheChinaConsole() throws {
        let credential = try load(
            zcode: #"{"oauth:bigmodel:access_token": "\#(sealedOAuthToken)"}"#,
            secret: testSecret
        )
        XCTAssertEqual(credential?.token, "zai-token-xyz")
        XCTAssertEqual(credential?.baseURL.host, "open.bigmodel.cn")
    }

    func testAnAccountKeyNamingBigModelReadsFromTheChinaConsole() throws {
        let credential = try load(
            zcode: """
            {"account-provider:coding-plan:account:bigmodel-individual-coding-plan:account:u1:api-key": "\
            \(sealedAccountKey)"}
            """,
            secret: testSecret
        )
        XCTAssertEqual(credential?.token, "plan-api-key.abc123")
        XCTAssertEqual(credential?.baseURL.host, "open.bigmodel.cn")
    }

    func testAnEmptyMiddleIsNotAnAccountKey() {
        XCTAssertFalse(GLMCredentials.isAccountAPIKey("account-provider::api-key"))
        XCTAssertFalse(GLMCredentials.isAccountAPIKey("oauth:zai:access_token"))
        XCTAssertTrue(GLMCredentials.isAccountAPIKey(
            "account-provider:coding-plan:account:zai-individual-coding-plan:account:u1:api-key"))
    }

    /// #71, new layout: `config.json` is gone from recent ZCode, and the
    /// plan choice moved to `setting.json`'s
    /// `providerFamilyConnectionSelections`. A Start Plan on every console is
    /// still a plan with no published usage; a coding plan on either console
    /// is not.
    func testAStartPlanOnlySettingIsNoticed() throws {
        let url = try write(
            #"{"providerFamilyConnectionSelections": {"zai": {"kind": "start-plan"}}}"#,
            to: "zcode-setting.json")
        XCTAssertTrue(GLMCredentials.zcodeSettingsHasStartPlanOnly(url))
    }

    func testACodingPlanOnEitherConsoleIsNotStartPlanOnly() throws {
        let coding = try write(
            #"{"providerFamilyConnectionSelections": {"zai": {"kind": "individual-coding-plan"}}}"#,
            to: "zcode-setting-coding.json")
        XCTAssertFalse(GLMCredentials.zcodeSettingsHasStartPlanOnly(coding))

        let mixed = try write(
            """
            {"providerFamilyConnectionSelections": {
              "zai": {"kind": "start-plan"},
              "bigmodel": {"kind": "individual-coding-plan"}}}
            """,
            to: "zcode-setting-mixed.json")
        XCTAssertFalse(GLMCredentials.zcodeSettingsHasStartPlanOnly(mixed))

        let empty = try write(
            #"{"providerFamilyConnectionSelections": {}}"#,
            to: "zcode-setting-empty.json")
        XCTAssertFalse(GLMCredentials.zcodeSettingsHasStartPlanOnly(empty))

        let missing = try write(#"{"locale": "en-US"}"#, to: "zcode-setting-bare.json")
        XCTAssertFalse(GLMCredentials.zcodeSettingsHasStartPlanOnly(missing))
    }

    // MARK: OpenCode

    func testReadsAnOpenCodeKeyFromTheCodingPlanEntry() throws {
        let credential = try load(openCode: #"{"zai-coding-plan": "opencode-key"}"#)
        XCTAssertEqual(credential?.token, "opencode-key")
        XCTAssertEqual(credential?.baseURL.host, "api.z.ai")
    }

    /// The entry is sometimes an object carrying the key rather than the key
    /// itself; both shapes have shipped.
    func testReadsAnOpenCodeKeyWrappedInAnObject() throws {
        let credential = try load(
            openCode: #"{"zai": {"apiKey": "opencode-key", "type": "api"}}"#
        )
        XCTAssertEqual(credential?.token, "opencode-key")
    }

    func testAZhipuEntryReadsFromTheChinaConsole() throws {
        let credential = try load(openCode: #"{"zhipu": "cn-key"}"#)
        XCTAssertEqual(credential?.baseURL.host, "open.bigmodel.cn")
    }

    // MARK: Priority

    /// The sources are tried in a fixed order, so a machine with two holds a
    /// stable answer rather than a directory-listing lottery.
    func testClaudeCodeWinsWhenTwoSourcesArePresent() throws {
        let credential = try load(
            claude: #"{"env": {"ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic", "ANTHROPIC_AUTH_TOKEN": "claude-key"}}"#,
            zcode: #"{"oauth:zai:access_token": "zcode-key"}"#
        )
        XCTAssertEqual(credential?.token, "claude-key")
    }

    /// Within ZCode, the key pasted into the plan provider is the one in use;
    /// the OAuth token is what is left when there is no paste.
    func testThePlanKeyWinsOverTheOAuthToken() throws {
        let credential = try load(
            zcodeConfig: """
            { "provider": { "builtin:zai-coding-plan": {
                "enabled": true,
                "options": { "apiKey": "zai-plan-key",
                             "baseURL": "https://api.z.ai/api/anthropic" } } } }
            """,
            zcode: #"{"oauth:zai:access_token": "zcode-oauth-key"}"#
        )
        XCTAssertEqual(credential?.token, "zai-plan-key")
    }

    func testNoSourceAtAllIsNil() throws {
        XCTAssertNil(try load())
    }
}

/// ZCode seals every credential at rest as `enc:v1:<iv>.<tag>.<ciphertext>`:
/// AES-256-GCM, keyed by the SHA-256 of a secret. The vectors below were
/// produced by that same construction outside this codebase, so a passing
/// test proves the notch reads ZCode's files rather than its own writing.
final class ZCodeCredentialCipherTests: XCTestCase {
    private let secret = "codenotch-test-secret"
    private let sealedOAuthToken = "enc:v1:AAECAwQFBgcICQoL.Ry_i-Pdd5-Q9anxf-qmhuw.F8EQAm0pm9G8_FWoIA"
    private let sealedAccountKey = "enc:v1:EBESExQVFhcYGRob.uwR9hDp2bhbEHb7rLSi-4A.t8lOm_4Hb-lm_4iiqmz2L5hPZw"

    func testDecryptsKnownVectors() {
        XCTAssertEqual(ZCodeCredentialCipher.decrypt(sealedOAuthToken, secret: secret), "zai-token-xyz")
        XCTAssertEqual(ZCodeCredentialCipher.decrypt(sealedAccountKey, secret: secret), "plan-api-key.abc123")
    }

    /// A wrong secret fails closed: nil means "try the next key", never
    /// "send what we have".
    func testAWrongSecretFailsClosed() {
        XCTAssertNil(ZCodeCredentialCipher.decrypt(sealedOAuthToken, secret: "somebody-elses-secret"))
    }

    /// One flipped bit in the ciphertext or the tag breaks the seal, and
    /// the whole value with it.
    func testATamperedCiphertextFailsClosed() {
        // Flipped mid-part, where every bit survives decoding: the last
        // character of a two-character quantum carries padding bits, and a
        // flip there can decode to the very same bytes — no tamper at all.
        func flip(_ value: String, part: Int) -> String {
            var pieces = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            var chars = Array(pieces[part])
            chars[3] = chars[3] == "A" ? "B" : "A"
            pieces[part] = String(chars)
            return pieces.joined(separator: ".")
        }
        XCTAssertNil(ZCodeCredentialCipher.decrypt(flip(sealedOAuthToken, part: 2), secret: secret),
                     "a tampered ciphertext must not read")
        XCTAssertNil(ZCodeCredentialCipher.decrypt(flip(sealedOAuthToken, part: 1), secret: secret),
                     "a tampered tag must not read")
    }

    func testBadShapesAreNil() {
        // No parts at all.
        XCTAssertNil(ZCodeCredentialCipher.decrypt("enc:v1:uJqn18qD-not-a-real-key", secret: secret))
        // An IV of one byte where twelve are required.
        XCTAssertNil(ZCodeCredentialCipher.decrypt("enc:v1:QQ.uwR9hDp2bhbEHb7rLSi-4A.eA", secret: secret))
        // Not base64url.
        XCTAssertNil(ZCodeCredentialCipher.decrypt("enc:v1:***.uwR9hDp2bhbEHb7rLSi-4A.eA", secret: secret))
        // Five characters land one past a quantum, which no valid encoding does.
        XCTAssertNil(ZCodeCredentialCipher.decrypt("enc:v1:AAAAA.uwR9hDp2bhbEHb7rLSi-4A.eA", secret: secret))
    }

    /// Older ZCode wrote the token in the clear; those values pass through,
    /// the way ZCode's own decrypt treats them.
    func testPlaintextPassesThrough() {
        XCTAssertEqual(ZCodeCredentialCipher.decrypt("zai-token-xyz", secret: secret), "zai-token-xyz")
        XCTAssertFalse(ZCodeCredentialCipher.isEncrypted("zai-token-xyz"))
        XCTAssertTrue(ZCodeCredentialCipher.isEncrypted(sealedOAuthToken))
    }

    func testTheEnvironmentOverrideWinsTrimmed() {
        XCTAssertEqual(
            ZCodeCredentialCipher.defaultSecret(environment: ["ZCODE_CREDENTIAL_SECRET": "  env-secret\t"],
                                                homeDirectory: "/Users/test", username: "test"),
            "env-secret")
    }

    func testTheFallbackNamesPlaceAndUser() {
        XCTAssertEqual(
            ZCodeCredentialCipher.defaultSecret(environment: [:],
                                                homeDirectory: "/Users/test", username: "test"),
            "zcode-credential-fallback:darwin:/Users/test:test")
    }

    /// A blank override is no override: whitespace alone must not become a
    /// secret nobody can reproduce.
    func testABlankOverrideFallsBack() {
        XCTAssertEqual(
            ZCodeCredentialCipher.defaultSecret(environment: ["ZCODE_CREDENTIAL_SECRET": "   "],
                                                homeDirectory: "/Users/test", username: "test"),
            "zcode-credential-fallback:darwin:/Users/test:test")
    }
}

/// The monitor endpoint is known to throttle. A poll that keeps firing into a
/// 429 is how you stay rate-limited, so the back-off is pinned the way
/// Claude's is.
final class GLMBackoffTests: XCTestCase {
    func testTheWaitDoublesWhileTheLimitPersists() {
        XCTAssertEqual(GLMProvider.backoff(forAttempt: 0, retryAfter: nil), 60)
        XCTAssertEqual(GLMProvider.backoff(forAttempt: 1, retryAfter: nil), 120)
        XCTAssertEqual(GLMProvider.backoff(forAttempt: 2, retryAfter: nil), 240)
    }

    func testItIsCappedSoItAlwaysRecovers() {
        XCTAssertEqual(GLMProvider.backoff(forAttempt: 99, retryAfter: nil), 15 * 60)
    }

    func testAZeroHintStillWaitsAMinute() {
        XCTAssertEqual(GLMProvider.backoff(forAttempt: 0, retryAfter: 0), 60)
    }

    func testAGenerousHintWins() {
        XCTAssertEqual(GLMProvider.backoff(forAttempt: 0, retryAfter: 600), 600)
    }

    private func response(retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!,
            statusCode: 429, httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] }
        )!
    }

    func testReadsRetryAfterInSeconds() {
        XCTAssertEqual(GLMProvider.retryAfter(from: response(retryAfter: "120")), 120)
    }

    func testMissingOrUnparseableHeaderIsNil() {
        XCTAssertNil(GLMProvider.retryAfter(from: response(retryAfter: nil)))
        XCTAssertNil(GLMProvider.retryAfter(from: response(retryAfter: "soon")))
    }
}

/// The mark is defined rather than traced, so its geometry is pinned: one
/// loop, inside the unit box, reading as a Z.
final class GLMGlyphTests: XCTestCase {
    func testTheOutlineIsASingleLoopInsideTheUnitBox() {
        let outline = GlyphOutline.glm
        XCTAssertEqual(outline.count, 1, "one loop; even-odd fill has no counters to keep open")
        let loop = outline[0]
        XCTAssertEqual(loop.count, 10)
        for point in loop {
            XCTAssertTrue(point.x >= 0 && point.x <= 1, "x \(point.x) outside the unit box")
            XCTAssertTrue(point.y >= 0 && point.y <= 1, "y \(point.y) outside the unit box")
        }
    }

    func testTheMarkMatchesTheProviderGlyph() {
        XCTAssertEqual(ProviderGlyph.glm.rawValue, "glm")
        XCTAssertEqual(ProviderGlyph.glm.outline, GlyphOutline.glm)
        XCTAssertEqual(ProviderGlyph.glm.assetName, "glyph-glm")
    }

    /// A ring with no reading still draws the glyph: the shape has to have
    /// ink, or the cell renders an empty ring.
    func testTheOutlineHasInk() {
        let loop = GlyphOutline.glm[0]
        var area = 0.0
        for (index, point) in loop.enumerated() {
            let next = loop[(index + 1) % loop.count]
            area += Double(point.x * next.y - next.x * point.y)
        }
        XCTAssertGreaterThan(abs(area) / 2, 0.3, "the mark covers less than a third of its box")
    }
}
