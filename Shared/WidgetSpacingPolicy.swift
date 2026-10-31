import Foundation

/// Insets are fixed by family and actual visible card count, never by content pressure.
struct WidgetSpacingPolicy {
    let size: ProviderWidgetSize
    let cardCount: Int

    init(size: ProviderWidgetSize, cardCount: Int) {
        self.size = size
        self.cardCount = min(max(1, cardCount), WidgetComposition.capacity(for: size))
    }

    var outerPadding: CGFloat {
        switch size {
        case .small: 10
        case .medium: 12
        case .large, .extraLarge: 16
        }
    }

    var cardSpacing: CGFloat {
        switch size {
        case .small: 4
        case .medium: 6
        case .large, .extraLarge: 8
        }
    }

    var horizontalPadding: CGFloat {
        switch size {
        case .small: cardCount == 1 ? 12 : 8
        case .medium: cardCount == 1 ? 12 : cardCount <= 3 ? 10 : 8
        case .large: cardCount == 1 ? 16 : cardCount <= 3 ? 12 : 10
        case .extraLarge: cardCount == 1 ? 16 : 12
        }
    }

    var verticalPadding: CGFloat {
        switch size {
        case .small: cardCount == 1 ? 10 : 8
        case .medium: cardCount <= 3 ? 10 : 8
        case .large: cardCount == 1 ? 12 : cardCount <= 3 ? 10 : 8
        case .extraLarge: cardCount == 1 ? 14 : cardCount <= 4 ? 12 : 10
        }
    }
}
