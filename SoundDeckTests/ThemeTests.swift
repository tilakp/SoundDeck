import AppKit
import SwiftUI
import Testing
@testable import SoundDeck

/// Gives the WCAG relative luminance of an sRGB colour.
private func luminance(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat {
    func linear(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
}

/// Gives the contrast ratio of a translucent text colour on an opaque background.
private func contrast(of text: Color, on background: Color) throws -> CGFloat {
    let foreground = try #require(NSColor(text).usingColorSpace(.sRGB))
    let back = try #require(NSColor(background).usingColorSpace(.sRGB))
    let alpha = foreground.alphaComponent
    func blend(_ front: CGFloat, _ rear: CGFloat) -> CGFloat { alpha * front + (1 - alpha) * rear }
    let textLuminance = luminance(
        blend(foreground.redComponent, back.redComponent),
        blend(foreground.greenComponent, back.greenComponent),
        blend(foreground.blueComponent, back.blueComponent)
    )
    let backLuminance = luminance(back.redComponent, back.greenComponent, back.blueComponent)
    return (max(textLuminance, backLuminance) + 0.05) / (min(textLuminance, backLuminance) + 0.05)
}

@Test func tertiaryTextPassesSmallTextContrast() throws {
    let surfaces = [Theme.backdropTop, Theme.surface, Theme.surfaceRaised, Theme.surfaceHover]
    for surface in surfaces {
        #expect(try contrast(of: Theme.textTertiary, on: surface) >= 4.5)
    }
}

@Test func scalesIncrease() {
    let type = [Theme.Font.captionSize, Theme.Font.bodySize, Theme.Font.titleSize, Theme.Font.numeralSize]
    let radii = [Theme.Radius.small, Theme.Radius.control, Theme.Radius.container]
    let spacing = [Theme.Spacing.xs, Theme.Spacing.s, Theme.Spacing.m, Theme.Spacing.l, Theme.Spacing.xl]
    #expect(type == type.sorted())
    #expect(radii == radii.sorted())
    #expect(spacing == spacing.sorted())
    #expect(Theme.tileRadius == Theme.Radius.container)
    #expect(Theme.tileSpacing == Theme.Spacing.s)
}
