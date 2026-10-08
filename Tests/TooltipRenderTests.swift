import XCTest
import SwiftUI
@testable import Codenotch

/// Renders the tooltip with a session in every state.
///
/// Partly a smoke test — a card that fails to lay out fails here rather than on
/// someone's screen — and partly a way to actually look at it: set
/// `TOOLTIP_RENDER_PATH` and the frame is written there.
@MainActor
final class TooltipRenderTests: XCTestCase {
    func testAmpDetailsRenderBesideTheHoveredRing() throws {
        let reading = try AmpUsage.parse(AmpFixture.tier)
        let model = NotchViewModel()
        model.edge = .right
        model.snapshots = [ProviderSnapshot(
            id: "amp", displayName: "Amp", glyph: .amp, fidelity: reading.fidelity,
            status: .ok, windows: reading.windows, headlineID: reading.headlineID, plan: reading.plan
        )]
        model.isExpanded = true
        model.hoveredIndex = 0
        for style in [NotchSurfaceStyle.solid, .glass] {
            model.surfaceStyle = style
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: model.panelSize.width, height: model.panelSize.height)
                .environment(\.colorScheme, .dark)
                .environment(\.codenotchHeadlessGlass, true))
            let image = try XCTUnwrap(renderer.cgImage)
            let pixels = NSBitmapImageRep(cgImage: image)
            var ink = 0
            for x in stride(from: 0, to: Int(NotchLayout.cardWidth), by: 2) {
                for y in stride(from: 0, to: pixels.pixelsHigh, by: 2) {
                    if (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 }
                }
            }
            XCTAssertGreaterThan(ink, 100, "\(style): no card content beside the hovered ring")
        }
    }

    func testAmpSubscriptionAndFreeCardsRenderWithTheirGlyph() throws {
        XCTAssertNotNil(NSImage(named: ProviderGlyph.amp.assetName))
        for (name, data) in [("subscription", AmpFixture.tier), ("free", AmpFixture.free)] {
            let reading = try AmpUsage.parse(data)
            let snapshot = ProviderSnapshot(
                id: "amp", displayName: "Amp", glyph: .amp, fidelity: reading.fidelity,
                status: .ok, windows: reading.windows, headlineID: reading.headlineID, plan: reading.plan
            )
            let view = HStack(spacing: 20) {
                VStack {
                    ProviderRing(usedFraction: snapshot.usedFraction, glyph: .amp)
                    Text(snapshot.headlineText).foregroundStyle(.white)
                }
                TooltipCard(snapshot: snapshot, now: Date(), direction: .trailing)
            }
            .padding(20)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.notchSurfaceStyle, .solid)
            .environment(\.codenotchAccentColor, .blue)
            .environment(\.codenotchHeadlessGlass, true)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertGreaterThan(image.size.width, NotchLayout.cardWidth)
            XCTAssertGreaterThan(image.size.height, 100)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "amp-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// The card with a fixture at 80% of a $1,500 cap — the render behind
    /// docs/providers/apify.png, attached rather than compared: the point is
    /// that the money row and the reset draw beside the mark, not their pixels.
    func testApifyCardRendersWithItsGlyph() throws {
        XCTAssertNotNil(NSImage(named: ProviderGlyph.apify.assetName))
        let windows = try ApifyUsage.windows(from: Data(ApifyFixture.limits.utf8))
        let snapshot = ProviderSnapshot(
            id: "apify", displayName: "Apify", glyph: .apify, fidelity: .official,
            status: .ok, windows: windows, headlineID: ApifyUsage.headlineID, plan: "Scale"
        )
        let view = HStack(spacing: 20) {
            VStack {
                ProviderRing(usedFraction: snapshot.usedFraction, glyph: .apify)
                Text(snapshot.headlineText).foregroundStyle(.white)
            }
            TooltipCard(snapshot: snapshot, now: Date(timeIntervalSince1970: 1_790_000_000), direction: .trailing)
        }
        .padding(20)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environment(\.notchSurfaceStyle, .solid)
        .environment(\.codenotchAccentColor, .blue)
        .environment(\.codenotchHeadlessGlass, true)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.width, NotchLayout.cardWidth)
        XCTAssertGreaterThan(image.size.height, 100)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "apify-monthly"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func session(_ name: String, _ state: AgentSession.State,
                         minutes: Int) -> AgentSession {
        AgentSession(id: name, name: name, detail: "Terminal · usage-notch",
                     state: state, waitingFor: state == .waiting ? "your answer" : nil,
                     since: Date().addingTimeInterval(Double(-minutes) * 60))
    }

    func testClaudeCardRendersUnusedResetsAndShrinksAfterExpiry() throws {
        let now = Date()
        let response = try UsageResponse.decoder.decode(UsageResponse.self, from: ClaudeResetFixture.futureUsage)
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
            status: .ok, windows: response.limitWindows(),
            resetCredits: response.cedarEmber?.credits(at: now)
        )
        let withResets = try renderClaudeResets(snapshot, now: now)
        var cached = snapshot
        cached.resetCredits?.checkedAt = now.addingTimeInterval(-184 * 60)
        let withCachedResets = try renderClaudeResets(cached, now: now)
        XCTAssertEqual(withResets.size.height, withCachedResets.size.height)
        let expiry = try XCTUnwrap(snapshot.resetCredits?.nextExpiry)
        let expired = try renderClaudeResets(snapshot, now: expiry)
        XCTAssertGreaterThan(withResets.size.height, expired.size.height)
    }

    /// Explicit manual QA only: normal tests never read the user's cache.
    func testLiveClaudeResetCard() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_RESET_LIVE_RENDER_PATH"] else {
            throw XCTSkip("Set CLAUDE_RESET_LIVE_RENDER_PATH to verify the live Desktop cache and card")
        }
        let provider = ClaudeOAuthProvider(
            loadCredentials: { throw UsageProviderError.needsAuth }, cli: nil,
            desktopCache: ClaudeDesktopUsageCache()
        )
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertTrue(snapshot.hasAvailableResetCredits)
        let image = try renderClaudeResets(snapshot, now: Date())
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }

    private func renderClaudeResets(_ snapshot: ProviderSnapshot, now: Date) throws -> NSImage {
        let view = TooltipCard(snapshot: snapshot, now: now, direction: .trailing)
            .padding(20)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.notchSurfaceStyle, .solid)
            .environment(\.codenotchAccentColor, .blue)
            .environment(\.codenotchHeadlessGlass, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try XCTUnwrap(renderer.nsImage)
    }

    func testUsagePaceFitsTheExistingSummaryLine() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = LimitWindow(id: "weekly", label: "Weekly limit", usedFraction: 1,
                                 resetsAt: now.addingTimeInterval(604800), duration: 604800)
        let pace = try XCTUnwrap(window.usagePace(now: now))
        let summary = "\(window.summary) · \(pace.summary)"
        XCTAssertEqual(summary, "100% Used · 0% left · 100% deficit")
        let font = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 18))
        let width = (summary as NSString).size(withAttributes: [.font: font]).width
        XCTAssertLessThanOrEqual(width * 0.85, NotchLayout.cardTextWidth)
    }

    /// The deficit compares spent against elapsed — a question about what was
    /// spent, whichever end the meters draw from — so it reads the same in
    /// both modes, and the swapped line still fits the card.
    func testDeficitSurvivesTheRemainingMode() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = LimitWindow(id: "weekly", label: "Weekly limit", usedFraction: 1,
                                 resetsAt: now.addingTimeInterval(604800), duration: 604800)
        let pace = try XCTUnwrap(window.usagePace(now: now))
        XCTAssertEqual(pace.summary, "100% deficit")
        XCTAssertEqual("\(window.summary) · \(pace.summary)",
                       "100% Used · 0% left · 100% deficit")
        let remaining = "\(window.summary(showingRemaining: true)) · \(pace.summary)"
        XCTAssertEqual(remaining, "0% left · 100% Used · 100% deficit")
        let font = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 18))
        let width = (remaining as NSString).size(withAttributes: [.font: font]).width
        XCTAssertLessThanOrEqual(width * 0.85, NotchLayout.cardTextWidth)
    }

    /// The ring draws from either end without complaint — a smoke test, the
    /// way the card renders are: the sweep maths itself is pinned in
    /// `MeteredFractionTests`.
    func testRingRendersFromTheRemainingEnd() throws {
        let view = HStack(spacing: 20) {
            ProviderRing(usedFraction: 0.25, glyph: .claude)
            ProviderRing(usedFraction: 0.25, glyph: .claude, showsRemaining: true)
            ProviderRing(usedFraction: 1.28, glyph: .claude, showsRemaining: true)
        }
        .padding(20)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environment(\.notchSurfaceStyle, .solid)
        .environment(\.codenotchAccentColor, .blue)
        .environment(\.codenotchHeadlessGlass, true)
        let renderer = ImageRenderer(content: view)
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testTheCardLaysOutEverySessionState() throws {
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.47)]
        )
        let activity = ActivitySummary(sessions: [
            session("codenotch-6f", .idle, minutes: 0),
            session("hivinz-web-2f", .busy, minutes: 1),
            session("codenotch-18", .waiting, minutes: 3)
        ])

        let view = TooltipCard(snapshot: snapshot, activity: activity, now: Date())
            .padding(20)
            .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)

        // Three sessions of two lines each, under the window rows: a card that
        // silently collapsed would still render, just far too short.
        XCTAssertGreaterThan(image.size.height, NotchLayout.cardWidth * 0.5,
                             "the card laid out far shorter than three sessions need")
        XCTAssertGreaterThan(image.size.width, NotchLayout.cardWidth)

        if let path = ProcessInfo.processInfo.environment["TOOLTIP_RENDER_PATH"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    func testCodexCardRendersAccountActivity() throws {
        let usage = CodexTokenUsage(
            summary: .init(lifetimeTokens: 280_000, peakDailyTokens: 150_000,
                            longestRunningTurnSeconds: 4020,
                            currentStreakDays: 2, longestStreakDays: 11),
            dailyUsageBuckets: [
                .init(startDate: "2026-08-25", tokens: 48_000),
                .init(startDate: "2026-09-03", tokens: 192_000),
                .init(startDate: "2026-09-08", tokens: 40_000)
            ]
        )
        let snapshot = ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "primary", label: "5h limit", usedFraction: 0),
                LimitWindow(id: "secondary", label: "Weekly limit", usedFraction: 0.28)
            ],
            tokenUsage: usage
        )
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!
        let view = TooltipCard(snapshot: snapshot, now: now)
            .padding(20)
            .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(
            image.size.height,
            NotchLayout.cardHeight(windowCount: 2) + NotchLayout.codexChartHeight,
            "the account activity section was not included in the rendered card"
        )

        if let path = ProcessInfo.processInfo.environment["CODEX_TOOLTIP_RENDER_PATH"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The glass is masked by this one outline, so anything it fails to cover
    /// is a piece of the tooltip left unpainted.
    func testTheSilhouetteIsOneShapeCoveringCardAndTail() {
        for direction in [NotchEdge.TooltipDirection.leading, .trailing, .down, .up] {
            let horizontal = direction == .leading || direction == .trailing
            // The tail is long in the direction it points, whichever that is.
            let tailLength = NotchLayout.tailLength
            let rect = horizontal
                ? CGRect(x: 0, y: 0, width: NotchLayout.cardWidth + tailLength, height: 200)
                : CGRect(x: 0, y: 0, width: NotchLayout.cardWidth, height: 200 + tailLength)

            let path = TooltipSilhouette(direction: direction).path(in: rect)
            XCTAssertFalse(path.isEmpty, "\(direction) produced no outline at all")

            let bounds = path.boundingRect
            XCTAssertEqual(bounds.minX, rect.minX, accuracy: 0.5, "\(direction)")
            XCTAssertEqual(bounds.minY, rect.minY, accuracy: 0.5, "\(direction)")
            XCTAssertEqual(bounds.maxX, rect.maxX, accuracy: 0.5, "\(direction)")
            XCTAssertEqual(bounds.maxY, rect.maxY, accuracy: 0.5, "\(direction)")

            // The middle of the card, then a point just past the card's edge on
            // the tail's centre line: one shape has to hold both.
            let cardCentre: CGPoint
            let insideTail: CGPoint
            switch direction {
            case .leading:
                cardCentre = CGPoint(x: (rect.width - tailLength) / 2, y: rect.midY)
                insideTail = CGPoint(x: rect.width - tailLength + 1, y: rect.midY)
            case .trailing:
                cardCentre = CGPoint(x: tailLength + (rect.width - tailLength) / 2, y: rect.midY)
                insideTail = CGPoint(x: tailLength - 1, y: rect.midY)
            case .down:
                cardCentre = CGPoint(x: rect.midX, y: tailLength + (rect.height - tailLength) / 2)
                insideTail = CGPoint(x: rect.midX, y: tailLength - 1)
            case .up:
                cardCentre = CGPoint(x: rect.midX, y: (rect.height - tailLength) / 2)
                insideTail = CGPoint(x: rect.midX, y: rect.height - tailLength + 1)
            }

            XCTAssertTrue(path.contains(cardCentre), "\(direction) missed the card")
            XCTAssertTrue(path.contains(insideTail), "\(direction) missed the tail")
        }
    }

    /// The tail slides along the card to stay on the cell it points at, and the
    /// glass is masked by this outline — a silhouette that ignored the nudge
    /// would leave the tail unpainted where it actually is.
    func testTheSilhouetteFollowsTheTailsOffset() {
        for direction in [NotchEdge.TooltipDirection.leading, .trailing, .down, .up] {
            let horizontal = direction == .leading || direction == .trailing
            let tailLength = NotchLayout.tailLength
            let rect = horizontal
                ? CGRect(x: 0, y: 0, width: NotchLayout.cardWidth + tailLength, height: 200)
                : CGRect(x: 0, y: 0, width: NotchLayout.cardWidth, height: 200 + tailLength)
            // A whole tail's width, so the centre line the tail used to sit on
            // is now clear of it.
            let nudge = NotchLayout.tailHeight

            let path = TooltipSilhouette(direction: direction, tailOffset: nudge).path(in: rect)

            // Just past the card's edge on the unmoved centre line: a point only
            // the tail can ever cover.
            let wasOnCentre: CGPoint
            switch direction {
            case .leading:  wasOnCentre = CGPoint(x: rect.width - tailLength + 1, y: rect.midY)
            case .trailing: wasOnCentre = CGPoint(x: tailLength - 1, y: rect.midY)
            case .down:     wasOnCentre = CGPoint(x: rect.midX, y: tailLength - 1)
            case .up:       wasOnCentre = CGPoint(x: rect.midX, y: rect.height - tailLength + 1)
            }
            // The offset runs along the card: across the tail's own direction.
            let nowOnCentre = horizontal
                ? CGPoint(x: wasOnCentre.x, y: wasOnCentre.y + nudge)
                : CGPoint(x: wasOnCentre.x + nudge, y: wasOnCentre.y)

            XCTAssertTrue(path.contains(nowOnCentre),
                          "\(direction): the outline did not follow the tail's offset")
            XCTAssertFalse(path.contains(wasOnCentre),
                           "\(direction): the outline left a tail behind where the tail no longer is")
        }
    }
}

/// The pace tick on the card's bars: a white mark where the fill *should* be,
/// a quarter along in used mode for a window a quarter through its cycle,
/// mirrored to three-quarters when the bar reads remaining — and drawn only
/// while the deficit option is on.
@MainActor
final class PaceMarkerRenderTests: XCTestCase {
    private let scale: CGFloat = 2

    private func snapshot(now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "pace", displayName: "Pace", glyph: .amp, fidelity: .official,
            status: .ok,
            windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.8,
                                  resetsAt: now.addingTimeInterval(2700), duration: 3600)],
            headlineID: "w", plan: nil
        )
    }

    private func render(snapshot: ProviderSnapshot, now: Date) throws -> NSBitmapImageRep {
        let view = TooltipCard(snapshot: snapshot, now: now, direction: .down)
            .padding(20)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.notchSurfaceStyle, .solid)
            .environment(\.codenotchAccentColor, .blue)
            .environment(\.colorTransitionStyle, .hardStep)
            .environment(\.codenotchHeadlessGlass, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// Device pixels from the card's own metrics, so the probe follows the
    /// layout rather than pinning a number the frame owns.
    private func markerColumn(fraction: CGFloat) -> Int {
        let track = NotchLayout.cardWidth - 2 * NotchLayout.cardPadding
        return Int(((20 + NotchLayout.cardPadding + track * fraction) * scale).rounded())
    }

    private func isMarkerWhite(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5
            && color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9
    }

    /// The critical band's fixed orange — 0.8 used sits above the critical
    /// limit whatever the accent is.
    private func isCriticalOrange(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5
            && color.redComponent > 0.85
            && color.greenComponent > 0.15 && color.greenComponent < 0.45
            && color.blueComponent < 0.2
    }

    /// The bare track: white at 17.6% over the black card.
    private func isBarTrack(_ color: NSColor) -> Bool {
        guard color.alphaComponent > 0.5 else { return false }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        return channels.allSatisfy { $0 > 0.08 && $0 < 0.32 }
            && channels.max()! - channels.min()! < 0.06
    }

    /// A white pixel with the expected bar colour 12pt either side — title and
    /// percentage text are white too, but nothing orange or track-grey sits
    /// beside them, so only the tick matches.
    private func markerPresent(in pixels: NSBitmapImageRep, column: Int,
                               neighbor: (NSColor) -> Bool) -> Bool {
        let reach = Int((12 * scale).rounded())
        for y in 0..<pixels.pixelsHigh {
            for x in (column - 1)...(column + 1) {
                guard let center = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let left = pixels.colorAt(x: x - reach, y: y)?.usingColorSpace(.sRGB),
                      let right = pixels.colorAt(x: x + reach, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                if isMarkerWhite(center) && neighbor(left) && neighbor(right) { return true }
            }
        }
        return false
    }

    func testPaceMarkerMarksExpectedBurnInBothModes() throws {
        let paceKey = Preferences.showUsagePaceKey
        let remainingKey = Preferences.showsRemainingInNotchKey
        let savedPace = UserDefaults.standard.object(forKey: paceKey)
        let savedRemaining = UserDefaults.standard.object(forKey: remainingKey)
        defer {
            if let savedPace { UserDefaults.standard.set(savedPace, forKey: paceKey) }
            else { UserDefaults.standard.removeObject(forKey: paceKey) }
            if let savedRemaining { UserDefaults.standard.set(savedRemaining, forKey: remainingKey) }
            else { UserDefaults.standard.removeObject(forKey: remainingKey) }
        }
        UserDefaults.standard.set(true, forKey: paceKey)

        let now = Date()
        let card = snapshot(now: now)

        // A quarter through the cycle: the tick sits a quarter along the bar,
        // on the orange fill.
        UserDefaults.standard.set(false, forKey: remainingKey)
        let used = try render(snapshot: card, now: now)
        XCTAssertTrue(markerPresent(in: used, column: markerColumn(fraction: 0.25),
                                    neighbor: isCriticalOrange),
                      "used mode: no pace tick a quarter along the bar")

        // The same moment reads as three-quarters expected left — the tick
        // mirrors with the bar, onto the bare track past the short fill.
        UserDefaults.standard.set(true, forKey: remainingKey)
        let remaining = try render(snapshot: card, now: now)
        XCTAssertTrue(markerPresent(in: remaining, column: markerColumn(fraction: 0.75),
                                    neighbor: isBarTrack),
                      "remaining mode: no pace tick three-quarters along the bar")

        // The tick belongs to the deficit option: off, the bar carries none.
        UserDefaults.standard.set(false, forKey: paceKey)
        UserDefaults.standard.set(false, forKey: remainingKey)
        let off = try render(snapshot: card, now: now)
        XCTAssertFalse(markerPresent(in: off, column: markerColumn(fraction: 0.25),
                                     neighbor: isCriticalOrange),
                       "pace off: the bar carries a tick it should not")
    }
}
