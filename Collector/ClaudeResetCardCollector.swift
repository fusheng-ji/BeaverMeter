import Foundation

enum ClaudeResetCardCollector {
    private struct Response: Decodable {
        let cedarEmber: Status?
        enum CodingKeys: String, CodingKey { case cedarEmber = "cedar_ember" }
    }

    private struct Status: Decodable {
        let eligible: Bool
        let grants: [Grant]?
    }

    private struct Grant: Decodable {
        let batch: ResetCardBatch?

        enum CodingKeys: String, CodingKey {
            case id, paused
            case count = "resets_left"
            case startsAt = "starts_at"
            case expiresAt = "ends_at"
            case requiresLimit = "use_requires_limit"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = try? c.decode(String.self, forKey: .id), !id.isEmpty,
                  let count = try? c.decode(Int.self, forKey: .count), count >= 0 else {
                batch = nil
                return
            }
            batch = ResetCardBatch(
                id: CodexUsageSupport.hash(id), count: count,
                startsAt: CollectorSupport.parseISODate(try? c.decode(String.self, forKey: .startsAt)),
                expiresAt: CollectorSupport.parseISODate(try? c.decode(String.self, forKey: .expiresAt)),
                paused: (try? c.decode(Bool.self, forKey: .paused)) ?? false,
                requiresLimit: (try? c.decode(Bool.self, forKey: .requiresLimit)) ?? false
            )
        }
    }

    static func inventory(from data: Data, now: Date) throws -> ResetCardInventory? {
        guard let status = try JSONDecoder().decode(Response.self, from: data).cedarEmber,
              status.eligible, let grants = status.grants else { return nil }
        guard grants.allSatisfy({ $0.batch != nil }) else { throw URLError(.cannotParseResponse) }
        var seen: Set<String> = []
        let batches = grants.compactMap(\.batch).filter {
            seen.insert($0.id).inserted && $0.count > 0 && ($0.expiresAt.map { $0 > now } ?? true)
        }
        let count = try batches.reduce(0) { try CodexUsageSupport.adding($0, $1.count) }
        return ResetCardInventory(availableCount: count, observedAt: now, batches: batches)
    }

}
