import SwiftUI

extension AppTypeface {
    /// Width of SF Pro. Nil leaves the system width, including for a named face.
    var width: Font.Width? {
        switch self {
        case .sfProCondensed: .condensed
        case .sfProCompressed: .compressed
        case .sfProExpanded: .expanded
        default: nil
        }
    }

    /// A text style in this face. SF Pro keeps the system style so Dynamic Type and width still apply.
    func font(style: Font.TextStyle, weight: Font.Weight?, digits: Bool) -> Font {
        let chosen = weight ?? (style == .headline ? Font.Weight.semibold : Font.Weight.regular)
        var font: Font
        if self == .newYork {
            font = Font.system(style, design: .serif, weight: chosen)
        } else if usesSystemFace {
            font = systemFont(style, weight: weight)
        } else if let name = installedName(for: chosen), UIFont(name: name, size: 17) != nil {
            font = Font.custom(name, size: baseSize(style), relativeTo: style)
        } else {
            font = systemFont(style, weight: weight)
        }
        if digits {
            font = font.monospacedDigit()
        }
        return font
    }

    /// A point size that is already scaled, such as a ScaledMetric.
    func font(size: CGFloat, weight: Font.Weight, digits: Bool = false) -> Font {
        var font: Font
        if self == .newYork {
            font = Font.system(size: size, weight: weight, design: .serif)
        } else if usesSystemFace {
            // Nil design keeps the width chosen in Settings. The old overload locks SF Pro at its standard width.
            font = Font.system(size: size, weight: weight, design: nil)
        } else if let name = installedName(for: weight), UIFont(name: name, size: size) != nil {
            font = Font.custom(name, fixedSize: size)
        } else {
            font = Font.system(size: size, weight: weight, design: nil)
        }
        if digits {
            font = font.monospacedDigit()
        }
        return font
    }

    private var usesSystemFace: Bool {
        switch self {
        case .sfPro, .sfProCondensed, .sfProCompressed, .sfProExpanded: true
        default: false
        }
    }

    private func systemFont(_ style: Font.TextStyle, weight: Font.Weight?) -> Font {
        var font: Font
        switch style {
        case .largeTitle: font = .largeTitle
        case .title: font = .title
        case .title2: font = .title2
        case .title3: font = .title3
        case .headline: font = .headline
        case .body: font = .body
        case .callout: font = .callout
        case .subheadline: font = .subheadline
        case .footnote: font = .footnote
        case .caption: font = .caption
        case .caption2: font = .caption2
        default: font = .body
        }
        if let weight {
            font = font.weight(weight)
        }
        return font
    }

    /// Point size of the style at the default text size. `relativeTo` scales it from here.
    private func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }

    /// PostScript name of an installed face, or nil when this choice is a system face.
    private func installedName(for weight: Font.Weight) -> String? {
        switch self {
        case .sfPro, .sfProCondensed, .sfProCompressed, .sfProExpanded:
            nil
        case .sfCompact:
            compactName(weight)
        case .avenirNext:
            switch bucket(weight) {
            case .ultraLight, .thin, .light: "AvenirNext-UltraLight"
            case .regular: "AvenirNext-Regular"
            case .medium: "AvenirNext-Medium"
            case .semibold: "AvenirNext-DemiBold"
            case .bold: "AvenirNext-Bold"
            case .heavy: "AvenirNext-Heavy"
            }
        case .helveticaNeue:
            switch bucket(weight) {
            case .ultraLight: "HelveticaNeue-UltraLight"
            case .thin: "HelveticaNeue-Thin"
            case .light: "HelveticaNeue-Light"
            case .regular: "HelveticaNeue"
            case .medium, .semibold: "HelveticaNeue-Medium"
            case .bold, .heavy: "HelveticaNeue-Bold"
            }
        case .seravek:
            switch bucket(weight) {
            case .ultraLight, .thin: "Seravek-ExtraLight"
            case .light: "Seravek-Light"
            case .regular: "Seravek"
            case .medium, .semibold: "Seravek-Medium"
            case .bold, .heavy: "Seravek-Bold"
            }
        case .galvji:
            switch bucket(weight) {
            case .ultraLight, .thin, .light, .regular, .medium: "Galvji"
            case .semibold, .bold, .heavy: "Galvji-Bold"
            }
        case .futura:
            switch bucket(weight) {
            case .ultraLight, .thin, .light, .regular, .medium: "Futura-Medium"
            case .semibold, .bold, .heavy: "Futura-Bold"
            }
        case .dinAlternate:
            "DINAlternate-Bold"
        case .newYork:
            nil
        case .avenir, .avenirNextCondensed, .helvetica, .arial, .verdana, .trebuchet, .carlito,
             .timesNewRoman, .georgia, .palatino, .charter, .baskerville, .hoeflerText, .iowanOldStyle,
             .athelas, .bodoni, .superclarendon, .americanTypewriter, .rockwell, .menlo, .courierNew:
            readingCuts?.name(for: bucket(weight))
        }
    }

    /// Installed cuts for the Latin reading faces. Missing weights fall back to the nearest cut.
    private var readingCuts: FaceCuts? {
        switch self {
        case .avenir:
            FaceCuts(light: "Avenir-Light", regular: "Avenir-Roman", medium: "Avenir-Medium", bold: "Avenir-Heavy", heavy: "Avenir-Black")
        case .avenirNextCondensed:
            FaceCuts(light: "AvenirNextCondensed-UltraLight", regular: "AvenirNextCondensed-Regular", medium: "AvenirNextCondensed-Medium", semibold: "AvenirNextCondensed-DemiBold", bold: "AvenirNextCondensed-Bold", heavy: "AvenirNextCondensed-Heavy")
        case .helvetica:
            FaceCuts(light: "Helvetica-Light", regular: "Helvetica", bold: "Helvetica-Bold")
        case .arial:
            FaceCuts(regular: "ArialMT", bold: "Arial-BoldMT")
        case .verdana:
            FaceCuts(regular: "Verdana", bold: "Verdana-Bold")
        case .trebuchet:
            FaceCuts(regular: "TrebuchetMS", bold: "TrebuchetMS-Bold")
        case .carlito:
            FaceCuts(regular: "Carlito", bold: "Carlito-Bold")
        case .timesNewRoman:
            FaceCuts(regular: "TimesNewRomanPSMT", bold: "TimesNewRomanPS-BoldMT")
        case .georgia:
            FaceCuts(regular: "Georgia", bold: "Georgia-Bold")
        case .palatino:
            FaceCuts(regular: "Palatino-Roman", bold: "Palatino-Bold")
        case .charter:
            FaceCuts(regular: "Charter-Roman", bold: "Charter-Bold", heavy: "Charter-Black")
        case .baskerville:
            FaceCuts(regular: "Baskerville", semibold: "Baskerville-SemiBold", bold: "Baskerville-Bold")
        case .hoeflerText:
            FaceCuts(regular: "HoeflerText-Regular", bold: "HoeflerText-Black")
        case .iowanOldStyle:
            FaceCuts(regular: "IowanOldStyle-Roman", bold: "IowanOldStyle-Bold")
        case .athelas:
            FaceCuts(regular: "Athelas-Regular", bold: "Athelas-Bold")
        case .bodoni:
            FaceCuts(regular: "BodoniSvtyTwoITCTT-Book", bold: "BodoniSvtyTwoITCTT-Bold")
        case .superclarendon:
            FaceCuts(light: "Superclarendon-Light", regular: "Superclarendon-Regular", bold: "Superclarendon-Bold", heavy: "Superclarendon-Black")
        case .americanTypewriter:
            FaceCuts(light: "AmericanTypewriter-Light", regular: "AmericanTypewriter", semibold: "AmericanTypewriter-Semibold", bold: "AmericanTypewriter-Bold")
        case .rockwell:
            FaceCuts(regular: "Rockwell-Regular", bold: "Rockwell-Bold")
        case .menlo:
            FaceCuts(regular: "Menlo-Regular", bold: "Menlo-Bold")
        case .courierNew:
            FaceCuts(regular: "CourierNewPSMT", bold: "CourierNewPS-BoldMT")
        default:
            nil
        }
    }

    /// SF Compact is a variable face. Ask for the weight, and keep the name only when it is still Compact.
    private func compactName(_ weight: Font.Weight) -> String? {
        let families = [".SF Compact", "SF Compact"]
        for family in families {
            guard let base = UIFont(name: family, size: 17) else { continue }
            let described = base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: uiWeight(weight)]
            ])
            let resolved = UIFont(descriptor: described, size: 17)
            if resolved.fontName.localizedCaseInsensitiveContains("Compact") {
                return resolved.fontName
            }
        }
        return nil
    }

    private func bucket(_ weight: Font.Weight) -> FaceGrade {
        if weight == .ultraLight { return .ultraLight }
        if weight == .thin { return .thin }
        if weight == .light { return .light }
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        if weight == .heavy || weight == .black { return .heavy }
        return .regular
    }

    private func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        if weight == .ultraLight { return .ultraLight }
        if weight == .thin { return .thin }
        if weight == .light { return .light }
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        if weight == .heavy { return .heavy }
        if weight == .black { return .black }
        return .regular
    }

    fileprivate enum FaceGrade {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy
    }
}

/// The installed weights of one family. A missing weight uses the nearest cut that exists.
private struct FaceCuts {
    var light: String?
    var regular: String
    var medium: String?
    var semibold: String?
    var bold: String?
    var heavy: String?

    func name(for grade: AppTypeface.FaceGrade) -> String {
        switch grade {
        case .ultraLight, .thin, .light:
            light ?? regular
        case .regular:
            regular
        case .medium:
            medium ?? regular
        case .semibold:
            semibold ?? medium ?? bold ?? regular
        case .bold:
            bold ?? semibold ?? heavy ?? regular
        case .heavy:
            heavy ?? bold ?? semibold ?? regular
        }
    }
}

extension View {
    /// Reading text in the face chosen in Settings. Symbols keep `.font(.system)`.
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, digits: Bool = false) -> some View {
        modifier(AppStyledFont(style: style, weight: weight, digits: digits))
    }

    /// A size that already follows Dynamic Type, such as a ScaledMetric.
    func appFont(size: CGFloat, weight: Font.Weight = .regular, digits: Bool = false) -> some View {
        modifier(AppSizedFont(size: size, weight: weight, digits: digits))
    }
}

private struct AppStyledFont: ViewModifier {
    @Environment(AppSession.self) private var session
    var style: Font.TextStyle
    var weight: Font.Weight?
    var digits: Bool

    func body(content: Content) -> some View {
        content.font(session.typeface.font(style: style, weight: weight, digits: digits))
    }
}

private struct AppSizedFont: ViewModifier {
    @Environment(AppSession.self) private var session
    var size: CGFloat
    var weight: Font.Weight
    var digits: Bool

    func body(content: Content) -> some View {
        content.font(session.typeface.font(size: size, weight: weight, digits: digits))
    }
}
