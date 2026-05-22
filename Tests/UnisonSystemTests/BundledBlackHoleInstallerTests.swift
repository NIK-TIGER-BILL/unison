import Testing
@testable import UnisonSystem
@testable import UnisonDomain

// MARK: - Asset-selection unit tests

@Test
func assetSelection_picksMatching2chAnd16ch() {
    let assets = [
        makeAsset(name: "BlackHole2ch.v0.6.0.pkg", url: "https://example.com/2ch.pkg"),
        makeAsset(name: "BlackHole16ch.v0.6.0.pkg", url: "https://example.com/16ch.pkg"),
    ]
    let picked = BundledBlackHoleInstaller.selectAssets(from: assets)
    #expect(picked != nil)
    #expect(picked?.two.name == "BlackHole2ch.v0.6.0.pkg")
    #expect(picked?.sixteen.name == "BlackHole16ch.v0.6.0.pkg")
}

@Test
func assetSelection_doesNotConfuse2chWith16ch() {
    // The 16ch asset contains the substring "2ch" — earlier naive
    // `contains("2ch")` implementations would erroneously pick it as
    // the 2ch asset. Verify we exclude "16ch" from the 2ch match.
    let assets = [
        makeAsset(name: "BlackHole16ch.v1.0.0.pkg", url: "https://example.com/16ch.pkg"),
        makeAsset(name: "BlackHole2ch.v1.0.0.pkg", url: "https://example.com/2ch.pkg"),
    ]
    let picked = BundledBlackHoleInstaller.selectAssets(from: assets)
    #expect(picked?.two.name == "BlackHole2ch.v1.0.0.pkg")
    #expect(picked?.sixteen.name == "BlackHole16ch.v1.0.0.pkg")
}

@Test
func assetSelection_ignoresNonPkgFiles() {
    let assets = [
        makeAsset(name: "BlackHole2ch.v0.6.0.pkg", url: "https://example.com/2ch.pkg"),
        makeAsset(name: "BlackHole16ch.v0.6.0.dmg", url: "https://example.com/16ch.dmg"),
    ]
    // 16ch is only available as a `.dmg` — selection must fail.
    #expect(BundledBlackHoleInstaller.selectAssets(from: assets) == nil)
}

@Test
func assetSelection_emptyAssetsReturnsNil() {
    #expect(BundledBlackHoleInstaller.selectAssets(from: []) == nil)
}

@Test
func assetSelection_missing2chReturnsNil() {
    let assets = [
        makeAsset(name: "BlackHole16ch.v0.6.0.pkg", url: "https://example.com/16ch.pkg"),
    ]
    #expect(BundledBlackHoleInstaller.selectAssets(from: assets) == nil)
}

// MARK: - GitHub release JSON decoding

@Test
func githubRelease_decodesAssetUrlsFromSnakeCase() throws {
    let json = makeReleaseJSON(assets: [
        (name: "BlackHole2ch.v0.6.0.pkg", url: "https://github.com/example/BlackHole2ch.pkg"),
        (name: "BlackHole16ch.v0.6.0.pkg", url: "https://github.com/example/BlackHole16ch.pkg"),
    ])
    let release = try decodeRelease(json)
    #expect(release.assets.count == 2)
    #expect(release.assets[0].name == "BlackHole2ch.v0.6.0.pkg")
    #expect(release.assets[0].browserDownloadURL.absoluteString ==
            "https://github.com/example/BlackHole2ch.pkg")
}

// MARK: - End-to-end with injected fakes

@Test
func install_happyPath_invokesPkgutilAndInstaller() async throws {
    // Release tag `v0.6.1` drives the existential.audio URL build.
    // Assets are intentionally empty — upstream stopped attaching .pkgs
    // to GitHub releases since v0.6.0, so the installer must NOT rely
    // on `assets[]` and instead construct URLs from `tag_name`.
    let releaseJSON = makeReleaseJSON(tag: "v0.6.1", assets: [])

    let downloadedURLs = Mutex<[String]>([])
    let processCalls = Mutex<[(String, [String])]>([])

    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: releaseJSON),
        downloadFile: makeRecordingDownloader(into: downloadedURLs),
        runProcess: makeRecordingRunner(into: processCalls)
    ))

    try await installer.runBundledInstaller()

    let calls = processCalls.withLock { $0 }
    #expect(calls.count == 3) // 2× pkgutil + 1× osascript
    #expect(calls[0].0 == "/usr/sbin/pkgutil")
    #expect(calls[0].1.first == "--check-signature")
    #expect(calls[1].0 == "/usr/sbin/pkgutil")
    #expect(calls[2].0 == "/usr/bin/osascript")
    // The osascript invocation must chain both installer commands with
    // a single `do shell script ... with administrator privileges`.
    let script = calls[2].1.last ?? ""
    #expect(script.contains("with administrator privileges"))
    #expect(script.contains("&&"))
    #expect(script.contains("installer -pkg"))

    let urls = downloadedURLs.withLock { $0 }
    #expect(urls == [
        "https://existential.audio/downloads/BlackHole2ch-0.6.1.pkg",
        "https://existential.audio/downloads/BlackHole16ch-0.6.1.pkg",
    ])
}

@Test
func normalizeVersion_stripsLeadingV() {
    #expect(BundledBlackHoleInstaller.normalizeVersion("v0.6.1") == "0.6.1")
    #expect(BundledBlackHoleInstaller.normalizeVersion("v1.0.0") == "1.0.0")
}

@Test
func normalizeVersion_leavesUnprefixedVersionsAlone() {
    #expect(BundledBlackHoleInstaller.normalizeVersion("0.6.1") == "0.6.1")
    #expect(BundledBlackHoleInstaller.normalizeVersion("") == "")
}

@Test
func install_releaseFetchHTTPError_throwsReleaseFetchFailed() async {
    let downloaderHit = Mutex<Bool>(false)
    let runnerHit = Mutex<Bool>(false)
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returningStatus: 404),
        downloadFile: makeForbiddenDownloader(sink: downloaderHit),
        runProcess: makeForbiddenRunner(sink: runnerHit)
    ))

    do {
        try await installer.runBundledInstaller()
        Issue.record("expected throw")
    } catch let error as BlackHoleInstallError {
        #expect(error == .releaseFetchFailed(404))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(downloaderHit.withLock { $0 } == false)
    #expect(runnerHit.withLock { $0 } == false)
}

@Test
func install_releaseFetchTransportError_throwsReleaseFetchFailedMinusOne() async {
    struct Boom: Error {}
    let downloaderHit = Mutex<Bool>(false)
    let runnerHit = Mutex<Bool>(false)
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(throwing: Boom()),
        downloadFile: makeForbiddenDownloader(sink: downloaderHit),
        runProcess: makeForbiddenRunner(sink: runnerHit)
    ))

    do {
        try await installer.runBundledInstaller()
        Issue.record("expected throw")
    } catch let error as BlackHoleInstallError {
        #expect(error == .releaseFetchFailed(-1))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(downloaderHit.withLock { $0 } == false)
    #expect(runnerHit.withLock { $0 } == false)
}

// `install_emptyAssets_throwsAssetsNotFound` removed: the installer no
// longer relies on `assets[]` from the GitHub release (upstream stopped
// attaching .pkg assets since v0.6.0). URLs are built from `tag_name`
// against the existential.audio CDN.

@Test
func install_signatureCheckFails_throwsSignatureInvalid() async {
    let releaseJSON = makeReleaseJSON(assets: [
        (name: "BlackHole2ch.pkg", url: "https://example.com/2ch.pkg"),
        (name: "BlackHole16ch.pkg", url: "https://example.com/16ch.pkg"),
    ])
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: releaseJSON),
        downloadFile: makeNoOpDownloader(),
        runProcess: makeStatusByExecutable(pkgutil: 1, osascript: 0)
    ))

    do {
        try await installer.runBundledInstaller()
        Issue.record("expected throw")
    } catch let error as BlackHoleInstallError {
        #expect(error == .signatureInvalid)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test
func install_osascriptFails_throwsInstallFailed() async {
    let releaseJSON = makeReleaseJSON(assets: [
        (name: "BlackHole2ch.pkg", url: "https://example.com/2ch.pkg"),
        (name: "BlackHole16ch.pkg", url: "https://example.com/16ch.pkg"),
    ])
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: releaseJSON),
        downloadFile: makeNoOpDownloader(),
        runProcess: makeStatusByExecutable(pkgutil: 0, osascript: 1)
    ))

    do {
        try await installer.runBundledInstaller()
        Issue.record("expected throw")
    } catch let error as BlackHoleInstallError {
        if case .installFailed = error {
            // expected
        } else {
            Issue.record("expected .installFailed, got \(error)")
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test
func install_downloadFailure_throwsDownloadFailed() async {
    struct DownloadBoom: Error {}
    let releaseJSON = makeReleaseJSON(assets: [
        (name: "BlackHole2ch.pkg", url: "https://example.com/2ch.pkg"),
        (name: "BlackHole16ch.pkg", url: "https://example.com/16ch.pkg"),
    ])
    let runnerHit = Mutex<Bool>(false)
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: releaseJSON),
        downloadFile: makeThrowingDownloader(error: DownloadBoom()),
        runProcess: makeForbiddenRunner(sink: runnerHit)
    ))

    do {
        try await installer.runBundledInstaller()
        Issue.record("expected throw")
    } catch let error as BlackHoleInstallError {
        #expect(error == .downloadFailed)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(runnerHit.withLock { $0 } == false)
}

// MARK: - Post-install verification (the bug this PR fixes)

@Test
func install_osascriptSucceedsButDevicesNeverAppear_throwsVerificationFailed() async {
    // Regression for the silent-failure bug: `osascript` returns 0
    // (auth succeeded, `installer` ran) but BlackHole devices never
    // show up in CoreAudio. Previously this returned silently, the
    // ViewModel set `.done`, and the next `refresh()` flipped status
    // back to `.pending` with no error shown to the user. Now we
    // must throw `verificationFailed` so the UI can surface a real
    // error message.
    let releaseJSON = makeReleaseJSON(tag: "v0.6.1", assets: [])

    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: releaseJSON),
        downloadFile: makeNoOpDownloader(),
        runProcess: makeStatusByExecutable(pkgutil: 0, osascript: 0),
        verifyInstalled: { false }  // devices never appear
    ))

    do {
        try await installer.runBundledInstaller()
        Issue.record("expected verificationFailed throw")
    } catch let error as BlackHoleInstallError {
        #expect(error == .verificationFailed)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test
func install_osascriptSucceedsAndDevicesAppear_returnsCleanly() async throws {
    // Happy path with explicit `verifyInstalled` returning true. This
    // is what `install_happyPath_invokesPkgutilAndInstaller` already
    // exercises (the default `verifyInstalled` is `{ true }`), but
    // we make the contract explicit here.
    let releaseJSON = makeReleaseJSON(tag: "v0.6.1", assets: [])
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: releaseJSON),
        downloadFile: makeNoOpDownloader(),
        runProcess: makeStatusByExecutable(pkgutil: 0, osascript: 0),
        verifyInstalled: { true }
    ))
    try await installer.runBundledInstaller()
    // No throw — success.
}

// MARK: - osascript exit code carries captured stderr

@Test
func install_osascriptNonZero_propagatesStderrInInstallFailed() async {
    // When `do shell script` fails, osascript writes the reason
    // (e.g., "User canceled.") to stderr and exits nonzero. The
    // installer must surface that text in the `installFailed`
    // associated value so the ViewModel can branch on
    // "user cancelled auth" vs "installer crashed".
    let releaseJSON = makeReleaseJSON(tag: "v0.6.1", assets: [])
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: releaseJSON),
        downloadFile: makeNoOpDownloader(),
        runProcess: { executable, _ in
            if executable.hasSuffix("pkgutil") { return (0, "", "") }
            // osascript: simulate "User canceled."
            return (1, "", "0:0: execution error: User canceled. (-128)\n")
        }
    ))

    do {
        try await installer.runBundledInstaller()
        Issue.record("expected throw")
    } catch let error as BlackHoleInstallError {
        if case .installFailed(let detail) = error {
            #expect(detail.contains("User canceled"))
        } else {
            Issue.record("expected .installFailed, got \(error)")
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Shell / AppleScript quoting

@Test
func shellQuote_wrapsPlainPathInSingleQuotes() {
    #expect(BundledBlackHoleInstaller.shellQuote("/tmp/Unison.pkg") == "'/tmp/Unison.pkg'")
}

@Test
func shellQuote_escapesEmbeddedSingleQuotes() {
    // bash-safe single-quote escape: close, escape, reopen.
    // `O'Reilly` → `'O'\''Reilly'`
    #expect(BundledBlackHoleInstaller.shellQuote("O'Reilly") == "'O'\\''Reilly'")
    // Path with a single quote in the directory name.
    #expect(
        BundledBlackHoleInstaller.shellQuote("/tmp/some'dir/a.pkg")
            == "'/tmp/some'\\''dir/a.pkg'"
    )
}

@Test
func appleScriptQuote_escapesBackslashAndDoubleQuote() {
    #expect(BundledBlackHoleInstaller.appleScriptQuote("plain") == "\"plain\"")
    #expect(
        BundledBlackHoleInstaller.appleScriptQuote("a\"b")
            == "\"a\\\"b\""
    )
    #expect(
        BundledBlackHoleInstaller.appleScriptQuote("a\\b")
            == "\"a\\\\b\""
    )
}

@Test
func install_scriptPath_isAppleScriptQuotedNotRawConcatenated() async throws {
    // The osascript `-e` argument the installer passes should be an
    // AppleScript expression where the `do shell script` string is
    // properly quoted with escaped backslashes/quotes. We sanity-
    // check that the script string starts with `do shell script "`
    // (i.e., not `do shell script '`).
    let releaseJSON = makeReleaseJSON(tag: "v0.6.1", assets: [])
    let processCalls = Mutex<[(String, [String])]>([])
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: releaseJSON),
        downloadFile: makeNoOpDownloader(),
        runProcess: makeRecordingRunner(into: processCalls)
    ))
    try await installer.runBundledInstaller()
    let calls = processCalls.withLock { $0 }
    let osascriptCall = calls.first(where: { $0.0.hasSuffix("osascript") })
    let script = osascriptCall?.1.last ?? ""
    #expect(script.hasPrefix("do shell script \""))
    #expect(script.hasSuffix("with administrator privileges"))
}
