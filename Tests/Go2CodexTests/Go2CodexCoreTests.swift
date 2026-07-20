import Testing
@testable import Go2CodexCore

@Test
func preferencesSchemaRemainsBackwardCompatibleAtOne() {
    #expect(Go2CodexCoreInfo.preferencesSchemaVersion == 1)
}
