import Foundation

@testable import thane_agent_ios

nonisolated enum IdentityTestFixture {
    static let json = Data(
        #"""
        {
          "schema_version": 1,
          "observed_at": "2026-08-30T19:22:31.123Z",
          "instance": {
            "id": "thane:ed25519:SHA256:8N6XQdQfeJrVxZ5xI3a2S9Ozb5Nss4J2t7zJ1lKfJNo",
            "name": "pocket",
            "identity_key": {
              "algorithm": "ed25519",
              "fingerprint": "SHA256:8N6XQdQfeJrVxZ5xI3a2S9Ozb5Nss4J2t7zJ1lKfJNo"
            },
            "channel_ca": {
              "algorithm": "x509-ed25519",
              "fingerprint": "SHA256:q2QHfRjP9xjV8nL4Dzg0zz1IxF5XHFM9TPrWHhsLqXQ"
            }
          },
          "core": {
            "birth": {
              "commit": {
                "algorithm": "sha1",
                "oid": "0123456789abcdef0123456789abcdef01234567"
              },
              "asserted_at": "2026-07-01T12:00:00Z",
              "time_assurance": "signed_claim",
              "anchor": "operator"
            },
            "current_commit": {
              "algorithm": "sha1",
              "oid": "fedcba9876543210fedcba9876543210fedcba98"
            },
            "head": {
              "worktree_clean": true,
              "trust_file_change_count": 1
            },
            "verification": {
              "admission": {
                "status": "verified",
                "detail": "birth satisfies the declared seed policy"
              },
              "head": {
                "status": "failed",
                "detail": "current core tree contains tracked changes"
              }
            }
          }
        }
        """#.utf8
    )

    static func evidence() throws -> ThaneIdentityEvidence {
        try ThaneIdentityCoding.decoder().decode(ThaneIdentityEvidence.self, from: json)
    }
}
