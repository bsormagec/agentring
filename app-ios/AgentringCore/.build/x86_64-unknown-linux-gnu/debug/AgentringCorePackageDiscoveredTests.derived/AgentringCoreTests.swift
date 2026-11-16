import XCTest
@testable import AgentringCoreTests

fileprivate extension ProtocolFixturesTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__ProtocolFixturesTests = [
        ("testCallJoinInfoDecodes", testCallJoinInfoDecodes),
        ("testEveryEventFixtureParsesToATypedEventAndRoundTrips", testEveryEventFixtureParsesToATypedEventAndRoundTrips),
        ("testFixtureDetails", testFixtureDetails),
        ("testOptionalFieldsAreOmittedWhenEncoding", testOptionalFieldsAreOmittedWhenEncoding),
        ("testPairResponseWithApnsPushConfig", testPairResponseWithApnsPushConfig),
        ("testPushFixtures", testPushFixtures),
        ("testUnknownEventTypesAreTolerated", testUnknownEventTypesAreTolerated)
    ]
}

fileprivate extension PushVerifierTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__PushVerifierTests = [
        ("testApnsUserInfoVerification", testApnsUserInfoVerification),
        ("testBase64Url", testBase64Url),
        ("testHmacSha256KnownAnswers", testHmacSha256KnownAnswers),
        ("testPeekEventDoesNotVerify", testPeekEventDoesNotVerify),
        ("testPushSignatureMatchesTheSharedTestVector", testPushSignatureMatchesTheSharedTestVector),
        ("testSignedButMalformedEventIsRejected", testSignedButMalformedEventIsRejected)
    ]
}

fileprivate extension RelayApiTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__RelayApiTests = [
        ("testCallLifecycleAndMessagePaths", asyncTest(testCallLifecycleAndMessagePaths)),
        ("testCancellationCancelsTheRequest", asyncTest(testCancellationCancelsTheRequest)),
        ("testCreateCallToTheAgent", asyncTest(testCreateCallToTheAgent)),
        ("testErrorsWithoutTheRelayErrorBody", asyncTest(testErrorsWithoutTheRelayErrorBody)),
        ("testJoinCallAndActiveCallInStatus", asyncTest(testJoinCallAndActiveCallInStatus)),
        ("testNotPairedFailsWithoutARequest", asyncTest(testNotPairedFailsWithoutARequest)),
        ("testPushGatewayRegister", asyncTest(testPushGatewayRegister)),
        ("testRelayApiSpeaksTheProtocol", asyncTest(testRelayApiSpeaksTheProtocol))
    ]
}

fileprivate extension RelayIntegrationTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__RelayIntegrationTests = [
        ("testPairMessagesCallsAndEvents", asyncTest(testPairMessagesCallsAndEvents))
    ]
}

fileprivate extension RelaySocketNetworkTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__RelaySocketNetworkTests = [
        ("testAServerNamingAnotherRelayIsDropped", testAServerNamingAnotherRelayIsDropped),
        ("testCloseCode4401IsUnauthorized", testCloseCode4401IsUnauthorized),
        ("testHttp401OnUpgradeIsUnauthorized", testHttp401OnUpgradeIsUnauthorized),
        ("testReconnectsAndResumesFromTheLastSeq", testReconnectsAndResumesFromTheLastSeq),
        ("testThePairedRelayStaysConnected", testThePairedRelayStaysConnected)
    ]
}

fileprivate extension RelaySocketTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__RelaySocketTests = [
        ("testAConnectionThatStopsAnsweringPingsIsReplaced", testAConnectionThatStopsAnsweringPingsIsReplaced),
        ("testAServerNamingAnotherRelayIsDroppedAndDeliversNothing", testAServerNamingAnotherRelayIsDroppedAndDeliversNothing),
        ("testAnsweredPingsKeepTheConnection", testAnsweredPingsKeepTheConnection),
        ("testBackoffGrowsToThirtySeconds", testBackoffGrowsToThirtySeconds),
        ("testBackoffGrowsWhileNothingConnects", testBackoffGrowsWhileNothingConnects),
        ("testCloseCode4401IsUnauthorizedAndStopsReconnecting", testCloseCode4401IsUnauthorizedAndStopsReconnecting),
        ("testHttp401OnUpgradeIsUnauthorized", testHttp401OnUpgradeIsUnauthorized),
        ("testMalformedAndBinaryFramesAreSkipped", testMalformedAndBinaryFramesAreSkipped),
        ("testNoExpectedRelayAcceptsAnyHello", testNoExpectedRelayAcceptsAnyHello),
        ("testOtherHttpErrorsOnUpgradeRetry", testOtherHttpErrorsOnUpgradeRetry),
        ("testReconnectsWithBackoffAndResumesFromTheLastSeq", testReconnectsWithBackoffAndResumesFromTheLastSeq),
        ("testStartAgainAfterUnauthorized", testStartAgainAfterUnauthorized),
        ("testStartTwiceConnectsOnce", testStartTwiceConnectsOnce),
        ("testStopCancelsAPendingReconnect", testStopCancelsAPendingReconnect),
        ("testStopIsFinal", testStopIsFinal),
        ("testThePairedRelayStaysConnected", testThePairedRelayStaysConnected)
    ]
}

fileprivate extension RelayUrlPolicyTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__RelayUrlPolicyTests = [
        ("testLiveKitUrlMustBeWssOutsideAPrivateNetwork", testLiveKitUrlMustBeWssOutsideAPrivateNetwork),
        ("testPrivateHosts", testPrivateHosts),
        ("testQrPayloadParsingAndUrlPolicy", testQrPayloadParsingAndUrlPolicy),
        ("testRelayUrls", testRelayUrls)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __AgentringCoreTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(ProtocolFixturesTests.__allTests__ProtocolFixturesTests),
        testCase(PushVerifierTests.__allTests__PushVerifierTests),
        testCase(RelayApiTests.__allTests__RelayApiTests),
        testCase(RelayIntegrationTests.__allTests__RelayIntegrationTests),
        testCase(RelaySocketNetworkTests.__allTests__RelaySocketNetworkTests),
        testCase(RelaySocketTests.__allTests__RelaySocketTests),
        testCase(RelayUrlPolicyTests.__allTests__RelayUrlPolicyTests)
    ]
}