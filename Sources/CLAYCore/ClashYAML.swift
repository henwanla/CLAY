import Foundation
#if compiler(>=6)
internal import CYaml
#else
@_implementationOnly import CYaml
#endif

// Consume syntax events directly; we never expand aliases or construct the rest of the configuration.
enum ClashYAML {
    static func read(_ text: String, profile: (Any) throws -> NodeProfile) throws -> ImportResult? {
        try Data(text.utf8).withUnsafeBytes { input in
            let cursor = try Cursor(input)
            guard try cursor.next().type == YAML_STREAM_START_EVENT,
                  try cursor.next().type == YAML_DOCUMENT_START_EVENT else { throw ImportError.malformed }
            let root = try cursor.next()
            guard root.type == YAML_MAPPING_START_EVENT else { return nil }
            guard !root.hasProperties else { throw ImportError.malformed }

            var found = false
            var result = ImportResult()
            while true {
                let key = try cursor.next(readScalar: true)
                if key.type == YAML_MAPPING_END_EVENT { break }
                try cursor.skip(key, depth: 2)
                let value = try cursor.next()
                if key.text == "proxies" {
                    guard !found, !key.hasProperties, value.type == YAML_SEQUENCE_START_EVENT,
                          !value.hasProperties else { throw ImportError.malformed }
                    found = true
                    while true {
                        let atLimit = result.profiles.count >= ImportResult.maxProfiles
                        let node = try cursor.next(readScalar: !atLimit)
                        if node.type == YAML_SEQUENCE_END_EVENT { break }
                        if atLimit {
                            try cursor.skip(node, depth: 3)
                            result.issues[.unsupportedOption, default: 0] += 1
                        } else {
                            let value = try cursor.materialize(node, field: nil, depth: 3)
                            result.add {
                                guard let value else { throw ImportError.unsupportedOption }
                                return try profile(value)
                            }
                        }
                    }
                } else {
                    try cursor.skip(value, depth: 2)
                }
            }
            guard found, try cursor.next().type == YAML_DOCUMENT_END_EVENT,
                  try cursor.next().type == YAML_STREAM_END_EVENT else { throw ImportError.malformed }
            if result.profiles.isEmpty && result.issues.isEmpty { result.issues[.malformed] = 1 }
            return result
        }
    }

    private struct Event {
        let type: yaml_event_type_t
        var text: String?
        var plain = false
        var hasProperties = false

        var beginsCollection: Bool { type == YAML_MAPPING_START_EVENT || type == YAML_SEQUENCE_START_EVENT }
        var endsCollection: Bool { type == YAML_MAPPING_END_EVENT || type == YAML_SEQUENCE_END_EVENT }
    }

    private final class Cursor {
        private var parser = yaml_parser_t()
        private var eventCount = 0
        private static let maxEvents = 200_000
        private static let maxDepth = 64
        private static let booleanFields: Set<String> = ["udp", "tls", "skip-cert-verify", "support-x25519mlkem768",
                                                         "disable-sni", "reduce-rtt"]

        init(_ input: UnsafeRawBufferPointer) throws {
            guard let start = input.bindMemory(to: UInt8.self).baseAddress,
                  yaml_parser_initialize(&parser) == 1 else { throw ImportError.malformed }
            yaml_parser_set_encoding(&parser, YAML_UTF8_ENCODING)
            yaml_parser_set_input_string(&parser, start, input.count)
        }

        deinit { yaml_parser_delete(&parser) }

        func next(readScalar: Bool = false) throws -> Event {
            guard eventCount < Self.maxEvents else { throw ImportError.malformed }
            eventCount += 1
            var raw = yaml_event_t()
            guard yaml_parser_parse(&parser, &raw) == 1 else { throw ImportError.malformed }
            defer { yaml_event_delete(&raw) }
            var event = Event(type: raw.type)
            switch raw.type {
            case YAML_SCALAR_EVENT:
                let scalar = raw.data.scalar
                event.hasProperties = scalar.anchor != nil || scalar.tag != nil
                event.plain = scalar.style == YAML_PLAIN_SCALAR_STYLE
                if readScalar {
                    event.text = String(decoding: UnsafeBufferPointer(start: scalar.value, count: scalar.length), as: UTF8.self)
                }
            case YAML_MAPPING_START_EVENT:
                event.hasProperties = raw.data.mapping_start.anchor != nil || raw.data.mapping_start.tag != nil
            case YAML_SEQUENCE_START_EVENT:
                event.hasProperties = raw.data.sequence_start.anchor != nil || raw.data.sequence_start.tag != nil
            case YAML_ALIAS_EVENT:
                event.hasProperties = true
            default: break
            }
            return event
        }

        func skip(_ event: Event, depth: Int) throws {
            guard depth <= Self.maxDepth else { throw ImportError.malformed }
            if event.type == YAML_SCALAR_EVENT || event.type == YAML_ALIAS_EVENT { return }
            guard event.beginsCollection else { throw ImportError.malformed }

            var open = 1
            while open > 0 {
                let nested = try next()
                if nested.beginsCollection {
                    open += 1
                    guard depth + open - 1 <= Self.maxDepth else { throw ImportError.malformed }
                } else if nested.endsCollection {
                    open -= 1
                } else if nested.type != YAML_SCALAR_EVENT, nested.type != YAML_ALIAS_EVENT {
                    throw ImportError.malformed
                }
            }
        }

        func materialize(_ event: Event, field: String?, depth: Int) throws -> Any? {
            guard depth <= Self.maxDepth else { throw ImportError.malformed }
            if event.hasProperties {
                try skip(event, depth: depth)
                return nil
            }
            if let value = event.text {
                if event.plain {
                    let keyword = value.lowercased()
                    if value.isEmpty || keyword == "null" || value == "~" { return NSNull() }
                    if let field, Self.booleanFields.contains(field) {
                        if keyword == "true" { return true }
                        if keyword == "false" { return false }
                    }
                }
                // Preserve numeric-looking strings, e.g. a REALITY short-id with leading zeros.
                return value
            }
            switch event.type {
            case YAML_MAPPING_START_EVENT:
                var object: [String: Any] = [:]
                var supported = true
                while true {
                    let key = try next(readScalar: supported)
                    if key.type == YAML_MAPPING_END_EVENT { return supported ? object : nil }
                    try skip(key, depth: depth + 1)
                    let value = try next(readScalar: supported)
                    if supported, let field = key.text, !key.hasProperties, field != "<<", object[field] == nil {
                        if let literal = try materialize(value, field: field, depth: depth + 1) {
                            object[field] = literal
                        } else { supported = false }
                    } else {
                        try skip(value, depth: depth + 1)
                        supported = false
                    }
                }
            case YAML_SEQUENCE_START_EVENT:
                var array: [Any] = []
                var supported = true
                while true {
                    let item = try next(readScalar: supported)
                    if item.type == YAML_SEQUENCE_END_EVENT { return supported ? array : nil }
                    if !supported {
                        try skip(item, depth: depth + 1)
                    } else if let literal = try materialize(item, field: nil, depth: depth + 1) {
                        array.append(literal)
                    } else { supported = false }
                }
            default:
                throw ImportError.malformed
            }
        }
    }
}
