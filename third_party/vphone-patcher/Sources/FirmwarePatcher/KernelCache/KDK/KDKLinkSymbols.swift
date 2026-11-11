// Cross-image names for stripped collections, from ipsw#1372 symbols.go.
import Foundation
import VPhonePatchKit

struct KDKLinkSymbols {
    var imports: [String: [KDKSymbol]] = [:]
    var exports: [String: [KDKSymbol]] = [:]
    var unresolved: [(String, UInt64)] = []

    static func loadKnown(_ data: Data) throws -> [UInt64: [String]] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PatcherError.invalidFormat("invalid KDK symbol map") }
        var result: [UInt64: [String]] = [:]
        for (key, value) in raw {
            let address: UInt64? = if key.hasPrefix("0x") || key.hasPrefix("0X") {
                UInt64(key.dropFirst(2), radix: 16)
            } else if key.hasPrefix("0o") {
                UInt64(key.dropFirst(2), radix: 8)
            } else if key.hasPrefix("0b") {
                UInt64(key.dropFirst(2), radix: 2)
            } else if key.count > 1, key.first == "0" {
                UInt64(key, radix: 8)
            } else {
                UInt64(key)
            }
            guard let address, let names = (value as? [String]) ?? (value as? String).map({ [$0] }) else {
                throw PatcherError.invalidFormat("invalid symbol map entry: \(key)")
            }
            result[address] = names
        }
        return result
    }
}

extension KDKKernelCollection {
    func plist(at address: UInt64, count: UInt64) throws -> [String: Any] {
        var data = try read(Int(count), at: address)
        while data.last == 0 {
            data.removeLast()
        }
        guard let result = try PropertyListSerialization.propertyList(from: Data(data), format: nil) as? [String: Any] else {
            throw PatcherError.invalidFormat("KDK metadata is not a dictionary plist")
        }
        return result
    }

    func prelinkInfo() throws -> [[String: Any]] {
        guard let segment = segments.first(where: { $0.name == "__PRELINK_INFO" }) else { throw PatcherError.invalidFormat("missing __PRELINK_INFO") }
        return try plist(at: segment.address, count: segment.fileSize)["_PrelinkInfoDictionary"] as? [[String: Any]] ?? []
    }
}

extension KDKRecovery {
    struct SymbolRange {
        var entry: String
        var index: UInt8
        var section: KDKMachO.Section
    }

    func synthesizeSymbols(references: [String: [KDKReference]], known: [UInt64: [String]] = [:]) throws -> KDKLinkSymbols {
        let kernelID = "com.apple.kernel"
        guard let kernel = images[kernelID], kernel.symbols.isEmpty else {
            throw PatcherError.invalidFormat("native KDK symbol synthesis requires a stripped kernel")
        }
        let infos = try collection.prelinkInfo()
        var ranges: [SymbolRange] = []
        for id in images.keys.sorted() {
            for (index, section) in images[id]!.sections.enumerated() where section.size > 0 {
                guard let ordinal = UInt8(exactly: index + 1) else { throw PatcherError.invalidFormat("too many Mach-O sections") }
                ranges.append(.init(entry: id, index: ordinal, section: section))
            }
        }
        ranges.sort { $0.section.address < $1.section.address }
        let starts = ranges.map(\.section.address)
        func lookup(_ address: UInt64) -> SymbolRange? {
            let i = starts.upperBound(address) - 1
            return i >= 0 && ranges[i].section.contains(address) ? ranges[i] : nil
        }
        var needs: [(String, UInt64)] = []
        for (id, refs) in references {
            var seen = Set<UInt64>()
            for ref in refs where ref.kind == 2 || ref.kind == 7 {
                guard let owner = lookup(ref.target), owner.entry != id, seen.insert(ref.target).inserted else { continue }
                needs.append((id, ref.target))
            }
        }
        needs.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        let functionStarts = functions.mapValues { $0.map(\.start).sorted() }
        func positionName(_ owner: SymbolRange, _ target: UInt64) -> String {
            func trim(_ name: String) -> String {
                String(name.drop(while: { $0 == "_" }))
            }
            let section = trim(owner.section.segmentName) + "." + trim(owner.section.name)
            if owner.section.flags & 0x8000_0400 != 0 {
                let functions = functionStarts[owner.entry] ?? [], i = functions.upperBound(target) - 1
                if i >= 0, functions[i] >= owner.section.address {
                    return section + ".f\(i)" + (functions[i] == target ? "" : "_" + String(target - functions[i], radix: 16))
                }
            }
            return section + ".d" + String(target - owner.section.address, radix: 16)
        }
        var sets: [[String: Any]] = [], fallback = ""
        if let section = kernel.sections.first(where: { $0.segmentName == "__LINKINFO" && $0.name == "__symbolsets" }) {
            let plist = try collection.plist(at: section.address, count: section.size)
            sets = plist["SymbolsSets"] as? [[String: Any]] ?? []
            fallback = (plist["WeakRefFallbackSymbol"] as? [String: Any])?["SymbolName"] as? String ?? ""
        }
        var setNames: [String: [String]] = [:], privatePrefixes: [String] = [], reserved = Set<String>()
        for set in sets {
            let id = set["CFBundleIdentifier"] as? String ?? ""
            for symbol in set["Symbols"] as? [[String: Any]] ?? [] {
                let name = symbol["SymbolName"] as? String ?? "", prefix = symbol["SymbolPrefix"] as? String ?? "", alias = symbol["AliasTarget"] as? String ?? ""
                if !prefix.isEmpty {
                    if id == "com.apple.kpi.private" {
                        privatePrefixes.append(prefix)
                    }
                } else if !alias.isEmpty {
                    reserved.insert(name)
                    reserved.insert(alias)
                } else if !name.isEmpty {
                    setNames[id, default: []].append(name)
                }
            }
        }
        if !fallback.isEmpty {
            reserved.insert(fallback)
        }
        var dependencies: [String: [String]] = [:]
        for info in infos {
            if let id = info["CFBundleIdentifier"] as? String, let libs = info["OSBundleLibraries"] as? [String: Any] {
                dependencies[id] = libs.keys.sorted()
            }
        }
        var deps: [String: [String]] = [:]
        for (id, direct) in dependencies {
            var seen: Set<String> = [id], queue = direct, index = 0, closure: [String] = []
            while index < queue.count {
                let dep = queue[index]
                index += 1
                if !seen.insert(dep).inserted {
                    continue
                }
                closure.append(dep)
                queue += dependencies[dep] ?? []
            }
            deps[id] = closure.sorted()
        }
        var result = KDKLinkSymbols(), defined: [String: UInt64] = [:], namesAt: [UInt64: [String]] = [:]
        func define(_ owner: SymbolRange, _ name: String, _ target: UInt64) {
            if defined[name] != nil {
                return
            }
            defined[name] = target
            namesAt[target, default: []].append(name)
            result.exports[owner.entry, default: []].append(.init(name: name, type: 0xF, sect: owner.index, desc: 0, value: target))
        }
        var knownOwners: [String: Set<String>] = [:]
        let knownAddresses = known.keys.filter { lookup($0) != nil }.sorted()
        for address in knownAddresses {
            let owner = lookup(address)!
            for name in known[address]! {
                knownOwners[name, default: []].insert(owner.entry)
            }
        }
        let textStart = kernel.sections.first { $0.segmentName == "__TEXT_EXEC" && $0.name == "__text" }?.address ?? 0
        for address in knownAddresses {
            let owner = lookup(address)!
            for name in known[address]! where !name.isEmpty && name != "_kmod_info" {
                if reserved.contains(name), address == textStart {
                    continue
                }
                if owner.entry != kernelID, knownOwners[name, default: []].count > 1 {
                    result.exports[owner.entry, default: []].append(.init(name: name, type: 0xE, sect: owner.index, desc: 0, value: address))
                } else {
                    define(owner, name, address)
                }
            }
        }
        func knownImport(_ importer: String, _ owner: SymbolRange, _ target: UInt64) -> String? {
            for name in known[target] ?? [] where defined[name] == target {
                if owner.entry != kernelID {
                    return name
                }
                for dep in deps[importer] ?? [] {
                    if setNames[dep, default: []].contains(name) {
                        return name
                    }
                    if dep == "com.apple.kpi.private", privatePrefixes.contains(where: { name.hasPrefix($0) }) {
                        return name
                    }
                }
            }
            return nil
        }
        func unique(_ name: String, _ target: UInt64) -> String {
            var candidate = name, suffix = 1
            while let address = defined[candidate], address != target {
                candidate = "\(name).\(suffix)"
                suffix += 1
            }
            return candidate
        }
        func vtable(_ name: String) -> Bool {
            name.hasPrefix("__ZTV") || name.contains("10gMetaClassE") || name.contains("10superClassE") || name.contains("9MetaClassE")
        }
        var nextName: [String: Int] = [:]
        for (importer, target) in needs {
            let owner = lookup(target)!
            var name = knownImport(importer, owner, target)
            if name == nil, owner.entry != kernelID {
                name = unique("_kc.\(owner.entry)." + positionName(owner, target), target)
            } else if name == nil {
                if deps[importer, default: []].contains("com.apple.kpi.private"), let prefix = privatePrefixes.first {
                    name = unique(prefix + "_kc." + positionName(owner, target), target)
                } else {
                    for candidate in namesAt[target] ?? [] {
                        for dep in deps[importer] ?? [] where setNames[dep, default: []].contains(candidate) {
                            name = candidate
                        }
                    }
                    for dep in deps[importer] ?? [] {
                        let names = setNames[dep] ?? []
                        while name == nil, nextName[dep, default: 0] < names.count {
                            let candidate = names[nextName[dep, default: 0]]
                            nextName[dep, default: 0] += 1
                            if defined[candidate] == nil, !reserved.contains(candidate), !vtable(candidate) {
                                name = candidate
                            }
                        }
                    }
                }
            }
            guard let name else { result.unresolved.append((importer, target))
                continue
            }
            if let other = defined[name], other != target {
                throw PatcherError.invalidFormat("ambiguous synthesized import \(name)")
            }
            define(owner, name, target)
            result.imports[importer, default: []].append(.init(name: name, type: 1, sect: 0, desc: 0, value: target))
        }
        if let text = kernel.sections.first(where: { $0.segmentName == "__TEXT_EXEC" && $0.name == "__text" }), let textOwner = lookup(text.address) {
            for name in reserved.sorted() {
                var isAliasTarget = false, aliasAddress: UInt64 = 0
                for set in sets {
                    for symbol in set["Symbols"] as? [[String: Any]] ?? [] where symbol["AliasTarget"] as? String == name {
                        isAliasTarget = true
                        if let alias = symbol["SymbolName"] as? String, let address = defined[alias], aliasAddress == 0, lookup(address)?.entry == kernelID {
                            aliasAddress = address
                        }
                    }
                }
                if let address = defined[name], lookup(address)?.entry == kernelID {
                    continue
                }
                if aliasAddress != 0, let owner = lookup(aliasAddress) {
                    if defined[name] != nil {
                        result.exports[kernelID, default: []].append(.init(name: name, type: 0xF, sect: owner.index, desc: 0, value: aliasAddress))
                    } else {
                        define(owner, name, aliasAddress)
                    }
                } else if isAliasTarget || name == fallback {
                    if defined[name] != nil {
                        result.exports[kernelID, default: []].append(.init(name: name, type: 0xF, sect: textOwner.index, desc: 0, value: text.address))
                    } else {
                        define(textOwner, name, text.address)
                    }
                }
            }
        }
        for info in infos {
            guard let id = info["CFBundleIdentifier"] as? String, images[id] != nil,
                  let number = info["_PrelinkKmodInfo"] as? NSNumber else { continue }
            let address = number.uint64Value
            if let owner = lookup(address), owner.entry == id {
                result.exports[id, default: []].append(.init(name: "_kmod_info", type: 0xF, sect: owner.index, desc: 0, value: address))
            }
        }
        for id in result.exports.keys {
            result.exports[id]!.sort { $0.name < $1.name }
        }
        for id in result.imports.keys {
            result.imports[id]!.sort { $0.name < $1.name }
        }
        return result
    }
}
