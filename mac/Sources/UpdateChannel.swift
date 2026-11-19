// 1401
// Copyright (c) 2026 NullMoth Systems. SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

// Early updates. A new driver goes to the people who asked for it first, and only becomes everyone's update once the
// reports from those installs show it did not make any machine class worse. GitHub keeps /releases/latest on the full
// release and marks the staged one a pre-release, so an install that has not joined never sees it. One that has joined
// reads the site's channels file (/download/channels.json, written by the release pipeline) and is offered the
// pre-release it names, fetched from GitHub by its tag. A withdrawn pre-release is cleared from that file, so it stops
// being offered even while it is still on GitHub. When the file cannot be read or names no newer pre-release, the
// install gets the full release like everyone else. The choice is a file in Application Support; leaving puts the
// install back on the full releases at its next check.
enum UpdateChannel {
    static let stateFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NullMoth/early-updates.json")
    // The product's own repository. /releases/latest never names a pre-release, so a product whose releases are all
    // betas would never be offered an update from it; the list endpoint shows every release and the newest is picked.
    static let latestURL = URL(string: "https://api.github.com/repos/nullmoth/liberator/releases?per_page=30")!
    /// True while every release of the product is a beta: pre-releases are offered to everyone. Set false when the first
    /// full release ships, and pre-releases go back to the early-updates switch.
    static let betaProduct = true
    static let channelsURL = URL(string: "https://nullmothsystems.com/download/channels.json")!
    static let tagsBase = "https://api.github.com/repos/nullmoth/liberator/releases/tags/"

    static var isOn: Bool {
        guard let d = try? Data(contentsOf: stateFile),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return j["on"] as? Bool ?? false
    }

    static func set(on: Bool) {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let s: [String: Any] = ["on": on, "changed": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: stateFile, options: .atomic)
        }
    }

    /// The pre-release tag the channels file offers: only a plain "vX.Y.Z" tag newer than the file's stable release.
    /// nil means the full release (no file, unreadable file, no pre-release, or one not newer than stable).
    static func prereleaseTag(_ channels: Any?) -> String? {
        guard let doc = channels as? [String: Any], let pre = doc["prerelease"] as? [String: Any],
              let tag = pre["tag"] as? String,
              tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        if let stable = (doc["stable"] as? [String: Any])?["tag"] as? String, !newer(tag, than: stable) { return nil }
        return tag
    }

    /// Where the update check asks GitHub: the full release, or for early updates the pre-release the channels file names.
    static func releaseURL(early: Bool, channels: Any?) -> URL {
        guard early, let tag = prereleaseTag(channels), let u = URL(string: tagsBase + tag) else { return latestURL }
        return u
    }

    /// "v3.0.0-beta.3" -> [3,0,0,3]; a full release "v3.0.0" -> [3,0,0,Int.max], so a beta sorts below its release.
    static func versionKey(_ tag: String) -> [Int] {
        var t = Substring(tag.drop(while: { !$0.isNumber }))
        var pre = Int.max
        if let r = t.range(of: "-beta.") { pre = Int(t[r.upperBound...]) ?? 0; t = t[..<r.lowerBound] }
        return t.split(separator: ".").map { Int($0) ?? 0 } + [pre]
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = versionKey(a), y = versionKey(b)
        let n = max(x.count, y.count) - 1
        for i in 0...n {
            // the pre-release slot is last; numeric slots missing on one side count as 0
            let p = i == n ? (x.last ?? 0) : (i < x.count - 1 ? x[i] : 0), q = i == n ? (y.last ?? 0) : (i < y.count - 1 ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }

    /// The release to offer from GitHub's answer (one release either way). A draft is never offered. Not early: a
    /// pre-release is refused too (GitHub never names one at /releases/latest; refusing it here keeps it that way if
    /// the address or GitHub's rule ever changes). nil when the payload is not a usable release.
    static func pick(_ payload: Any, early: Bool) -> [String: Any]? {
        // the list endpoint: the newest usable release, pre-releases included only when the channel allows them
        if let list = payload as? [[String: Any]] {
            let allowPre = early || betaProduct
            var best: [String: Any]? = nil
            for r in list {
                guard let tag = r["tag_name"] as? String,
                      tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$"#, options: .regularExpression) != nil,
                      r["draft"] as? Bool != true, r["assets"] is [[String: Any]],
                      allowPre || r["prerelease"] as? Bool != true else { continue }
                if best == nil || newer(tag, than: best!["tag_name"] as! String) { best = r }
            }
            return best
        }
        guard let one = payload as? [String: Any], one["tag_name"] is String, one["assets"] is [[String: Any]],
              one["draft"] as? Bool != true else { return nil }
        if !early && one["prerelease"] as? Bool == true { return nil }
        return one
    }
}
