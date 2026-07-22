import Foundation
@testable import WispKit

func smokeTests(_ t: TestRunner) -> [TestCase] {
    [
        TestCase("token estimator approximates chars/4") {
            t.expectEqual(TokenEstimator.estimate("abcdefgh"), 2)
            t.expectEqual(TokenEstimator.estimate(""), 1)
        },
        TestCase("default config has active profile and mock") {
            let config = WispConfig.makeDefault()
            t.expect(config.activeProfile != nil, "active profile resolves")
            t.expect(config.profiles.contains { $0.id == "mock" }, "mock profile exists")
        },
    ]
}
