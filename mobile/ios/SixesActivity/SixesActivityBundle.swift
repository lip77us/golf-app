//
//  SixesActivityBundle.swift
//  SixesActivity
//
//  Only the Live Activity ships. Xcode's template also generates a home-screen
//  widget and an iOS 18 Control Center control; neither is part of the Sixes
//  lock screen (docs/design-review/handoff-sixes-lock/SPEC.md), and the control
//  will not compile below iOS 18.
//

import WidgetKit
import SwiftUI

@main
struct SixesActivityBundle: WidgetBundle {
    var body: some Widget {
        SixesActivityLiveActivity()
    }
}
