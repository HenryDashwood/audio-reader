import AppIntents
import SwiftUI
import WidgetKit

@main
struct HearfulControls: WidgetBundle {
    var body: some Widget {
        AskMagpieControl()
        ContinueMagpieControl()
    }
}

struct AskMagpieControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.henrydashwood.hearful.ask") {
            ControlWidgetButton(action: OpenMagpieMicrophoneControlIntent()) {
                Label("Ask Magpie", systemImage: "mic.fill")
            }
        }
        .displayName("Ask Magpie")
        .description("Open Magpie ready for a spoken request.")
    }
}

struct ContinueMagpieControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.henrydashwood.hearful.continue") {
            ControlWidgetButton(action: ContinueMagpieControlIntent()) {
                Label("Continue Listening", systemImage: "play.fill")
            }
        }
        .displayName("Continue Listening")
        .description("Open Magpie and resume your last podcast or article.")
    }
}
