import SwiftUI

struct SpeedometerGauge: View {
    let speed: Double
    let maximum: Double
    let unit: String
    let theme: SpeedTheme
    var numberStyle: SpeedNumberStyle = .digital
    var showsDecimal = false
    var compact = false

    private var progress: Double { min(max(speed / max(maximum, 1), 0), 1) }
    private var displayNumber: String {
        speed.formatted(.number.precision(.fractionLength(showsDecimal ? 1 : 0)))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.84))
                    .overlay(Circle().stroke(Color.white.opacity(0.11), lineWidth: 1))
                    .shadow(color: theme.inkSurfaceAccent.opacity(0.20), radius: compact ? 10 : 24)

                Circle()
                    .trim(from: 0.12, to: 0.88)
                    .stroke(Color.white.opacity(0.13), style: StrokeStyle(lineWidth: side * 0.055, lineCap: .round))
                    .rotationEffect(.degrees(90))

                Circle()
                    .trim(from: 0.12, to: 0.12 + 0.76 * progress)
                    .stroke(theme.inkSurfaceAccent, style: StrokeStyle(lineWidth: side * 0.055, lineCap: .round))
                    .rotationEffect(.degrees(90))

                ForEach(0..<13, id: \.self) { index in
                    Rectangle()
                        .fill(index <= Int(progress * 12) ? theme.inkSurfaceSecondary : Color.white.opacity(0.35))
                        .frame(width: side * 0.012, height: side * (index.isMultiple(of: 3) ? 0.075 : 0.045))
                        .offset(y: -side * 0.375)
                        .rotationEffect(.degrees(-135 + Double(index) * 22.5))
                }

                needle(side: side)
                    .rotationEffect(.degrees(SpeedometerGaugeGeometry.needleAngle(speed: speed, maximum: maximum)))

                Circle()
                    .fill(theme.inkSurfaceSecondary)
                    .frame(width: side * 0.11, height: side * 0.11)
                    .overlay(Circle().fill(.white).frame(width: side * 0.035))

                VStack(spacing: compact ? 0 : 4) {
                    SpeedNumberView(text: displayNumber, style: numberStyle, modernColor: .white)
                        .frame(width: side * 0.54, height: side * (compact ? 0.18 : 0.20))
                    Text(unit)
                        .font(.system(size: side * 0.065, weight: .bold, design: .rounded))
                        .foregroundStyle(numberStyle == .digital ? AppPalette.digitalGreen : theme.inkSurfaceAccent)
                }
                .offset(y: side * 0.22)

                endpointLabel("0", side: side)
                    .position(x: side * 0.27, y: side * 0.84)
                endpointLabel(Int(maximum).formatted(), side: side)
                    .position(x: side * 0.73, y: side * 0.84)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("accessibility_speedometer"))
        .accessibilityValue("\(displayNumber) \(unit)")
    }

    private func needle(side: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(Color.black.opacity(0.96))
                .frame(width: side * 0.35, height: side * 0.052)
                .offset(x: side * 0.145)

            Capsule()
                .fill(theme.inkSurfaceSecondary)
                .frame(width: side * 0.33, height: side * 0.026)
                .offset(x: side * 0.15)
        }
        .shadow(color: .black.opacity(0.58), radius: 3, y: 1)
    }

    private func endpointLabel(_ text: String, side: CGFloat) -> some View {
        Text(text)
            .font(.system(size: side * (compact ? 0.060 : 0.052), weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.68))
            .lineLimit(1)
            .frame(width: side * 0.20)
    }
}

enum SpeedometerGaugeGeometry {
    static func needleAngle(speed: Double, maximum: Double) -> Double {
        let progress = min(max(speed / max(maximum, 1), 0), 1)
        return 135 + progress * 270
    }
}

struct SpeedNumberView: View {
    let text: String
    let style: SpeedNumberStyle
    var modernColor: Color = .white
    var digitalActiveColor: Color = AppPalette.digitalGreen
    var digitalInactiveColor: Color = AppPalette.digitalGreenInactive
    var digitalOutlineColor: Color? = nil

    var body: some View {
        Group {
            switch style {
            case .digital:
                SevenSegmentNumberView(
                    text: text,
                    activeColor: digitalActiveColor,
                    inactiveColor: digitalInactiveColor,
                    outlineColor: digitalOutlineColor
                )
            case .modern:
                ZStack {
                    if let digitalOutlineColor {
                        ForEach(Array(modernOutlineOffsets.enumerated()), id: \.offset) { _, offset in
                            modernText
                                .foregroundStyle(digitalOutlineColor)
                                .offset(offset)
                        }
                    }
                    modernText.foregroundStyle(modernColor)
                }
                .platformNumericTextTransition()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("speed.number.\(style.rawValue)")
    }

    private var modernText: some View {
        Text(text)
            .font(.system(size: 170, weight: .black, design: .rounded).monospacedDigit())
            .minimumScaleFactor(0.25)
            .lineLimit(1)
    }

    private var modernOutlineOffsets: [CGSize] {
        [
            CGSize(width: -1.5, height: 0), CGSize(width: 1.5, height: 0),
            CGSize(width: 0, height: -1.5), CGSize(width: 0, height: 1.5),
            CGSize(width: -1, height: -1), CGSize(width: 1, height: -1),
            CGSize(width: -1, height: 1), CGSize(width: 1, height: 1)
        ]
    }
}

struct SevenSegmentNumberView: View {
    let text: String
    var activeColor: Color = AppPalette.digitalGreen
    var inactiveColor: Color = AppPalette.digitalGreenInactive
    var outlineColor: Color? = nil

    private var glyphs: [SevenSegmentGlyph] {
        text.compactMap(SevenSegmentGlyph.init(character:))
    }

    var body: some View {
        Canvas { context, size in
            guard !glyphs.isEmpty, size.width > 0, size.height > 0 else { return }

            let digitRatio = 0.58
            let separatorRatio = 0.16
            let gapRatio = 0.075
            let widthRatios = glyphs.map { $0.isSeparator ? separatorRatio : digitRatio }
            let intrinsicRatio = widthRatios.reduce(0, +) + gapRatio * Double(max(glyphs.count - 1, 0))
            let outlineWidth = outlineColor == nil ? 0 : max(1.5, min(size.height, size.width) * 0.012)
            let safeInset = outlineWidth / 2 + (outlineColor == nil ? 0 : 1)
            let availableWidth = max(0, size.width - safeInset * 2)
            let availableHeight = max(0, size.height - safeInset * 2)
            let glyphHeight = min(availableHeight, availableWidth / intrinsicRatio)
            let gap = glyphHeight * gapRatio
            let totalWidth = widthRatios.reduce(0) { $0 + $1 * glyphHeight } + gap * Double(max(glyphs.count - 1, 0))
            var originX = (size.width - totalWidth) / 2

            for (index, glyph) in glyphs.enumerated() {
                let glyphWidth = widthRatios[index] * glyphHeight
                let rect = CGRect(x: originX, y: safeInset + (availableHeight - glyphHeight) / 2, width: glyphWidth, height: glyphHeight)
                draw(glyph, in: rect, context: &context)
                originX += glyphWidth + gap
            }
        }
        .shadow(color: activeColor.opacity(0.34), radius: 5)
        .accessibilityHidden(true)
    }

    private func draw(_ glyph: SevenSegmentGlyph, in rect: CGRect, context: inout GraphicsContext) {
        if glyph.isSeparator {
            let diameter = min(rect.width * 0.72, rect.height * 0.10)
            let dot = CGRect(x: rect.midX - diameter / 2, y: rect.maxY - diameter * 1.25, width: diameter, height: diameter)
            let path = Path(ellipseIn: dot)
            strokeOutline(path, glyphHeight: rect.height, context: &context)
            context.fill(path, with: .color(activeColor))
            return
        }

        for segment in SevenSegment.allCases {
            let isActive = glyph.segments.contains(segment)
            let path = segment.path(in: rect)
            if isActive {
                strokeOutline(path, glyphHeight: rect.height, context: &context)
            }
            context.fill(path, with: .color(isActive ? activeColor : inactiveColor))
        }
    }

    private func strokeOutline(_ path: Path, glyphHeight: CGFloat, context: inout GraphicsContext) {
        guard let outlineColor else { return }
        context.stroke(path, with: .color(outlineColor), lineWidth: max(1.5, glyphHeight * 0.012))
    }
}

private enum SevenSegment: CaseIterable, Hashable {
    case top, upperLeft, upperRight, middle, lowerLeft, lowerRight, bottom

    func path(in rect: CGRect) -> Path {
        let thickness = rect.width * 0.15
        switch self {
        case .top:
            return horizontalPath(in: CGRect(x: rect.minX + thickness * 0.70, y: rect.minY, width: rect.width - thickness * 1.40, height: thickness))
        case .middle:
            return horizontalPath(in: CGRect(x: rect.minX + thickness * 0.70, y: rect.midY - thickness / 2, width: rect.width - thickness * 1.40, height: thickness))
        case .bottom:
            return horizontalPath(in: CGRect(x: rect.minX + thickness * 0.70, y: rect.maxY - thickness, width: rect.width - thickness * 1.40, height: thickness))
        case .upperLeft:
            return verticalPath(in: CGRect(x: rect.minX, y: rect.minY + thickness * 0.72, width: thickness, height: rect.height * 0.40))
        case .upperRight:
            return verticalPath(in: CGRect(x: rect.maxX - thickness, y: rect.minY + thickness * 0.72, width: thickness, height: rect.height * 0.40))
        case .lowerLeft:
            return verticalPath(in: CGRect(x: rect.minX, y: rect.midY + thickness * 0.22, width: thickness, height: rect.height * 0.40))
        case .lowerRight:
            return verticalPath(in: CGRect(x: rect.maxX - thickness, y: rect.midY + thickness * 0.22, width: thickness, height: rect.height * 0.40))
        }
    }

    private func horizontalPath(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.height * 0.52, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.height * 0.52, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.height * 0.52, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + rect.height * 0.52, y: rect.maxY))
            path.closeSubpath()
        }
    }

    private func verticalPath(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.width * 0.50))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.width * 0.50))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.width * 0.50))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.width * 0.50))
            path.closeSubpath()
        }
    }
}

private struct SevenSegmentGlyph {
    let segments: Set<SevenSegment>
    let isSeparator: Bool

    init?(character: Character) {
        if character == "." || character == "," || character == "٫" {
            segments = []
            isSeparator = true
            return
        }

        guard let value = character.wholeNumberValue else { return nil }
        isSeparator = false
        switch value {
        case 0: segments = [.top, .upperLeft, .upperRight, .lowerLeft, .lowerRight, .bottom]
        case 1: segments = [.upperRight, .lowerRight]
        case 2: segments = [.top, .upperRight, .middle, .lowerLeft, .bottom]
        case 3: segments = [.top, .upperRight, .middle, .lowerRight, .bottom]
        case 4: segments = [.upperLeft, .upperRight, .middle, .lowerRight]
        case 5: segments = [.top, .upperLeft, .middle, .lowerRight, .bottom]
        case 6: segments = [.top, .upperLeft, .middle, .lowerLeft, .lowerRight, .bottom]
        case 7: segments = [.top, .upperRight, .lowerRight]
        case 8: segments = Set(SevenSegment.allCases)
        case 9: segments = [.top, .upperLeft, .upperRight, .middle, .lowerRight, .bottom]
        default: return nil
        }
    }
}
