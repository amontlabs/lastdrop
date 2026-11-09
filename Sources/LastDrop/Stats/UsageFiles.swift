import Darwin
import Foundation

/// A file the index might read.
struct UsageFile: Sendable {
    enum Kind: Int32, Sendable { case claude, codex, antigravity }
    var path: String
    var kind: Kind
    var account: String
    var size: Int64
    var modified: Int64
    var born: Int64
    /// A conversation forked from another: its lines from before this were copies, which the original counts.
    var forkedAt: Date?
}

enum UsageFiles {
    /// Where one account's transcripts live.
    struct Root: Sendable {
        var path: String
        var kind: UsageFile.Kind
        var account: String
    }

    /// Every place on this Mac with transcripts. An account's folder outlives its removal from lastdrop, and its
    /// past use still counts. Runs on every account use `~/.claude/projects` (the ledger says which account),
    /// and an account's own real `projects` holds runs from before that, counted as that account's.
    static func roots(home: String = NSHomeDirectory()) -> [Root] {
        var roots = [Root(path: home + "/.claude/projects", kind: .claude, account: "claude.main"),
                     Root(path: home + "/.codex/sessions", kind: .codex, account: "codex.main"),
                     Root(path: home + "/.codex/archived_sessions", kind: .codex, account: "codex.main"),
                     Root(path: home + "/.gemini/antigravity-cli/brain", kind: .antigravity, account: "antigravity.main")]
        for name in folders(home + "/.claude-accounts") {
            let dir = "\(home)/.claude-accounts/\(name)"
            if isRealDirectory(dir + "/projects") {
                roots.append(Root(path: dir + "/projects", kind: .claude, account: "claude.\(name)"))
            }
        }
        for name in folders(home + "/.codex-accounts") {
            roots.append(Root(path: "\(home)/.codex-accounts/\(name)/sessions", kind: .codex, account: "codex.\(name)"))
        }
        // Never walk one real folder twice: a link and the folder it points at are the same files.
        var seen = Set<String>(), unique: [Root] = []
        for root in roots where seen.insert(URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path).inserted {
            unique.append(root)
        }
        return unique
    }

    private static func folders(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// A real folder of the account's own, not a link to the shared one (a link that leads nowhere isn't one).
    private static func isRealDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { return false }
        return true
    }

    /// The transcripts under `root`. One `getattrlistbulk` call returns a folder's sizes and dates together, where
    /// `lstat` would be a call per file: that's what lets a scan with nothing new run every time the panel opens.
    /// `ledger` is the session ledger read once for the whole scan; it says which account each shared
    /// conversation ran on.
    static func list(_ root: Root, ledger: [String: SessionLedger.Session] = [:], into files: inout [UsageFile]) {
        if root.kind == .antigravity {
            // Each conversation's folder holds whatever the agent made; its transcript is always in one place.
            for name in folders(root.path) {
                let path = "\(root.path)/\(name)/.system_generated/logs/transcript.jsonl"
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                files.append(UsageFile(path: path, kind: root.kind, account: root.account, size: info.st_size,
                                       modified: Int64(info.st_mtimespec.tv_sec), born: Int64(info.st_birthtimespec.tv_sec)))
            }
        } else {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 18, alignment: 8)
            defer { buffer.deallocate() }
            let start = files.count
            walk(root.path, depth: 0, root: root, buffer: buffer, into: &files)
            attribute(root, ledger: ledger, into: &files, from: start)
        }
    }

    /// A claude transcript's session id: `<project>/<session>.jsonl` names it in the file, and a file inside
    /// `<project>/<session>/` (the side folder with the subagents) belongs to that session's folder.
    static func sessionID(of path: String, under root: String) -> String? {
        let rest = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        let parts = rest.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let second = parts[1]
        return second.hasSuffix(".jsonl") ? String(second.dropLast(".jsonl".count)) : String(second)
    }

    /// Conversations share one folder now, so the ledger says which account each session ran on, and which of
    /// them were forks. Sessions the ledger doesn't know, and folders kept aside at sharing, stay with the
    /// folder's own account.
    private static func attribute(_ root: Root, ledger: [String: SessionLedger.Session], into files: inout [UsageFile], from start: Int) {
        guard root.kind == .claude else { return }
        for i in start..<files.count {
            guard let id = sessionID(of: files[i].path, under: root.path), let noted = ledger[id] else { continue }
            files[i].forkedAt = noted.forkedAt
            if root.account == "claude.main" { files[i].account = "claude." + noted.account }   // the shared folder
        }
    }

    private static func walk(_ path: String, depth: Int, root: Root, buffer: UnsafeMutableRawBufferPointer, into files: inout [UsageFile]) {
        guard depth < 8 else { return }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
        attributes.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        var folders: [String] = []
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer.baseAddress!, buffer.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
            guard count > 0 else { break }
            var entry = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                // length, returned attributes, then the attributes in bit order.
                let returned = entry.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                var field = entry + 4 + MemoryLayout<attribute_set_t>.size
                let nameStart = field + Int(field.loadUnaligned(as: attrreference_t.self).attr_dataoffset)
                let name = nameStart.assumingMemoryBound(to: CChar.self)
                field += MemoryLayout<attrreference_t>.size
                let type = field.loadUnaligned(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size
                if type == VDIR.rawValue {
                    if name[0] != CChar(UInt8(ascii: ".")), strcmp(name, "tool-results") != 0 { folders.append(String(cString: name)) }
                } else if type == VREG.rawValue, returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0, hasSuffix(name, ".jsonl") {
                    let born = field.loadUnaligned(as: timespec.self)
                    let modified = (field + MemoryLayout<timespec>.size).loadUnaligned(as: timespec.self)
                    let size = (field + 2 * MemoryLayout<timespec>.size).loadUnaligned(as: off_t.self)
                    files.append(UsageFile(path: path + "/" + String(cString: name), kind: root.kind, account: root.account, size: size,
                                           modified: Int64(modified.tv_sec), born: Int64(born.tv_sec)))
                }
                entry += length
            }
        }
        for folder in folders { walk(path + "/" + folder, depth: depth + 1, root: root, buffer: buffer, into: &files) }
    }

    private static func hasSuffix(_ name: UnsafePointer<CChar>, _ suffix: StaticString) -> Bool {
        let length = strlen(name), count = suffix.utf8CodeUnitCount
        return length >= count && memcmp(name + (length - count), suffix.utf8Start, count) == 0
    }

    /// Calls `line` with each complete line from `offset` on, and returns the offset after the last one, so a
    /// line still being written is read next time; -1 if the file couldn't be read. Reads into one reused buffer:
    /// no line outlives its call.
    static func lines(path: String, from offset: Int64, _ line: (Bytes) -> Void) -> Int64 {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)   // Reading gigabytes once shouldn't push the user's own work out of memory.
        var capacity = 1 << 20
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 4096)
        defer { buffer.deallocate() }
        var position = offset        // of the next byte to read
        var end = offset             // after the last complete line
        var held = 0                 // bytes of an unfinished line at the buffer's start
        while true {
            let count = pread(fd, buffer + held, capacity - held, position)
            guard count >= 0 else { return -1 }
            guard count > 0 else { break }
            position += Int64(count)
            let filled = held + count
            let bytes = UnsafePointer(buffer.assumingMemoryBound(to: UInt8.self))
            var start = 0
            while start < filled, let hit = memchr(bytes + start, 0x0A, filled - start) {
                let stop = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - bytes
                line(Bytes(start: bytes + start, count: stop - start))
                start = stop + 1
            }
            end += Int64(start)
            held = filled - start
            if start > 0 {
                memmove(buffer, buffer + start, held)
            } else if held == capacity {
                // One line longer than the buffer.
                capacity *= 2
                let larger = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 4096)
                memcpy(larger, buffer, held)
                buffer.deallocate()
                buffer = larger
            }
        }
        return end
    }
}
