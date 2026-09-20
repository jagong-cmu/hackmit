import SwiftUI

/// The four "point the glasses at something" features behind one tab, so the
/// tab bar stays at five items or fewer (iOS folds anything past that into a
/// "More" list, which is where the caregiver's Setup tab was ending up).
/// Every one of these is also reachable by voice; the screens are the
/// Simulator and debugging surface.
struct CameraFeaturesView: View {
    let glasses: GlassesSession
    let calendar: CalendarService
    @ObservedObject var foodLabel: FoodLabelViewModel

    var body: some View {
        List {
            Section {
                NavigationLink {
                    FoodLabelView(viewModel: foodLabel)
                } label: {
                    row("Check Food", "Read a food label and check it against the diet", "carrot")
                }
                NavigationLink {
                    ReadToMeView(glasses: glasses)
                } label: {
                    row("Read To Me", "Read mail, labels or a menu aloud", "text.viewfinder")
                }
                NavigationLink {
                    AppointmentCardScanView(glasses: glasses, calendar: calendar)
                } label: {
                    row("Scan Card", "Put an appointment card on the calendar", "doc.text.viewfinder")
                }
                NavigationLink {
                    AdScamCheckView(glasses: glasses)
                } label: {
                    row("Check Ad", "Screen an advertisement for scam signals", "exclamationmark.shield")
                }
            } footer: {
                Text("Each of these also works by voice: “Hey Dojo, can I eat this?”, “read this to me”, “scan this”, “check this ad”.")
            }
        }
        .navigationTitle("Camera")
    }

    private func row(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }
}
