// MONOLITH: `codesign -f -s - <bundle>` without codesign: the bundle's `_CodeSignature/CodeResources` is
// rebuilt under its own rules (files: SHA-1, files2: SHA-256), and its main executable is signed ad hoc
// with VPhoneSign, Info.plist in slot 1 and the new CodeResources in slot 3. Works on any
// VPhoneConfinedDirectory, so also on a guest volume in an APFS image.
import CryptoKit
import FirmwarePatcher
import Foundation
import VPhoneCoreKit
import VPhoneSign

enum MonolithBundleSeal {
    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    private struct Rule {
        let pattern: NSRegularExpression
        let weight: Double
        let omit, optional, nested, exclude: Bool
    }

    private static func rules(_ dictionary: [String: Any]?) -> [Rule] {
        (dictionary ?? [:]).compactMap { key, value in
            guard let regex = try? NSRegularExpression(pattern: key) else { return nil }
            if let on = value as? Bool {
                return on ? Rule(pattern: regex, weight: 1, omit: false, optional: false, nested: false, exclude: false) : nil
            }
            guard let d = value as? [String: Any] else { return nil }
            func flag(_ k: String) -> Bool { (d[k] as? Bool) ?? false }
            return Rule(pattern: regex, weight: (d["weight"] as? Double) ?? Double((d["weight"] as? Int) ?? 1),
                        omit: flag("omit"), optional: flag("optional"), nested: flag("nested"), exclude: flag("exclude"))
        }
    }

    /// The rule that decides a path: the matching one with the highest weight.
    private static func decide(_ path: String, _ rules: [Rule]) -> Rule? {
        let range = NSRange(path.startIndex..., in: path)
        return rules.filter { $0.pattern.firstMatch(in: path, range: range) != nil }.max { $0.weight < $1.weight }
    }

    /// Every file and link below the bundle, relative to it, but its seal.
    private static func walk(_ dir: VPhoneConfinedDirectory, _ prefix: String, into out: inout [(String, stat)]) throws {
        for name in try dir.entries().sorted() {
            let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if rel == "_CodeSignature" { continue }
            guard let s = try dir.status(name) else { continue }
            if s.st_mode & S_IFMT == S_IFDIR {
                try walk(try dir.directory(name), rel, into: &out)
            } else {
                out.append((rel, s))
            }
        }
    }

    static func seal(system: VPhoneConfinedDirectory, bundle: String, preserveEntitlements: Bool) throws {
        let root = try system.directory(bundle)
        guard let info = try? root.readData("Info.plist"),
              let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String
        else { throw Unsupported(description: "\(bundle): no Info.plist naming its executable") }
        let fallback = try PropertyListSerialization.propertyList(from: CustomFirmwareBundleSeal.empty, format: nil) as? [String: Any] ?? [:]
        let existing = (try? root.readData("_CodeSignature/CodeResources"))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? fallback
        let rules1 = rules(existing["rules"] as? [String: Any])
        let rules2 = rules(existing["rules2"] as? [String: Any])

        var entries: [(String, stat)] = []
        try walk(root, "", into: &entries)
        var files: [String: Any] = [:], files2: [String: Any] = [:]
        for (rel, status) in entries where rel != executable {
            let isLink = status.st_mode & S_IFMT == S_IFLNK
            let data = isLink ? nil : try root.readData(rel)
            if let r = decide(rel, rules1), !r.omit, !r.exclude, !r.nested, let data {
                let hash = Data(Insecure.SHA1.hash(data: data))
                files[rel] = r.optional ? ["hash": hash, "optional": true] : hash
            }
            if let r = decide(rel, rules2), !r.omit, !r.exclude {
                if r.nested { throw Unsupported(description: "\(bundle)/\(rel): nested code is not sealed here") }
                var entry: [String: Any]
                if isLink {
                    entry = ["symlink": try root.readLink(rel) ?? ""]
                } else {
                    entry = ["hash2": Data(SHA256.hash(data: data!))]
                }
                if r.optional { entry["optional"] = true }
                files2[rel] = entry
            }
        }
        var seal = existing
        seal["files"] = files
        seal["files2"] = files2
        let resources = try PropertyListSerialization.data(fromPropertyList: seal, format: .xml, options: 0)
        let signature = try root.directory("_CodeSignature", create: true)
        if let s = try signature.status("CodeResources") {
            try signature.writeFile("CodeResources", contents: resources, mode: s.st_mode & 0o7777, owner: (s.st_uid, s.st_gid))
        } else {
            try signature.writeFile("CodeResources", contents: resources, mode: 0o644, owner: (0, 0))
        }

        // The executable, ad hoc as `codesign -s -` signs it; its identifier stays.
        guard let status = try root.status(executable) else { throw Unsupported(description: "\(bundle)/\(executable) is missing") }
        let binary = try root.readData(executable)
        var options = VPhoneSignOptions(identifier: try VPhoneSigner.identifier(in: binary),
                                        entitlements: preserveEntitlements ? try VPhoneSigner.entitlements(in: binary).last : nil,
                                        style: .appleAdHoc)
        options.bundleInfoPlist = info
        options.bundleResources = resources
        let signed = try VPhoneSigner.sign(binary, options: options)
        try root.writeFile(executable, contents: signed, mode: status.st_mode & 0o7777, owner: (status.st_uid, status.st_gid))
    }
}
