import AppKit
import SwiftUI

/// One provider's limits, as the menu bar's menu draws them.
///
/// The card is `ProviderLimitsContent` — the same view the notch's tooltip
/// starts from, given the same snapshot from the same model — on a plain
/// rounded surface. Nothing about a provider is worked out here; this file is
/// the container and only the container.
///
/// The notch's own silhouette is deliberately left behind: the tail, the glass
/// and the circular corner cut are drawn for a screen bezel and mean nothing in
/// a menu. The padding, the corner radius and the ink are the notch's, so the
/// card still reads as the same app.
struct MenuUsageCard: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    let now: Date
    var resetTimeFormat: ResetTimeFormat = .automatic
    var deepSeekPricingEnabled: Bool = true
    var deepSeekPricingSchedule: DeepSeekPricing.Schedule = .current
    var sessionCap: Int = NotchLayout.defaultSessionCap
    /// Whether this card is opened out. Closed it is the limits; open it is
    /// everything the notch's tooltip carries, and the card grows downward to
    /// hold it.
    var isExpanded: Bool = false
    /// Nil leaves the header without a switch, which is how a card renders
    /// outside a menu.
    var onToggle: (() -> Void)?
    /// Where the switch ended up, in this card's own coordinates.
    ///
    /// Reported rather than worked out, so the geometry lives in one place:
    /// the switch sits on the title's line whether or not a tier is named
    /// under it. The menu item hit-tests against this — see
    /// `MenuCardHostingView`.
    var onSwitchFrame: ((CGRect) -> Void)?
    /// Read here rather than passed in, the way `ProviderDetailContent` reads
    /// it: one preference, one reader, and the menu follows a change to it
    /// without anything having to carry the value down.
    @AppStorage(Preferences.showUsagePaceKey) private var showUsagePace = false

    /// How wide the card is drawn, and the column its bars get inside it.
    ///
    /// A menu item sizes itself from the view it is given, so the width is
    /// settled here rather than measured from a container. In design pixels
    /// like everything else, so the card tracks `Design.scale`.
    static let width = Design.px(900)
    static var contentWidth: CGFloat { width - 2 * NotchLayout.cardPadding }
    /// Between cards, and around the stack of them.
    static let gutter = Design.px(24)

    var body: some View {
        ProviderDetailContent(snapshot: snapshot, activity: activity, now: now,
                              sessionCap: sessionCap,
                              resetTimeFormat: resetTimeFormat,
                              deepSeekPricingEnabled: deepSeekPricingEnabled,
                              deepSeekPricingSchedule: deepSeekPricingSchedule,
                              showsExtendedDetail: isExpanded,
                              headerAccessory: onToggle.map { AnyView(detailSwitch(onToggle: $0)) })
            .environment(\.providerDetailWidth, Self.contentWidth)
            // Always the height the content asks for, never what the item
            // happens to offer. Offered less — the frame AppKit still holds
            // from before a switch, say — SwiftUI squeezes whatever gives, and
            // the one thing that gives is a usage line's `minimumScaleFactor`,
            // so one "% Used · % left" came out smaller than the one under it.
            .fixedSize(horizontal: false, vertical: true)
            .padding(NotchLayout.cardPadding)
            .frame(width: Self.width, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.hairline / 2)
            )
            .padding(.horizontal, Self.gutter)
            .padding(.vertical, Self.gutter / 2)
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(SwitchFramePreference.self) { frame in
                if let frame { onSwitchFrame?(frame) }
            }
    }

    private static let space = "menuUsageCard"

    /// The card's own switch, beside the provider it belongs to.
    ///
    /// Closed, the card is what the limits say; open, it is everything the
    /// notch's tooltip carries for that provider, and the card grows
    /// downward to hold it.
    private func detailSwitch(onToggle: @escaping () -> Void) -> some View {
        Toggle(L10n.t("Detail"), isOn: Binding(get: { isExpanded }, set: { _ in onToggle() }))
            .toggleStyle(DetailSwitchStyle())
            .fixedSize()
            .accessibilityLabel(L10n.t("\(snapshot.displayName) detail"))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SwitchFramePreference.self,
                                           value: proxy.frame(in: .named(Self.space)))
                }
            }
    }
}

/// Where the card's switch is, carried up to the card so the menu item can be
/// told. Optional so a card drawn without a switch reports nothing at all.
private struct SwitchFramePreference: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// The card's switch, drawn rather than borrowed.
///
/// `NSSwitch` — what `.toggleStyle(.switch)` bridges in — is an AppKit control
/// living inside a card whose every distance is measured off the design frame,
/// and it brings its own metrics, its own tint and its own idea of a control
/// size. Worse for anyone working on this: it does not rasterize, so the card
/// cannot be rendered and looked at offscreen the way the rest of the surface
/// can, and a change to it can only be checked by running the app.
///
/// This is the same shape in the app's own terms: a capsule that takes the
/// accent when it is on, sized in design pixels beside the body text it sits
/// with.
struct DetailSwitchStyle: ToggleStyle {
    @Environment(\.codenotchAccentColor) private var accentColor
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Measured against the body text's cap height, like the status dot beside
    /// a session's word — so it reads as part of the line rather than a control
    /// pinned near it.
    private static let height = Design.px(38)
    private static let width = Design.px(66)
    private static let inset = Design.px(4)

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NotchLayout.statusDotGap) {
            configuration.label
                .font(Typography.cardBody)
                .foregroundStyle(secondaryInk)
                .lineLimit(1)
            track(isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// Only the colour and the knob move. The animation is scoped to those two
    /// rather than hung on the whole track with `.animation(_:value:)`, which
    /// animates the track's *position* too: the card re-lays out in the same
    /// update that flips the switch — it has just grown or shrunk — and the
    /// track slid in from wherever that layout passed through while the words
    /// beside it stood still.
    private func track(isOn: Bool) -> some View {
        let motion = reduceMotion ? nil : NotchMotion.glide
        // Off is deliberately heavier than `Palette.barTrack`: the knob is
        // white in both appearances, and a track as faint as a usage bar's
        // would leave it floating on a light card with nothing under it.
        return Capsule()
            .fill(secondaryInk.opacity(0.35))
            .overlay {
                Capsule()
                    .fill(accentColor)
                    .animation(motion) { $0.opacity(isOn ? 1 : 0) }
            }
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .padding(Self.inset)
                    .frame(width: Self.height, height: Self.height)
                    .animation(motion) { $0.offset(x: isOn ? Self.width - Self.height : 0) }
            }
            .frame(width: Self.width, height: Self.height)
    }
}

/// The card, wrapped for an `NSMenuItem`.
///
/// A menu item with a view of its own is the only way AppKit lets anything but
/// a line of text into a menu, and the view has to arrive already sized: the
/// item takes the frame it is given and the menu is as wide as its widest item.
/// So the hosting view is measured once, here, from what SwiftUI says the card
/// needs at `MenuUsageCard.width`.
///
/// It also must not behave like a command. A menu item highlights under the
/// pointer and closes the menu when clicked; this one is a reading, so it
/// swallows the click and never draws a highlight.
@MainActor
enum MenuUsageCardItem {
    /// The card with its environment on it, type-erased so a hosting view can
    /// be handed a new one without changing type.
    ///
    /// The three environment values are the ones the notch root also sets,
    /// taken from the same model, so a percentage is coloured by one rule and
    /// a reset worded by one setting whichever surface is being read.
    static func root(snapshot: ProviderSnapshot, activity: ActivitySummary?, now: Date,
                     resetTimeFormat: ResetTimeFormat,
                     deepSeekPricingEnabled: Bool,
                     deepSeekPricingSchedule: DeepSeekPricing.Schedule,
                     sessionCap: Int,
                     accentColor: Color,
                     watchLimit: Double,
                     criticalLimit: Double,
                     isExpanded: Bool,
                     onToggle: (() -> Void)?,
                     onSwitchFrame: ((CGRect) -> Void)? = nil) -> AnyView {
        AnyView(
            MenuUsageCard(snapshot: snapshot, activity: activity, now: now,
                          resetTimeFormat: resetTimeFormat,
                          deepSeekPricingEnabled: deepSeekPricingEnabled,
                          deepSeekPricingSchedule: deepSeekPricingSchedule,
                          sessionCap: sessionCap,
                          isExpanded: isExpanded,
                          onToggle: onToggle,
                          onSwitchFrame: onSwitchFrame)
                .environment(\.codenotchAccentColor, accentColor)
                .environment(\.usageWatchLimit, watchLimit)
                .environment(\.usageCriticalLimit, criticalLimit)
                .tint(accentColor)
                // Pinned to the top of the item, and never taller than it.
                //
                // A hosting view's frame is its fitting size rounded up to
                // whole points, and SwiftUI centres content in whatever is
                // left over — a different fraction for a closed card than for
                // an open one, so the header, and the switch in it, moved when
                // it was flipped.
                //
                // The minimums matter as much as the alignment. A new card is
                // laid out once in the item's old frame before the item is
                // re-measured; with only a maximum, a card taller than that
                // frame keeps its own height and is centred on it, which puts
                // the header half the difference above where it belongs. With
                // both bounds the frame is always the item's, and whatever
                // does not fit yet hangs off the bottom until the item grows.
                .frame(minWidth: 0, maxWidth: .infinity,
                       minHeight: 0, maxHeight: .infinity, alignment: .top)
        )
    }

    /// Give a hosting view the height SwiftUI says its card needs, at the
    /// card's fixed width. The width is the menu's; only the height moves, and
    /// it moves whenever a card is opened or closed.
    static func resize(_ hosting: NSView) {
        let width = MenuUsageCard.width + 2 * MenuUsageCard.gutter
        hosting.frame = NSRect(origin: hosting.frame.origin,
                               size: NSSize(width: width, height: hosting.fittingSize.height))
    }

    /// `root` is handed the setter for this item's own hosting view, so the
    /// card can report where its switch landed to the very view that will
    /// hit-test the click.
    static func make(title: String, appearance: NSAppearance?,
                     onToggle: (() -> Void)?,
                     root: (_ onSwitchFrame: @escaping (CGRect) -> Void) -> AnyView) -> NSMenuItem {
        let hosting = MenuCardHostingView(rootView: AnyView(EmptyView()))
        hosting.onInteract = onToggle
        hosting.rootView = root { [weak hosting] frame in hosting?.interactiveRect = frame }
        // Set before the card is measured: the appearance decides the ink and
        // the surface, and a card measured in one and drawn in the other can
        // come out the wrong height.
        hosting.appearance = appearance
        resize(hosting)

        let item = NSMenuItem()
        item.view = hosting
        // Not drawn — the view is — but it is what AppKit hands to
        // accessibility and to anything that searches a menu, so it says what
        // the card says rather than nothing at all.
        item.title = title
        return item
    }
}

/// Never highlighted, never clicked through, and always in the menu's own
/// appearance.
///
/// Two things AppKit does not give a hosted view for free.
///
/// A menu item with a view is still a command as far as AppKit is concerned:
/// the row lights up under the pointer and the menu closes on mouse-up. A card
/// is mostly something to read, so the mouse stops here — except over the
/// card's own switch, which is the one thing on it to operate. A click there
/// is handed to SwiftUI and the menu deliberately stays open, because opening
/// a card and then losing the menu it is in would be no use at all.
///
/// And the appearance it draws in has to be told to it. A hosting view built
/// before it is installed in a menu resolves its colours against nothing in
/// particular, so the card is handed the Mac's own appearance — the one the
/// menu items beside it follow. See `StatusItemController.menuAppearance`.
final class MenuCardHostingView<Content: View>: NSHostingView<Content> {
    /// Where the card's switch is, in this view's own coordinates. Set by the
    /// card as it lays out, so nothing here has to guess at the geometry.
    var interactiveRect: CGRect = .zero
    /// What to do when the switch is clicked. The hit test is done here rather
    /// than left to SwiftUI because a menu runs its own event-tracking loop,
    /// and a hosted control cannot be relied on to see a click inside it.
    var onInteract: (() -> Void)?

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard interactiveRect.contains(point) else { return }
        onInteract?()
    }

    override var allowsVibrancy: Bool { false }
}
