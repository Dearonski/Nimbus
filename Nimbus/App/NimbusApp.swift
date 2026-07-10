//
//  NimbusApp.swift
//  Nimbus
//
//  Created by Кирилл on 09.07.2026.
//

import SwiftUI

@main
struct NimbusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
