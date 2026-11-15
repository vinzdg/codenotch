import XCTest
@testable import Codenotch

final class MiniMaxCredentialsTests: XCTestCase {
    func testTheCodingPlanEnvironmentKeyWinsOverTheGenericKeyAndTheKeychain() {
        XCTAssertEqual(MiniMaxCredentials.apiKeyEnvironment, "MiniMax_CODING_API_KEY")
        XCTAssertEqual(MiniMaxCredentials.apiKeyEnvironmentAlias, "MINIMAX_CODING_API_KEY")
        XCTAssertEqual(MiniMaxCredentials.apiKeyEnvironmentFallback, "MINIMAX_API_KEY")
        XCTAssertEqual(
            MiniMaxCredentials.loadAPIKey(
                environment: [
                    MiniMaxCredentials.apiKeyEnvironment: " coding ",
                    MiniMaxCredentials.apiKeyEnvironmentFallback: "generic"
                ],
                keychain: { "stored" }
            ),
            "coding"
        )
        XCTAssertEqual(
            MiniMaxCredentials.loadAPIKey(
                environment: [
                    "MiniMax_CODING_API_KEY": "coding",
                    "MINIMAX_CODING_API_KEY": "alias",
                    "MINIMAX_API_KEY": "generic"
                ],
                keychain: { "stored" }
            ),
            "coding",
            "macOS env lookup is case-sensitive; MiniMax_CODING_API_KEY must beat MINIMAX_API_KEY"
        )
        XCTAssertEqual(
            MiniMaxCredentials.loadAPIKey(
                environment: [
                    "MINIMAX_CODING_API_KEY": "alias",
                    "MINIMAX_API_KEY": "generic"
                ],
                keychain: { "stored" }
            ),
            "alias"
        )
    }

    func testTheGenericEnvironmentKeyWinsOverTheKeychainWhenTheCodingPlanKeyIsAbsent() {
        XCTAssertEqual(
            MiniMaxCredentials.loadAPIKey(
                environment: [MiniMaxCredentials.apiKeyEnvironmentFallback: " generic "],
                keychain: { "stored" }
            ),
            "generic"
        )
    }

    func testABlankEnvironmentKeyIsAbsentAndFallsThrough() {
        XCTAssertEqual(
            MiniMaxCredentials.loadAPIKey(
                environment: [
                    MiniMaxCredentials.apiKeyEnvironment: "  ",
                    MiniMaxCredentials.apiKeyEnvironmentFallback: " generic "
                ],
                keychain: { "stored" }
            ),
            "generic",
            "a blank coding-plan export is no key"
        )
        XCTAssertEqual(
            MiniMaxCredentials.loadAPIKey(
                environment: [
                    MiniMaxCredentials.apiKeyEnvironment: "  ",
                    MiniMaxCredentials.apiKeyEnvironmentFallback: "\n"
                ],
                keychain: { "stored" }
            ),
            "stored"
        )
        XCTAssertNil(MiniMaxCredentials.loadAPIKey(environment: [:], keychain: { nil }))
    }

    func testTheKeychainClosureIsNotCachedBetweenAPIKeyLoads() {
        var calls = 0
        _ = MiniMaxCredentials.loadAPIKey(environment: [:], keychain: { calls += 1; return "stored" })
        _ = MiniMaxCredentials.loadAPIKey(environment: [:], keychain: { calls += 1; return "stored" })
        XCTAssertEqual(calls, 2, "the injectable path must bypass the cache")
    }

    func testAnEnvironmentAPIKeyIsPresentWithoutReadingTheKeychain() {
        XCTAssertTrue(MiniMaxCredentials.isAPIKeyPresent(
            environment: [MiniMaxCredentials.apiKeyEnvironment: "k"]))
        XCTAssertTrue(MiniMaxCredentials.isAPIKeyPresent(
            environment: [MiniMaxCredentials.apiKeyEnvironmentAlias: "k"]))
        XCTAssertTrue(MiniMaxCredentials.isAPIKeyPresent(
            environment: [MiniMaxCredentials.apiKeyEnvironmentFallback: "k"]))
        XCTAssertTrue(MiniMaxCredentials.isAPIKeyPresent(
            environment: [MiniMaxCredentials.apiKeyEnvironment: " k "]))
        XCTAssertTrue(MiniMaxCredentials.isAPIKeyPresent(
            environment: ["MiniMax_CODING_API_KEY": "k"]))
    }

    func testTheCookieEnvironmentWinsOverTheHeaderFallbackAndTheKeychain() {
        XCTAssertEqual(
            MiniMaxCredentials.loadCookieHeader(
                environment: [
                    MiniMaxCredentials.cookieEnvironment: " a=1 ",
                    MiniMaxCredentials.cookieHeaderEnvironment: "b=2"
                ],
                keychain: { "stored=1" }
            ),
            "a=1"
        )
        XCTAssertEqual(
            MiniMaxCredentials.loadCookieHeader(
                environment: [MiniMaxCredentials.cookieHeaderEnvironment: "Cookie: b=2"],
                keychain: { "stored=1" }
            ),
            "b=2"
        )
        XCTAssertEqual(
            MiniMaxCredentials.loadCookieHeader(environment: [:], keychain: { " stored=1 " }),
            "stored=1"
        )
        XCTAssertNil(MiniMaxCredentials.loadCookieHeader(environment: [:], keychain: { nil }))
    }

    func testABlankCookieEnvironmentFallsThrough() {
        XCTAssertEqual(
            MiniMaxCredentials.loadCookieHeader(
                environment: [
                    MiniMaxCredentials.cookieEnvironment: "  ",
                    MiniMaxCredentials.cookieHeaderEnvironment: "b=2"
                ],
                keychain: { "stored=1" }
            ),
            "b=2"
        )
    }

    func testNormalizedCookieHeaderAcceptsABarePair() {
        XCTAssertEqual(MiniMaxCredentials.normalizedCookieHeader(from: " session=abc; token=xyz "),
                       "session=abc; token=xyz")
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: "  "))
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: ""))
    }

    func testNormalizedCookieHeaderStripsACookiePrefix() {
        XCTAssertEqual(MiniMaxCredentials.normalizedCookieHeader(from: "Cookie: session=abc"),
                       "session=abc")
        XCTAssertEqual(MiniMaxCredentials.normalizedCookieHeader(from: "cookie: session=abc"),
                       "session=abc")
        XCTAssertEqual(MiniMaxCredentials.normalizedCookieHeader(from: "COOKIE:session=abc"),
                       "session=abc")
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: "Cookie:  "))
    }

    func testNormalizedCookieHeaderExtractsACurlHeader() {
        XCTAssertEqual(
            MiniMaxCredentials.normalizedCookieHeader(from: #"-H 'Cookie: session=abc; token=xyz'"#),
            "session=abc; token=xyz"
        )
        XCTAssertEqual(
            MiniMaxCredentials.normalizedCookieHeader(from: #"-H "Cookie: session=abc""#),
            "session=abc"
        )
        XCTAssertEqual(
            MiniMaxCredentials.normalizedCookieHeader(from: #"--header 'Cookie: session=abc'"#),
            "session=abc"
        )
        XCTAssertEqual(
            MiniMaxCredentials.normalizedCookieHeader(from: #"--header=Cookie: session=abc --compressed"#),
            "session=abc"
        )
        let curl = """
        curl --location 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains' \
        --header 'Authorization: Bearer sk-cp-secret' \
        --header 'Cookie: session=abc; token=xyz' \
        --header 'Content-Type: application/json'
        """
        XCTAssertEqual(MiniMaxCredentials.normalizedCookieHeader(from: curl),
                       "session=abc; token=xyz")
    }

    func testACurlCommandWithoutACookieHeaderIsNotACookie() {
        let curl = """
        curl --location 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains' \
        --header 'Authorization: Bearer sk-cp-secret'
        """
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: curl))
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: #"-H 'Authorization: Bearer sk-cp-secret'"#))
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: "$ curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains'"),
                     "a prompt-prefixed curl is still a command, not a Cookie header")
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: "% curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains'"))
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: "/usr/bin/curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains'"))
        XCTAssertEqual(
            MiniMaxCredentials.loadCookieHeader(
                environment: [MiniMaxCredentials.cookieEnvironment: curl],
                keychain: { "stored=1" }
            ),
            "stored=1",
            "a curl paste with no Cookie header is no cookie, so the keychain still counts"
        )
        XCTAssertEqual(
            MiniMaxCredentials.loadCookieHeader(
                environment: [MiniMaxCredentials.cookieEnvironment: "$ curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains'"],
                keychain: { "stored=1" }
            ),
            "stored=1"
        )
    }

    func testAOneLineCurlDoesNotSwallowFlagsAfterTheCookie() {
        let quoted = "curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains' -H 'Cookie: session=abc; token=xyz' -H 'Content-Type: application/json' --compressed"
        XCTAssertEqual(MiniMaxCredentials.normalizedCookieHeader(from: quoted),
                       "session=abc; token=xyz")
        let unquoted = "curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains' -H Cookie: session=abc; token=xyz --compressed"
        XCTAssertEqual(MiniMaxCredentials.normalizedCookieHeader(from: unquoted),
                       "session=abc; token=xyz",
                       "unquoted Cookie: must stop at the next flag, not eat the rest of the command")
        let dataRaw = #"curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains' --data-raw '{"x":"Cookie: fake"}' -H 'Cookie: session=abc'"#
        XCTAssertEqual(MiniMaxCredentials.normalizedCookieHeader(from: dataRaw),
                       "session=abc")
        let onlyJSON = #"curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains' --data-raw '{"x":"Cookie: fake"}'"#
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: onlyJSON),
                     "Cookie: inside a JSON body is not a Cookie header")
    }

    func testACurlCookieFlagIsACookieAndABrowserStorePathIsNot() {
        XCTAssertEqual(
            MiniMaxCredentials.normalizedCookieHeader(from: "curl 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains' -b 'session=abc; token=xyz'"),
            "session=abc; token=xyz"
        )
        XCTAssertEqual(
            MiniMaxCredentials.normalizedCookieHeader(from: #"curl --cookie "session=abc" 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains'"#),
            "session=abc"
        )
        let chrome = #"curl -b "$HOME/Library/Application Support/Google/Chrome/Default/Cookies" 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains'"#
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: chrome),
                     "a Chrome Cookies.sqlite path is not a header, and must not be opened")
        let safari = #"curl -b $HOME/Library/Cookies/Cookies.binarycookies 'https://www.minimax.io/v1/api/openplatform/coding_plan/remains'"#
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(from: safari),
                     "Safari's cookie store is not a header, and must not be opened")
        XCTAssertNil(MiniMaxCredentials.normalizedCookieHeader(
            from: "curl -b ~/Library/Application\\ Support/Google/Chrome/Default/Cookies.sqlite 'https://www.minimax.io/'"))
    }

    func testKeychainServiceNamesDoNotCollideWithOllama() {
        XCTAssertEqual(MiniMaxCredentials.apiKeyService, "minimax-api-key")
        XCTAssertEqual(MiniMaxCredentials.cookieService, "minimax-session-cookie")
        XCTAssertEqual(MiniMaxCredentials.keychainAccount, "codenotch")
        XCTAssertEqual(OllamaCredentials.keychainService, "ollama-api-key")
        XCTAssertEqual(OllamaCredentials.keychainAccount, "codenotch")
        XCTAssertNotEqual(MiniMaxCredentials.apiKeyService, OllamaCredentials.keychainService,
                          "the same account is fine; the service name is what would overwrite Ollama's key")
        XCTAssertNotEqual(MiniMaxCredentials.cookieService, OllamaCredentials.keychainService)
        XCTAssertNotEqual(MiniMaxCredentials.apiKeyService, MiniMaxCredentials.cookieService)
        XCTAssertNotEqual(MiniMaxCredentials.apiKeyService, LMStudioCredentials.keychainService)
        XCTAssertNotEqual(MiniMaxCredentials.cookieService, LMStudioCredentials.keychainService)
    }

    func testAnEnvironmentCookieIsNormalized() {
        XCTAssertEqual(
            MiniMaxCredentials.loadCookieHeader(
                environment: [MiniMaxCredentials.cookieEnvironment: "-H 'Cookie: a=1'"],
                keychain: { "stored=1" }
            ),
            "a=1"
        )
    }

    func testAccountUsesTheRegionCodingPlanPageWhenAKeyOrCookieIsExported() {
        let fromKey = MiniMaxCredentials.account(
            region: .international,
            environment: [MiniMaxCredentials.apiKeyEnvironment: "k"]
        )
        XCTAssertEqual(fromKey?.source, "MiniMax")
        XCTAssertNil(fromKey?.label)
        XCTAssertNil(fromKey?.plan)
        XCTAssertEqual(fromKey?.manageURL,
                       URL(string: "https://platform.minimax.io/user-center/payment/coding-plan"))

        let fromCookie = MiniMaxCredentials.account(
            region: .china,
            environment: [MiniMaxCredentials.cookieEnvironment: "session=abc"]
        )
        XCTAssertEqual(fromCookie?.source, "MiniMax")
        XCTAssertEqual(fromCookie?.manageURL,
                       URL(string: "https://platform.minimax.cn/user-center/payment/coding-plan"))
    }

    func testInternationalAndChinaHostsStayOnTheirOwnConsoles() {
        XCTAssertEqual(MiniMaxRegion.international.apiBase.absoluteString, "https://api.minimax.io")
        XCTAssertEqual(MiniMaxRegion.international.platformOrigin.absoluteString, "https://platform.minimax.io")
        XCTAssertEqual(MiniMaxRegion.international.remainsURL.absoluteString,
                       "https://www.minimax.io/v1/api/openplatform/coding_plan/remains")
        XCTAssertEqual(MiniMaxRegion.international.tokenPlanRemainsURL.absoluteString,
                       "https://api.minimax.io/v1/token_plan/remains")
        XCTAssertEqual(MiniMaxRegion.international.codingPlanRemainsURL.absoluteString,
                       "https://api.minimax.io/v1/api/openplatform/coding_plan/remains")
        XCTAssertEqual(MiniMaxRegion.international.displayName, "International")

        XCTAssertEqual(MiniMaxRegion.china.apiBase.absoluteString, "https://api.minimaxi.com")
        XCTAssertEqual(MiniMaxRegion.china.platformOrigin.absoluteString, "https://platform.minimax.cn")
        XCTAssertEqual(MiniMaxRegion.china.remainsURL.absoluteString,
                       "https://www.minimax.cn/v1/api/openplatform/coding_plan/remains")
        XCTAssertEqual(MiniMaxRegion.china.tokenPlanRemainsURL.absoluteString,
                       "https://api.minimaxi.com/v1/token_plan/remains")
        XCTAssertEqual(MiniMaxRegion.china.codingPlanRemainsURL.absoluteString,
                       "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains")
        XCTAssertEqual(MiniMaxProvider.apiKeyRemainsURLs(for: .china).map(\.absoluteString), [
            "https://api.minimaxi.com/v1/token_plan/remains",
            "https://www.minimax.cn/v1/token_plan/remains",
            "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"
        ])
        XCTAssertEqual(MiniMaxRegion.china.displayName, "China")

        XCTAssertEqual(MiniMaxRegion.allCases, [.international, .china])
    }
}
