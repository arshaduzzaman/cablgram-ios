import SwiftUI

/// Cablgram's own dock icons: rounded, bold outlines with round ends, drawn
/// on a 24×24 grid. Unselected they're outlines; selected they're filled
/// (with the details cut out), like the tab icons in big social apps.
struct DockIcon: View {
    enum Kind { case home, walk, ticket }

    let kind: Kind
    let selected: Bool
    var color: Color = .black
    var size: CGFloat = 26

    var body: some View {
        Group {
            switch (kind, selected) {
            case (.home, false):
                HomeOutline().stroke(color, style: Self.line)
            case (.home, true):
                HomeFilled().fill(color, style: FillStyle(eoFill: true))
            case (.walk, false):
                Footprints().stroke(color, style: Self.line)
            case (.walk, true):
                Footprints().fill(color)
            case (.ticket, false):
                ZStack {
                    TicketShape().stroke(color, style: Self.line)
                    TicketTear().stroke(color, style: Self.line)
                }
            case (.ticket, true):
                TicketFilled().fill(color, style: FillStyle(eoFill: true))
            }
        }
        .frame(width: size, height: size)
    }

    /// Stroke width is set on the 24-point grid and scales with the icon.
    private static let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
}

// MARK: - Grid helper

/// Maps points on the 24×24 design grid into the shape's rect.
private struct Grid {
    let rect: CGRect
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
    }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(origin: p(x, y), size: CGSize(width: w / 24 * rect.width, height: h / 24 * rect.height))
    }
    func s(_ v: CGFloat) -> CGFloat { v / 24 * rect.width }
}

// MARK: - Home

/// A house with a softly rounded roof and base.
private func housePath(_ g: Grid) -> Path {
    var path = Path()
    path.move(to: g.p(3.5, 10.6))
    path.addLine(to: g.p(10.6, 4.3))
    path.addQuadCurve(to: g.p(13.4, 4.3), control: g.p(12, 3.1))
    path.addLine(to: g.p(20.5, 10.6))
    path.addLine(to: g.p(20.5, 18.5))
    path.addQuadCurve(to: g.p(18, 21), control: g.p(20.5, 21))
    path.addLine(to: g.p(6, 21))
    path.addQuadCurve(to: g.p(3.5, 18.5), control: g.p(3.5, 21))
    path.closeSubpath()
    return path
}

private struct HomeOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let g = Grid(rect: rect)
        var path = housePath(g)
        // Door: an open arch up from the base.
        path.move(to: g.p(9.6, 21))
        path.addLine(to: g.p(9.6, 16.4))
        path.addQuadCurve(to: g.p(14.4, 16.4), control: g.p(12, 13.6))
        path.addLine(to: g.p(14.4, 21))
        return path
    }
}

private struct HomeFilled: Shape {
    func path(in rect: CGRect) -> Path {
        let g = Grid(rect: rect)
        // Slightly fuller house so the fill matches the outline's weight.
        var path = Path()
        path.move(to: g.p(2.6, 10.4))
        path.addLine(to: g.p(10.3, 3.6))
        path.addQuadCurve(to: g.p(13.7, 3.6), control: g.p(12, 2.1))
        path.addLine(to: g.p(21.4, 10.4))
        path.addLine(to: g.p(21.4, 18.6))
        path.addQuadCurve(to: g.p(18.2, 22), control: g.p(21.4, 22))
        path.addLine(to: g.p(5.8, 22))
        path.addQuadCurve(to: g.p(2.6, 18.6), control: g.p(2.6, 22))
        path.closeSubpath()
        // Door cut out.
        path.move(to: g.p(9.8, 22))
        path.addLine(to: g.p(9.8, 17))
        path.addQuadCurve(to: g.p(14.2, 17), control: g.p(12, 14.4))
        path.addLine(to: g.p(14.2, 22))
        path.closeSubpath()
        return path
    }
}

// MARK: - Walk

/// Two footprints, one a step ahead of the other.
private struct Footprints: Shape {
    func path(in rect: CGRect) -> Path {
        let g = Grid(rect: rect)
        var path = Path()
        // Left foot (lower): sole and heel.
        path.addPath(Path(ellipseIn: g.r(2.6, 7.2, 7, 10.4))
            .applying(rotation(-10, around: g.p(6.1, 12.4))))
        path.addPath(Path(ellipseIn: g.r(3.4, 18.2, 5.6, 4.8))
            .applying(rotation(-10, around: g.p(6.2, 20.6))))
        // Right foot (higher).
        path.addPath(Path(ellipseIn: g.r(14.4, 1.2, 7, 10.4))
            .applying(rotation(10, around: g.p(17.9, 6.4))))
        path.addPath(Path(ellipseIn: g.r(14.9, 12.4, 5.6, 4.8))
            .applying(rotation(10, around: g.p(17.7, 14.8))))
        return path
    }

    private func rotation(_ degrees: CGFloat, around c: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -c.x, y: -c.y)
    }
}

// MARK: - Ticket

/// A rounded ticket with a notch bitten out of each side.
private func ticketPath(_ g: Grid, inset: CGFloat = 0) -> Path {
    let l = 2.4 - inset, r = 21.6 + inset, t = 5.2 - inset, b = 18.8 + inset
    let c: CGFloat = 3
    let notch: CGFloat = 2.6
    let mid: CGFloat = 12
    var path = Path()
    path.move(to: g.p(l + c, t))
    path.addLine(to: g.p(r - c, t))
    path.addQuadCurve(to: g.p(r, t + c), control: g.p(r, t))
    path.addLine(to: g.p(r, mid - notch))
    path.addCurve(to: g.p(r, mid + notch),
                  control1: g.p(r - notch * 1.3, mid - notch * 0.9),
                  control2: g.p(r - notch * 1.3, mid + notch * 0.9))
    path.addLine(to: g.p(r, b - c))
    path.addQuadCurve(to: g.p(r - c, b), control: g.p(r, b))
    path.addLine(to: g.p(l + c, b))
    path.addQuadCurve(to: g.p(l, b - c), control: g.p(l, b))
    path.addLine(to: g.p(l, mid + notch))
    path.addCurve(to: g.p(l, mid - notch),
                  control1: g.p(l + notch * 1.3, mid + notch * 0.9),
                  control2: g.p(l + notch * 1.3, mid - notch * 0.9))
    path.addLine(to: g.p(l, t + c))
    path.addQuadCurve(to: g.p(l + c, t), control: g.p(l, t))
    path.closeSubpath()
    return path
}

private struct TicketShape: Shape {
    func path(in rect: CGRect) -> Path { ticketPath(Grid(rect: rect)) }
}

/// The dashed tear line across the ticket's stub.
private struct TicketTear: Shape {
    func path(in rect: CGRect) -> Path {
        let g = Grid(rect: rect)
        var path = Path()
        for (y0, y1) in [(8.4, 9.8), (11.3, 12.7), (14.2, 15.6)] as [(CGFloat, CGFloat)] {
            path.move(to: g.p(15.4, y0))
            path.addLine(to: g.p(15.4, y1))
        }
        return path
    }
}

private struct TicketFilled: Shape {
    func path(in rect: CGRect) -> Path {
        let g = Grid(rect: rect)
        var path = ticketPath(g, inset: 0.9)
        // Tear line cut out as three short dashes.
        for y in [7.9, 10.9, 13.9] as [CGFloat] {
            path.addRoundedRect(in: g.r(14.4, y, 2, 2.2), cornerSize: CGSize(width: g.s(1), height: g.s(1)))
        }
        return path
    }
}
