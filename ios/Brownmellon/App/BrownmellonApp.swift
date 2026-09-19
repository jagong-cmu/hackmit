import SwiftUI

@main
struct BrownmellonApp: App {
    // Workstream B scaffold root. Wires the mock GlassesSession/CalendarService
    // for now — see Core/Mocks. Swap these for the real implementations once
    // the shared foundation lands (PRD.md § Foundation).
    // Plain properties, not @StateObject: these are session/service
    // objects, not view state — the ViewModels are the ObservableObjects.
    private let glasses = MockGlassesSession()
    private let calendarService = MockCalendarService()

    var body: some Scene {
        WindowGroup {
            TabView {
                AppointmentCardScanView(glasses: glasses, calendar: calendarService)
                    .tabItem { Label("Scan Card", systemImage: "doc.text.viewfinder") }

                ReadToMeView(glasses: glasses)
                    .tabItem { Label("Read To Me", systemImage: "text.viewfinder") }
            }
        }
    }
}
