//
//  SixesActivityLiveActivity.swift
//  SixesActivity
//
//  Created by Paul Lipkin on 8/24/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct SixesActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct SixesActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SixesActivityAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension SixesActivityAttributes {
    fileprivate static var preview: SixesActivityAttributes {
        SixesActivityAttributes(name: "World")
    }
}

extension SixesActivityAttributes.ContentState {
    fileprivate static var smiley: SixesActivityAttributes.ContentState {
        SixesActivityAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: SixesActivityAttributes.ContentState {
         SixesActivityAttributes.ContentState(emoji: "🤩")
     }
}
