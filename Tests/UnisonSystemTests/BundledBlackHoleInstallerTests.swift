import Testing
@testable import UnisonSystem

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
    let pkg2UrlString = "https://example.com/BlackHole2ch.pkg"
    let pkg16UrlString = "https://example.com/BlackHole16ch.pkg"
    let releaseJSON = makeReleaseJSON(assets: [
        (name: "BlackHole2ch.v0.6.0.pkg", url: pkg2UrlString),
        (name: "BlackHole16ch.v0.6.0.pkg", url: pkg16UrlString),
    ])

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
    #expect(urls == [pkg2UrlString, pkg16UrlString])
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

@Test
func install_emptyAssets_throwsAssetsNotFound() async {
    let emptyReleaseJSON = makeReleaseJSON(assets: [])
    let downloaderHit = Mutex<Bool>(false)
    let runnerHit = Mutex<Bool>(false)
    let installer = makeFakeInstaller(.init(
        fetchData: makeFetcher(returning: emptyReleaseJSON),
        downloadFile: makeForbiddenDownloader(sink: downloaderHit),
        runProcess: makeForbiddenRunner(sink: runnerHit)
    ))

    do {
        try await installer.runBundledInstaller()
        Issue.record("expected throw")
    } catch let error as BlackHoleInstallError {
        #expect(error == .assetsNotFound)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(downloaderHit.withLock { $0 } == false)
    #expect(runnerHit.withLock { $0 } == false)
}

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
