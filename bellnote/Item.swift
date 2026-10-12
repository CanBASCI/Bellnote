//
//  Item.swift
//  bellnote
//
//  Created by Can Basci on 13.10.2026.
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
