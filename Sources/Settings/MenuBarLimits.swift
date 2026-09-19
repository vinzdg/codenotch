import Foundation

/// What the menu bar item shows in place of its icon: nothing — the icon, as
/// it has always been — or the five-hour limits of the providers chosen for it.
///
/// Presentation only, and kept apart from `Preferences.connectedProviders` on
/// purpose. That list decides what Codenotch *reads*; this one decides what the
/// menu bar *shows* of it. A provider can be read and kept out of the bar, and
/// taking it out never stops the reading — the notch, the menu, the alerts and
/// the phone all carry on. The other way round there is nothing to show: a
/// provider that is not read has no limit to put here, and choosing it here
/// starts no reading.
struct MenuBarLimits: Equatable {
    /// Off, the item is the app's own icon, whatever the readings say.
    var isOn: Bool
    /// The providers chosen for the bar, as ids.
    ///
    /// Nil until someone chooses, which reads as Claude and Codex: their
    /// headline limit *is* the five-hour window, so they are what the bar is
    /// for. Empty is a choice rather than an absence, and gives the bar its
    /// icon back.
    var chosen: Set<String>?

    static let off = MenuBarLimits(isOn: false, chosen: nil)

    /// Whether this provider is among the chosen. Answered with the feature
    /// off as well, so switching it off and on again keeps what was chosen.
    func isChosen(_ providerID: String) -> Bool {
        chosen?.contains(providerID) ?? StatusItemSummary.isFiveHourFamily(providerID)
    }

    /// The same choice with one provider put in or taken out.
    ///
    /// `listed` is every provider Settings has on screen. The first choice
    /// anyone makes writes all of them down as they were showing, so the
    /// default stops being a rule and becomes the list that was ticked — and a
    /// profile that turns up later is never added to the bar behind anyone's
    /// back.
    func choosing(_ isChosen: Bool, _ providerID: String, among listed: [String]) -> MenuBarLimits {
        var chosen = self.chosen ?? Set(listed.filter(self.isChosen))
        if isChosen {
            chosen.insert(providerID)
        } else {
            chosen.remove(providerID)
        }
        return MenuBarLimits(isOn: isOn, chosen: chosen)
    }
}
