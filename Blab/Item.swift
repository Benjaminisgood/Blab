//
//  Item.swift
//  Blab
//
//  Created by ben on 2026/2/22.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
