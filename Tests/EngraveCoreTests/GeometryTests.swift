import Testing
@testable import EngraveCore

@Test func rectangleFlattensToFourCorners() {
    let p = Path2D.rect(width: 10, height: 4).flattened()
    #expect(p.count == 1)
    #expect(p[0].points.count == 4)
    #expect(abs(abs(p[0].signedArea) - 40) < 1e-9)
}
