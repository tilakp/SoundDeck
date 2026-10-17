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

/// The two appearances that the deck supports.
private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

/// Resolves a colour in an appearance. An adaptive token gives a different value in each appearance.
private func resolved(_ color: Color, in appearance: NSAppearance.Name) throws -> NSColor {
    let drawing = try #require(NSAppearance(named: appearance))
    var result: NSColor?
    drawing.performAsCurrentDrawingAppearance {
        result = NSColor(color).usingColorSpace(.sRGB)
    }
    return try #require(result)
}

/// Gives the contrast ratio of a translucent text colour on an opaque background.
private func contrast(of text: Color, on background: Color, in appearance: NSAppearance.Name) throws -> CGFloat {
    let foreground = try resolved(text, in: appearance)
    let back = try resolved(background, in: appearance)
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

private let surfaces = [Theme.backdropTop, Theme.backdropBottom, Theme.surface, Theme.surfaceRaised, Theme.surfaceHover]

/// The tints, the accent and the danger colour. The views also use them as text colours.
private let tints = SoundTint.allCases.map(\.color) + [Theme.accent, Theme.accentBright, Theme.danger]

@Test(arguments: appearances)
func textPassesSmallTextContrast(appearance: NSAppearance.Name) throws {
    for text in [Theme.textPrimary, Theme.textSecondary, Theme.textTertiary] {
        for surface in surfaces {
            #expect(try contrast(of: text, on: surface, in: appearance) >= 4.5)
        }
    }
}

@Test(arguments: appearances)
func tintTextPassesSmallTextContrast(appearance: NSAppearance.Name) throws {
    for tint in tints {
        for surface in surfaces {
            #expect(try contrast(of: tint, on: surface, in: appearance) >= 4.5)
        }
    }
}

/// The Stop controls and the error badge put `backdropBottom` text on a tint fill.
@Test(arguments: appearances)
func backdropTextOnTintPassesContrast(appearance: NSAppearance.Name) throws {
    for tint in tints {
        #expect(try contrast(of: Theme.backdropBottom, on: tint, in: appearance) >= 4.5)
    }
}

/// The Add, Go and Stop All controls put white text on the accent or the danger colour.
/// The dark values give 2.6:1 to 3.1:1. This task did not change the dark design.
@Test func whiteTextOnLightAccentPassesContrast() throws {
    for fill in [Theme.accent, Theme.danger] {
        #expect(try contrast(of: .white, on: fill, in: .aqua) >= 4.5)
    }
}

@Test func tokensFollowTheAppearance() throws {
    let light = try resolved(Theme.surface, in: .aqua)
    let dark = try resolved(Theme.surface, in: .darkAqua)
    #expect(light.brightnessComponent > 0.9)
    #expect(dark.brightnessComponent < 0.2)

    // The floating panel uses the AppKit value directly.
    var panelLight: NSColor?
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
        panelLight = Theme.surfaceColor.usingColorSpace(.sRGB)
    }
    #expect(try #require(panelLight).brightnessComponent > 0.9)
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
