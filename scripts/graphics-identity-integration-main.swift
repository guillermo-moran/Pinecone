import XCTest

@main
struct GraphicsIdentityRegressionRunner {
    static func main() {
        let suite = XCTestSuite(name: "Graphics Identity and Lifetime")
        suite.addTest(GraphicsIdentityTests.defaultTestSuite)
        suite.addTest(GPUCommandConcurrencyTests.defaultTestSuite)
        suite.run()
        guard let run = suite.testRun, run.executionCount >= 2,
              run.hasSucceeded, run.skipCount == 0 else { exit(1) }
        print("graphics integration: \(run.executionCount) tests passed")
    }
}
