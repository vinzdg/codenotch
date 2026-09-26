import XCTest
@testable import Codenotch

final class CustomEndpointTests: XCTestCase {
    func testCustomEndpointDefaultValues() {
        let endpoint = CustomEndpoint(
            name: "Test vLLM",
            baseURL: "http://localhost:8000/v1"
        )

        XCTAssertEqual(endpoint.name, "Test vLLM")
        XCTAssertEqual(endpoint.baseURL, "http://localhost:8000/v1")
        XCTAssertEqual(endpoint.headerKey, "Authorization")
        XCTAssertEqual(endpoint.accentColorHex, "#6366F1")
        XCTAssertEqual(endpoint.iconPreset, "openai")
        XCTAssertTrue(endpoint.isEnabled)
        XCTAssertEqual(endpoint.lastHealthStatus, .idle)
        XCTAssertEqual(endpoint.computedSpendUSD, 0.0)
        XCTAssertEqual(endpoint.usedFraction, 0.0)
    }

    func testUsedFractionWithBudget() {
        var endpoint = CustomEndpoint(
            name: "Budget Test",
            baseURL: "https://api.groq.com/openai/v1",
            monthlyBudgetUSD: 20.0,
            currentSpendUSD: 5.0
        )

        XCTAssertEqual(endpoint.usedFraction, 0.25, accuracy: 0.001)

        // Spend at budget
        endpoint.currentSpendUSD = 20.0
        XCTAssertEqual(endpoint.usedFraction, 1.0, accuracy: 0.001)

        // Spend over budget caps at 1.0
        endpoint.currentSpendUSD = 25.0
        XCTAssertEqual(endpoint.usedFraction, 1.0, accuracy: 0.001)

        // No budget
        endpoint.monthlyBudgetUSD = nil
        XCTAssertEqual(endpoint.usedFraction, 0.0)

        // Display remaining mode
        var remainingEndpoint = CustomEndpoint(
            name: "Remaining Test",
            baseURL: "https://api.groq.com/openai/v1",
            monthlyBudgetUSD: 100.0,
            currentSpendUSD: 25.0,
            displayRemaining: true
        )
        XCTAssertEqual(remainingEndpoint.remainingFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(remainingEndpoint.usedFraction, 0.75, accuracy: 0.001)

        remainingEndpoint.currentSpendUSD = 100.0
        XCTAssertEqual(remainingEndpoint.remainingFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(remainingEndpoint.usedFraction, 0.0, accuracy: 0.001)

        // Show currency flag
        XCTAssertFalse(remainingEndpoint.showCurrency)
        remainingEndpoint.showCurrency = true
        XCTAssertTrue(remainingEndpoint.showCurrency)
    }

    func testURLValidation() {
        XCTAssertTrue(CustomEndpoint.isValidURL("https://api.openai.com/v1"))
        XCTAssertTrue(CustomEndpoint.isValidURL("http://localhost:8000/v1"))
        XCTAssertTrue(CustomEndpoint.isValidURL("http://127.0.0.1:11434"))

        XCTAssertFalse(CustomEndpoint.isValidURL(""))
        XCTAssertFalse(CustomEndpoint.isValidURL("not a url"))
        XCTAssertFalse(CustomEndpoint.isValidURL("ftp://server.local"))
        XCTAssertFalse(CustomEndpoint.isValidURL("javascript:alert(1)"))
        XCTAssertFalse(CustomEndpoint.isValidURL("file:///etc/passwd"))
    }

    func testPresetsCoverage() {
        let presets = CustomEndpointPreset.templates
        XCTAssertFalse(presets.isEmpty)

        let openRouter = presets.first { $0.id == "openrouter" }
        XCTAssertNotNil(openRouter)
        XCTAssertEqual(openRouter?.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertTrue(CustomEndpoint.isValidURL(openRouter?.baseURL ?? ""))

        let groq = presets.first { $0.id == "groq" }
        XCTAssertNotNil(groq)
        XCTAssertEqual(groq?.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertTrue(CustomEndpoint.isValidURL(groq?.baseURL ?? ""))

        let vllm = presets.first { $0.id == "vllm" }
        XCTAssertNotNil(vllm)
        XCTAssertEqual(vllm?.baseURL, "http://localhost:8000/v1")
        XCTAssertTrue(CustomEndpoint.isValidURL(vllm?.baseURL ?? ""))
    }

    func testCustomEndpointJSONCodableNeverStoresAPIKey() throws {
        let endpointID = "test-codable-\(UUID().uuidString)"
        let original = CustomEndpoint(
            id: endpointID,
            name: "Together AI",
            baseURL: "https://api.together.xyz/v1",
            headerKey: "Authorization",
            selectedModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            availableModels: ["meta-llama/Llama-3.3-70B-Instruct-Turbo"],
            isEnabled: true,
            accentColorHex: "#06B6D4",
            iconPreset: "meta",
            customIconFilename: "custom.png",
            monthlyBudgetUSD: 15.0,
            currentSpendUSD: 3.50,
            lastLatencyMs: 48,
            lastHealthStatus: .online,
            lastCheckedAt: Date(timeIntervalSince1970: 1700000000)
        )

        let data = try JSONEncoder().encode(original)
        let jsonString = String(data: data, encoding: .utf8) ?? ""

        // Crucial security check: apiKey must never be serialized into JSON
        XCTAssertFalse(jsonString.contains("apiKey"))
        XCTAssertFalse(jsonString.contains("secret"))

        let decoded = try JSONDecoder().decode(CustomEndpoint.self, from: data)
        XCTAssertEqual(decoded.id, endpointID)
        XCTAssertEqual(decoded.name, "Together AI")
        XCTAssertEqual(decoded.availableModels.count, 1)
        XCTAssertEqual(decoded.computedSpendUSD, 3.50)
        XCTAssertEqual(decoded.monthlyBudgetUSD, 15.0)
        XCTAssertEqual(decoded.lastLatencyMs, 48)
        XCTAssertEqual(decoded.lastHealthStatus, .online)
    }

    func testKeychainAPIKeyStorageAndDeletion() {
        let endpointID = "keychain-test-\(UUID().uuidString)"
        let endpoint = CustomEndpoint(
            id: endpointID,
            name: "Secure Endpoint",
            baseURL: "https://api.openai.com/v1"
        )

        defer {
            endpoint.deleteAPIKey()
        }

        XCTAssertNil(endpoint.apiKey)

        let testKey = "sk-test-secret-key-12345"
        endpoint.saveAPIKey(testKey)
        XCTAssertEqual(endpoint.apiKey, testKey)

        endpoint.deleteAPIKey()
        XCTAssertNil(endpoint.apiKey)
    }

    func testCustomEndpointTokenTracking() {
        var endpoint = CustomEndpoint(
            name: "Tokens Test",
            baseURL: "http://localhost:8000/v1",
            trackingUnit: .tokens,
            monthlyBudgetTokensM: 10.0,
            currentTokensUsedM: 2.5
        )

        XCTAssertEqual(endpoint.trackingUnit, .tokens)
        XCTAssertEqual(endpoint.computedTokensUsedM, 2.5)
        XCTAssertEqual(endpoint.usedFraction, 0.25, accuracy: 0.001)

        // Tokens at budget
        endpoint.currentTokensUsedM = 10.0
        XCTAssertEqual(endpoint.usedFraction, 1.0, accuracy: 0.001)

        // Tokens over budget caps at 1.0
        endpoint.currentTokensUsedM = 15.0
        XCTAssertEqual(endpoint.usedFraction, 1.0, accuracy: 0.001)

        // No budget
        endpoint.monthlyBudgetTokensM = nil
        XCTAssertEqual(endpoint.usedFraction, 0.0)

        // Display remaining mode
        var remainingEndpoint = CustomEndpoint(
            name: "Remaining Tokens Test",
            baseURL: "http://localhost:8000/v1",
            trackingUnit: .tokens,
            monthlyBudgetTokensM: 100.0,
            currentTokensUsedM: 25.0,
            displayRemaining: true
        )
        XCTAssertEqual(remainingEndpoint.remainingTokensFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(remainingEndpoint.remainingFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(remainingEndpoint.usedTokensFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(remainingEndpoint.usedFraction, 0.75, accuracy: 0.001)

        remainingEndpoint.currentTokensUsedM = 100.0
        XCTAssertEqual(remainingEndpoint.remainingFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(remainingEndpoint.usedFraction, 0.0, accuracy: 0.001)
    }

    func testFormatTokenMillions() {
        XCTAssertEqual(CustomEndpoint.formatTokenMillions(0), "0M")
        XCTAssertEqual(CustomEndpoint.formatTokenMillions(0.05), "50k")
        XCTAssertEqual(CustomEndpoint.formatTokenMillions(0.25), "250k")
        XCTAssertEqual(CustomEndpoint.formatTokenMillions(1.0), "1M")
        XCTAssertEqual(CustomEndpoint.formatTokenMillions(2.5), "2.5M")
        XCTAssertEqual(CustomEndpoint.formatTokenMillions(10.0), "10M")
        XCTAssertEqual(CustomEndpoint.formatTokenMillions(25.0), "25M")
        XCTAssertEqual(CustomEndpoint.formatTokenMillions(1200.0), "1.2B")
    }

    func testCustomEndpointTokenCodable() throws {
        let original = CustomEndpoint(
            name: "Token Codable Test",
            baseURL: "http://localhost:11434/v1",
            trackingUnit: .tokens,
            monthlyBudgetTokensM: 50.0,
            currentTokensUsedM: 12.5
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomEndpoint.self, from: data)

        XCTAssertEqual(decoded.trackingUnit, .tokens)
        XCTAssertEqual(decoded.monthlyBudgetTokensM, 50.0)
        XCTAssertEqual(decoded.currentTokensUsedM, 12.5)

        // Legacy JSON without trackingUnit should decode as .currency
        let legacyJSON = """
        {
            "id": "legacy-id",
            "name": "Legacy Endpoint",
            "baseURL": "https://api.openai.com/v1",
            "headerKey": "Authorization",
            "accentColorHex": "#6366F1",
            "isEnabled": true,
            "monthlyBudgetUSD": 20.0,
            "currentSpendUSD": 5.0
        }
        """.data(using: .utf8)!

        let decodedLegacy = try JSONDecoder().decode(CustomEndpoint.self, from: legacyJSON)
        XCTAssertEqual(decodedLegacy.trackingUnit, .currency)
        XCTAssertEqual(decodedLegacy.monthlyBudgetUSD, 20.0)
        XCTAssertEqual(decodedLegacy.currentSpendUSD, 5.0)
        XCTAssertNil(decodedLegacy.monthlyBudgetTokensM)
        XCTAssertNil(decodedLegacy.currentTokensUsedM)
    }
    func testJSONUsageParserFiltersModelAndConvertsTokensToMillions() {
        let data = Data(#"""
        {
          "model_token_usage": [
            {"model": "other", "total_tokens": 9000},
            {"model": "mimo", "total_tokens": 7347},
            {"model": "mimo", "total_tokens": 1760}
          ]
        }
        """#.utf8)

        let millions = CustomEndpointNetwork.parseJSONUsage(
            data: data,
            recordsPath: "model_token_usage",
            modelField: "model",
            tokenField: "total_tokens",
            modelFilter: "mimo"
        )

        guard let millions else {
            XCTFail("Expected a matching usage record")
            return
        }
        XCTAssertEqual(millions, 0.009107, accuracy: 0.000000001)
    }
    func testPresetParsersDistinguishZeroMissingAndUnits() {
        func parse(_ preset: CustomEndpointUsagePreset, _ text: String) -> CustomEndpointPresetReading? {
            CustomEndpointPresetUsage.parsePreset(preset, data: Data(text.utf8))
        }
        XCTAssertEqual(parse(.vllm, """
            vllm:prompt_tokens_total{model="a"} 12000
            vllm:prompt_tokens_total{model="b"} 0
            vllm:generation_tokens_total{model="a"} 3000
            vllm:generation_tokens_total{model="b"} 0
            """), .tokens(15000))
        XCTAssertEqual(parse(.vllm, "vllm:prompt_tokens_total 0\nvllm:generation_tokens_total 0"), .tokens(0))
        XCTAssertEqual(parse(.vllm, "vllm:prompt_tokens_total 2\nvllm:generation_tokens_total 3"), .tokens(5),
                       "a restart replaces uptime counters rather than creating a daily delta")
        for invalid in [
            "vllm:prompt_tokens_total 0",
            "vllm:prompt_tokens_total NaN\nvllm:generation_tokens_total 0",
            "vllm:prompt_tokens_total -1\nvllm:generation_tokens_total 0",
            "vllm:prompt_tokens_total{model=\"a\"} 1\nvllm:prompt_tokens_total{model=\"a\"} 2\nvllm:generation_tokens_total 0",
            "vllm:prompt_tokens_total_bucket 5\nvllm:generation_tokens_total 0"
        ] {
            XCTAssertNil(parse(.vllm, invalid), invalid)
        }
        XCTAssertEqual(parse(.llamaCpp, "llamacpp:prompt_tokens_total 8\nllamacpp:tokens_predicted_total 3"), .tokens(11))
        XCTAssertEqual(parse(.openRouter, #"{"data":{"usage":90,"usage_monthly":3.5}}"#),
                       .spendUSD(3.5, period: .month))
        XCTAssertNil(parse(.openRouter, #"{"data":{"usage":90}}"#))
        XCTAssertEqual(parse(.litellm, #"{"info":{"spend":4.12}}"#), .spendUSD(4.12, period: .lifetime))
        XCTAssertEqual(parse(.newAPI, #"{"data":{"object":"token_usage","total_used":12345,"total_granted":1000000}}"#),
                       .quota(used: 12345, granted: 1000000))
        XCTAssertEqual(parse(.newAPI, #"{"data":{"object":"token_usage","total_used":0,"total_granted":100,"unlimited_quota":true}}"#),
                       .quota(used: 0, granted: nil))
        XCTAssertNil(parse(.newAPI, #"{"data":{"object":"token_usage","total_used":false}}"#))
        XCTAssertNil(parse(.litellm, #"{"info":{"spend":true}}"#))
        XCTAssertEqual(parse(.abacus, #"{"success":true,"result":{"computePointsLeft":934.25,"totalComputePoints":83666.66,"monthlyPtsPerUser":30000.0,"normalMonthlyCredits":20000.0,"userCount":1}}"#),
                       .credits(left: 934.25, monthly: 20000, total: 83666.66))
        XCTAssertNil(parse(.abacus, #"{"success":false,"error":"Invalid API key"}"#))
        XCTAssertNil(parse(.abacus, #"{"success":true,"result":{"computePointsLeft":-1,"totalComputePoints":1,"normalMonthlyCredits":20000}}"#))
        XCTAssertEqual(CustomEndpointPresetUsage.formatCredits(934.25), "934")
        XCTAssertEqual(CustomEndpointPresetUsage.formatCredits(19065), "19.1K")
        XCTAssertEqual(CustomEndpointPresetUsage.formatCredits(20000), "20K")
    }

    func testAbacusPresetURLIsPinnedToRouteLLMHost() {
        XCTAssertEqual(CustomEndpointPresetUsage.presetURL(.abacus, baseURL: "https://routellm.abacus.ai/v1")?.absoluteString,
                       "https://routellm.abacus.ai/api/v0/_getOrganizationComputePoints")
        XCTAssertNil(CustomEndpointPresetUsage.presetURL(.abacus, baseURL: "https://evil.example/v1"))
        XCTAssertNil(CustomEndpointPresetUsage.presetURL(.abacus, baseURL: "http://routellm.abacus.ai/v1"))
    }

    func testPresetURLCannotLeakCredentialsOrChangeOpenRouterOrigin() {
        XCTAssertEqual(CustomEndpointPresetUsage.presetURL(.vllm, baseURL: "http://127.0.0.1:8000/proxy/v1")?.absoluteString,
                       "http://127.0.0.1:8000/proxy/metrics")
        XCTAssertEqual(CustomEndpointPresetUsage.presetURL(.openRouter, baseURL: "https://openrouter.ai/api/v1/")?.absoluteString,
                       "https://openrouter.ai/api/v1/key")
        XCTAssertNil(CustomEndpointPresetUsage.presetURL(.openRouter, baseURL: "https://evil.example/api/v1"))
        XCTAssertNil(CustomEndpointPresetUsage.presetURL(.vllm, baseURL: "https://user:pass@example.com/v1"))
        XCTAssertNil(CustomEndpointPresetUsage.presetURL(.vllm, baseURL: "https://example.com/v1?key=secret"))
    }

    func testPresetCodableKeepsCustomJSONMappingWhenSelectionChanges() throws {
        let legacy = Data(#"{"id":"old","name":"Old","baseURL":"https://example.com/v1","usageSource":"jsonEndpoint","usageURL":"https://example.com/usage","usageRecordsPath":"items","usageModelField":"model","usageTokenField":"tokens"}"#.utf8)
        var endpoint = try JSONDecoder().decode(CustomEndpoint.self, from: legacy)
        XCTAssertNil(endpoint.usagePreset)
        endpoint.usagePreset = .vllm
        endpoint = try JSONDecoder().decode(CustomEndpoint.self, from: JSONEncoder().encode(endpoint))
        XCTAssertEqual(endpoint.usagePreset, .vllm)
        endpoint.usagePreset = nil
        endpoint = try JSONDecoder().decode(CustomEndpoint.self, from: JSONEncoder().encode(endpoint))
        XCTAssertEqual(endpoint.usageURL, "https://example.com/usage")
        XCTAssertEqual(endpoint.usageRecordsPath, "items")
        XCTAssertEqual(endpoint.usageTokenField, "tokens")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(endpoint), as: UTF8.self).contains("usagePreset"))
    }
    func testPresetSnapshotUsesUsageEvenWhenModelsUnavailable() async throws {
        let endpoint = CustomEndpoint(
            name: "Local vLLM", baseURL: "http://127.0.0.1:8000/v1",
            usageSource: .jsonEndpoint, usagePreset: .vllm
        )
        var count = 0
        let network = presetNetwork { request in
            count += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8000/metrics")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data("vllm:prompt_tokens_total 12000\nvllm:generation_tokens_total 3000".utf8))
        }
        let provider = CustomEndpointProvider(endpoint: endpoint, network: network, endpointLoader: { _ in endpoint })
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(count, 1, "named usage must not probe /models")
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.windows.first?.label, L10n.t("Tokens Since Server Start"))
        XCTAssertEqual(snapshot.windows.first?.usedText, "15k")
        XCTAssertNil(snapshot.windows.first?.usedFraction)
        XCTAssertNil(snapshot.customUsageHistory)
    }

    func testPresetCounterRestartIsNotRenderedAsMonthlyHistory() async throws {
        let endpoint = CustomEndpoint(
            name: "Local", baseURL: "http://127.0.0.1:8000/v1",
            usageSource: .jsonEndpoint, usagePreset: .vllm,
            usageHistory: [CustomEndpointUsageDay(day: "2026-09-01", totalTokens: 15000)]
        )
        var count = 0
        let network = presetNetwork { _ in
            count += 1
            let total = count == 1 ? 15000 : 5
            return (200, Data("vllm:prompt_tokens_total \(total)\nvllm:generation_tokens_total 0".utf8))
        }
        let provider = CustomEndpointProvider(endpoint: endpoint, network: network, endpointLoader: { _ in endpoint })
        let before = try await provider.fetchSnapshot()
        let after = try await provider.fetchSnapshot()
        XCTAssertEqual(before.windows.first?.usedText, "15k")
        XCTAssertEqual(after.windows.first?.usedText, "5")
        XCTAssertNil(after.customUsageHistory)
    }
    func testPresetNetworkRejectsUnauthorizedRedirectAndMalformedMetrics() async {
        let endpoint = CustomEndpoint(
            name: "Local", baseURL: "http://127.0.0.1:8000/v1",
            usageSource: .jsonEndpoint, usagePreset: .vllm
        )
        for status in [401, 403, 302, 404, 200] {
            var requests = 0
            let network = presetNetwork { request in
                requests += 1
                XCTAssertEqual(request.url?.host, "127.0.0.1")
                if status == 200 { return (status, Data("vllm:prompt_tokens_total 0".utf8)) }
                return (status, Data())
            }
            let provider = CustomEndpointProvider(endpoint: endpoint, network: network, endpointLoader: { _ in endpoint })
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("HTTP \(status) or missing metric succeeded")
            } catch UsageProviderError.needsAuth {
                XCTAssertTrue(status == 401 || status == 403)
            } catch UsageProviderError.badResponse(let code) {
                XCTAssertEqual(code, status == 200 || status == 302 ? 503 : status)
            } catch {
                XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(requests, 1)
        }
    }

    func testPresetRedirectNeverCarriesKeyToAnotherHost() async {
        var requests = 0
        let network = presetNetwork { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (302, Data())
        }
        do {
            _ = try await network.fetchPresetUsage(
                .vllm, baseURL: "http://127.0.0.1:8000/v1",
                apiKey: "secret", headerKey: "Authorization"
            )
            XCTFail("Redirect succeeded")
        } catch UsageProviderError.badResponse {
            XCTAssertEqual(requests, 1)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testPresetDetectionOnlySelectsKnownSchema() async {
        var requests = 0
        let network = presetNetwork { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            return (200, Data(#"{"data":{"usage":3}}"#.utf8))
        }
        let result = await network.detectPreset(
            baseURL: "http://127.0.0.1:8000/v1", apiKey: "", headerKey: "Authorization"
        )
        XCTAssertEqual(result, .unsupported)
        XCTAssertEqual(requests, 3, "probe /metrics only once, then New-API and LiteLLM")
    }

    func testPresetDetectionMatchedVLLMEvenWithZeroOrDelayed() async {
        let network = presetNetwork { request in
            if request.url?.path == "/metrics" {
                return (200, Data("vllm:prompt_tokens_total 12000\nvllm:generation_tokens_total 3000\n".utf8))
            }
            return (404, Data())
        }
        let result = await network.detectPreset(
            baseURL: "http://127.0.0.1:8000/v1", apiKey: "", headerKey: "Authorization"
        )
        XCTAssertEqual(result, .matched(.vllm))
    }

    func testPresetDetectionMatchedZeroCounters() async {
        let network = presetNetwork { request in
            if request.url?.path == "/metrics" {
                return (200, Data("vllm:prompt_tokens_total 0\nvllm:generation_tokens_total 0\n".utf8))
            }
            return (404, Data())
        }
        let result = await network.detectPreset(
            baseURL: "http://127.0.0.1:8000/v1", apiKey: "", headerKey: "Authorization"
        )
        XCTAssertEqual(result, .matched(.vllm))
    }

    func testPresetDetectionNeedsAuth() async {
        let network = presetNetwork { _ in
            (401, Data())
        }
        let result = await network.detectPreset(
            baseURL: "http://127.0.0.1:8000/v1", apiKey: "", headerKey: "Authorization"
        )
        XCTAssertEqual(result, .needsAuth)
    }

    func testPresetDetectionUnavailableOnServerError() async {
        let network = presetNetwork { _ in
            (500, Data())
        }
        let result = await network.detectPreset(
            baseURL: "http://127.0.0.1:8000/v1", apiKey: "", headerKey: "Authorization"
        )
        XCTAssertEqual(result, .unavailable)
    }

    func testPresetDetectionGenericModelsJSONDoesNotMatch() async {
        let network = presetNetwork { request in
            return (200, Data(#"{"object":"list","data":[{"id":"gpt-4o","object":"model"}]}"#.utf8))
        }
        let result = await network.detectPreset(
            baseURL: "http://127.0.0.1:8000/v1", apiKey: "", headerKey: "Authorization"
        )
        XCTAssertEqual(result, .unsupported)
    }

    func testCustomEndpointJSONPresetFileImport() throws {
        let json = """
        {
          "version": 1,
          "unit": "tokens",
          "usageURL": "https://proxy.example.com/usage",
          "recordsPath": "model_token_usage",
          "modelField": "model",
          "tokenField": "total_tokens",
          "modelFilter": "optional-model-name"
        }
        """
        let file = try CustomEndpointJSONPresetFile.importMapping(Data(json.utf8), baseURL: "https://proxy.example.com/v1")
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.unit, "tokens")
        XCTAssertEqual(file.usageURL, "https://proxy.example.com/usage")
        XCTAssertEqual(file.recordsPath, "model_token_usage")
        XCTAssertEqual(file.modelField, "model")
        XCTAssertEqual(file.tokenField, "total_tokens")
        XCTAssertEqual(file.modelFilter, "optional-model-name")
    }

    func testCustomEndpointJSONPresetFileImportWithoutModelFilter() throws {
        let json = """
        {
          "version": 1,
          "unit": "tokens",
          "usageURL": "https://proxy.example.com/usage",
          "recordsPath": "model_token_usage",
          "modelField": "model",
          "tokenField": "total_tokens"
        }
        """
        let file = try CustomEndpointJSONPresetFile.importMapping(Data(json.utf8), baseURL: "https://proxy.example.com/v1")
        XCTAssertNil(file.modelFilter)
    }

    func testCustomEndpointJSONPresetFileRejectsBadVersionOrUnit() {
        let badVersion = """
        {
          "version": 2,
          "unit": "tokens",
          "usageURL": "https://proxy.example.com/usage",
          "recordsPath": "model_token_usage",
          "modelField": "model",
          "tokenField": "total_tokens"
        }
        """
        XCTAssertThrowsError(try CustomEndpointJSONPresetFile.importMapping(Data(badVersion.utf8), baseURL: "https://proxy.example.com/v1"))

        let badUnit = """
        {
          "version": 1,
          "unit": "usd",
          "usageURL": "https://proxy.example.com/usage",
          "recordsPath": "model_token_usage",
          "modelField": "model",
          "tokenField": "total_tokens"
        }
        """
        XCTAssertThrowsError(try CustomEndpointJSONPresetFile.importMapping(Data(badUnit.utf8), baseURL: "https://proxy.example.com/v1"))
    }

    func testCustomEndpointJSONPresetFileRejectsUnknownFieldsAndCredentials() {
        let unknownField = """
        {
          "version": 1,
          "unit": "tokens",
          "usageURL": "https://proxy.example.com/usage",
          "recordsPath": "model_token_usage",
          "modelField": "model",
          "tokenField": "total_tokens",
          "apiKey": "secret"
        }
        """
        XCTAssertThrowsError(try CustomEndpointJSONPresetFile.importMapping(Data(unknownField.utf8), baseURL: "https://proxy.example.com/v1"))
    }

    func testCustomEndpointJSONPresetFileRejectsCrossOriginAndUserInfo() {
        let crossHost = """
        {
          "version": 1,
          "unit": "tokens",
          "usageURL": "https://other.example.com/usage",
          "recordsPath": "model_token_usage",
          "modelField": "model",
          "tokenField": "total_tokens"
        }
        """
        XCTAssertThrowsError(try CustomEndpointJSONPresetFile.importMapping(Data(crossHost.utf8), baseURL: "https://proxy.example.com/v1"))

        let withQuery = """
        {
          "version": 1,
          "unit": "tokens",
          "usageURL": "https://proxy.example.com/usage?foo=bar",
          "recordsPath": "model_token_usage",
          "modelField": "model",
          "tokenField": "total_tokens"
        }
        """
        XCTAssertThrowsError(try CustomEndpointJSONPresetFile.importMapping(Data(withQuery.utf8), baseURL: "https://proxy.example.com/v1"))
    }

    func testParseJSONUsageEmptyRecordsReturnsZero() {
        let json = #"{"records":[]}"#
        let parsed = CustomEndpointNetwork.parseJSONUsage(
            data: Data(json.utf8),
            recordsPath: "records",
            modelField: "model",
            tokenField: "tokens",
            modelFilter: nil
        )
        XCTAssertEqual(parsed, 0.0)
    }

    func testParseJSONUsageRejectsBooleansAndMissingField() {
        let jsonBool = #"{"records":[{"model":"m","tokens":true}]}"#
        let parsedBool = CustomEndpointNetwork.parseJSONUsage(
            data: Data(jsonBool.utf8),
            recordsPath: "records",
            modelField: "model",
            tokenField: "tokens",
            modelFilter: nil
        )
        XCTAssertNil(parsedBool)

        let jsonMissing = #"{"records":[{"model":"m"}]}"#
        let parsedMissing = CustomEndpointNetwork.parseJSONUsage(
            data: Data(jsonMissing.utf8),
            recordsPath: "records",
            modelField: "model",
            tokenField: "tokens",
            modelFilter: nil
        )
        XCTAssertNil(parsedMissing)
    }

    @MainActor
    func testPreferencesReconciliationPreservesSampledReadingsWhenMappingUnchanged() {
        let defaults = UserDefaults(suiteName: "testPreferencesReconciliation")!
        defaults.removePersistentDomain(forName: "testPreferencesReconciliation")
        let endpoint = CustomEndpoint(
            id: "ep-1",
            name: "Original",
            baseURL: "http://127.0.0.1:8000/v1",
            usageSource: .jsonEndpoint,
            usageURL: "http://127.0.0.1:8000/usage",
            usageRecordsPath: "records",
            usageModelField: "model",
            usageTokenField: "tokens",
            usageHistory: [],
            trackingUnit: .tokens,
            currentTokensUsedM: 0.0
        )
        let prefs = Preferences(defaults: defaults)
        prefs.addCustomEndpoint(endpoint)

        // Simulate background provider sampling 15,000 tokens (0.015M)
        var stored = endpoint
        stored.currentTokensUsedM = 0.015
        stored.usageHistory = [CustomEndpointUsageDay(day: "2026-09-24", totalTokens: 15000)]
        Preferences.updateStoredCustomEndpoint(stored, defaults: defaults)

        // Settings edits only the name and saves
        var edited = endpoint
        edited.name = "Renamed"
        prefs.updateCustomEndpoint(edited)

        let updated = prefs.customEndpoints.first(where: { $0.id == "ep-1" })
        XCTAssertEqual(updated?.name, "Renamed")
        XCTAssertEqual(updated?.currentTokensUsedM, 0.015)
        XCTAssertEqual(updated?.usageHistory.count, 1)
    }

    @MainActor
    func testPreferencesReconciliationDoesNotMergeWhenMappingChanged() {
        let defaults = UserDefaults(suiteName: "testPreferencesReconciliationChanged")!
        defaults.removePersistentDomain(forName: "testPreferencesReconciliationChanged")
        let endpoint = CustomEndpoint(
            id: "ep-2",
            name: "Original",
            baseURL: "http://127.0.0.1:8000/v1",
            usageSource: .jsonEndpoint,
            usageURL: "http://127.0.0.1:8000/usage",
            usageRecordsPath: "records",
            usageModelField: "model",
            usageTokenField: "tokens",
            usageHistory: [],
            trackingUnit: .tokens,
            currentTokensUsedM: 0.0
        )
        let prefs = Preferences(defaults: defaults)
        prefs.addCustomEndpoint(endpoint)

        // Background provider sampled old mapping
        var stored = endpoint
        stored.currentTokensUsedM = 0.015
        stored.usageHistory = [CustomEndpointUsageDay(day: "2026-09-24", totalTokens: 15000)]
        Preferences.updateStoredCustomEndpoint(stored, defaults: defaults)

        // User imported new mapping (usageURL changed) with cleared readings
        var edited = endpoint
        edited.usageURL = "http://127.0.0.1:8000/new-usage"
        edited.currentTokensUsedM = 0.0
        edited.usageHistory = []
        prefs.updateCustomEndpoint(edited)

        let updated = prefs.customEndpoints.first(where: { $0.id == "ep-2" })
        XCTAssertEqual(updated?.usageURL, "http://127.0.0.1:8000/new-usage")
        XCTAssertEqual(updated?.currentTokensUsedM, 0.0)
        XCTAssertEqual(updated?.usageHistory.count, 0)
    }

    private func presetNetwork(_ handler: @escaping (URLRequest) -> (Int, Data)) -> CustomEndpointNetwork {
        PresetUsageStubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresetUsageStubProtocol.self]
        return CustomEndpointNetwork(session: URLSession(configuration: configuration))
    }
}

private final class PresetUsageStubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: status == 302 ? ["Location": "https://evil.example/metrics"] : nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
