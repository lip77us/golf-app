// swift-tools-version: 5.9
// The Swift Package Manager manifest Flutter looks for at
// ios/<plugin_name>/Package.swift. Its presence is the entire reason this
// plugin exists in place of flutter_sms: with it, the iOS build needs no
// CocoaPods at all.
import PackageDescription

let package = Package(
    name: "halved_sms",
    platforms: [
        // Match the app (ios/Podfile and IPHONEOS_DEPLOYMENT_TARGET both say
        // 15.0, set by Firebase). Declaring anything lower buys nothing — the
        // app cannot install there — and costs @available guards around the
        // scene APIs used to find the presenting view controller.
        .iOS("15.0")
    ],
    products: [
        .library(name: "halved-sms", targets: ["halved_sms"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "halved_sms",
            dependencies: [],
            resources: []
        )
    ]
)
