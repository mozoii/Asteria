import Testing
import AsteriaModel

@Suite("Starfield model")
struct StarfieldTests {
    @Test("the field is identical across instances at the same intensity")
    func deterministic() {
        #expect(Starfield(intensity: 1).stars == Starfield(intensity: 1).stars)
        #expect(Starfield(intensity: 0.5).stars == Starfield(intensity: 0.5).stars)
    }

    @Test("star count scales with intensity and never drops below the floor")
    func countScales() {
        #expect(Starfield(intensity: 1).stars.count == 54)
        #expect(Starfield(intensity: 2).stars.count == 108)
        #expect(Starfield(intensity: 0.1).stars.count == 8)   // floor of max(8, …)
    }

    @Test("wrap01 recycles any coordinate into 0..<1")
    func wraps() {
        #expect(abs(Starfield.wrap01(1.5) - 0.5) < 1e-12)
        #expect(abs(Starfield.wrap01(-0.25) - 0.75) < 1e-12)
        #expect(Starfield.wrap01(2.0) == 0.0)
        #expect(Starfield.wrap01(0.3) == 0.3)
    }

    @Test("drifted star positions stay within the canvas at any time")
    func positionsStayNormalized() {
        let field = Starfield(intensity: 1)
        for t in [0.0, 12.5, 100.0, 9_999.0] {
            for star in field.stars {
                let p = field.position(of: star, at: t)
                #expect(p.x >= 0 && p.x < 1)
                #expect(p.y >= 0 && p.y < 1)
            }
        }
    }

    @Test("twinkle only modulates alpha when animating")
    func twinkleGatedByAnimate() {
        let field = Starfield(intensity: 1)
        for star in field.stars {
            #expect(field.alpha(of: star, at: 3.0, animate: false) == star.baseAlpha)
        }
    }

    @Test("a shooting star appears once per period and is dark between appearances")
    func shootingStarWindow() {
        var active = 0, inactive = 0
        for i in 0 ..< 680 {                       // scan two ~34s periods at 0.1s
            let t = Double(i) * 0.1
            if let shot = Starfield.shootingStar(at: t) {
                active += 1
                #expect(shot.alpha >= 0 && shot.alpha <= 0.5)
            } else {
                inactive += 1
            }
        }
        #expect(active > 0)       // it does appear
        #expect(inactive > active)   // and is absent most of the time
    }
}
