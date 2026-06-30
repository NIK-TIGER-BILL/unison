import Testing
import CSpeexDSP

@Test func cspeexdsp_echoState_initAndDestroy_links() {
    // Proves the vendored C target compiles, links, and is callable from
    // Swift. 64-sample frame, 1024-sample tail — values irrelevant here.
    let st = speex_echo_state_init(64, 1024)
    #expect(st != nil)
    speex_echo_state_destroy(st)
}
