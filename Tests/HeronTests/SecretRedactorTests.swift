import XCTest
@testable import Heron

final class SecretRedactorTests: XCTestCase {
    private func assertRedacted(_ input: String, keeps: [String] = [], drops: [String], file: StaticString = #filePath, line: UInt = #line) {
        let result = SecretRedactor.redacting(input)
        XCTAssertTrue(result.didRedact, "expected a redaction in: \(input)", file: file, line: line)
        for fragment in drops {
            XCTAssertFalse(result.text.contains(fragment), "leaked \(fragment) in: \(result.text)", file: file, line: line)
        }
        for fragment in keeps {
            XCTAssertTrue(result.text.contains(fragment), "lost context \(fragment) in: \(result.text)", file: file, line: line)
        }
    }

    func testEnvFileAssignmentsKeepTheirNamesAndLoseTheirValues() {
        // The exact case that motivated this: `cat .env` used to land verbatim in the session
        // file and get replayed to the provider on every later message.
        assertRedacted(
            "DATABASE_PASSWORD=hunter2supersecret\nAPI_KEY=abcdef123456\nDEBUG=true",
            keeps: ["DATABASE_PASSWORD=", "API_KEY=", "DEBUG=true"],
            drops: ["hunter2supersecret", "abcdef123456"]
        )
    }

    func testNoFragmentOfTheKeySurvives() {
        // Caught in a live run: `sk_(live|test)_` captured its own alternative and the template
        // wrote it back out as `STRIPE_KEY=live[redacted api key]`. Alternations inside a
        // pattern have to be non-capturing — group 1 is reserved for the prefix to keep.
        let result = SecretRedactor.redacting("STRIPE_KEY=sk_live_AAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(result.text, "STRIPE_KEY=[redacted api key]")
        XCTAssertFalse(SecretRedactor.redacted("id AKIAIOSFODNN7EXAMPLE").contains("AKIA"))
    }

    func testRedactionShapes() {
        // Provider keys, bearer tokens, connection-string passwords and PEM blocks: each loses
        // its credential and keeps the context around it.
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
        -----END RSA PRIVATE KEY-----
        """
        let cases: [(input: String, keeps: [String], drops: [String])] = [
            ("export ANTHROPIC_KEY=sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA", [], ["sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA"]),
            ("token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", [], ["ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]),
            ("aws_access_key_id AKIAIOSFODNN7EXAMPLE", [], ["AKIAIOSFODNN7EXAMPLE"]),
            ("slack xoxb-123456789012-abcdefghijkl", [], ["xoxb-123456789012-abcdefghijkl"]),
            ("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.QQQQQQQQQQQQ", ["Authorization:"], ["eyJzdWIiOiIxIn0"]),
            ("postgres://appuser:s3cr3tpassword@db.internal:5432/app", ["postgres://appuser:", "@db.internal:5432/app"], ["s3cr3tpassword"]),
            (pem, [], ["MIIEowIBAAKCAQEA", "BEGIN RSA PRIVATE KEY"]),
        ]
        for row in cases {
            assertRedacted(row.input, keeps: row.keeps, drops: row.drops)
        }
    }

    func testBenignOutputIsLeftExactlyAlone() {
        // False positives are their own kind of damage: a redacted build log or diff is a tool
        // result the model can no longer reason about. And `TOKEN=x` in a test fixture or a doc
        // example isn't a credential; blanking it would make the output harder to read for no
        // safety gain.
        let samples = [
            "Compiling 42 files\nBuild succeeded in 12.4s",
            "func loadKey() -> String? { keychain.read(\"anthropic\") }",
            "total 24\ndrwxr-xr-x  5 user  staff  160 Aug 25 10:00 src",
            "PATH=/usr/bin:/bin\nHOME=/Users/someone",
            "TOKEN=abc",
        ]
        for sample in samples {
            let result = SecretRedactor.redacting(sample)
            XCTAssertFalse(result.didRedact, "unexpected redaction in: \(sample) → \(result.text)")
            XCTAssertEqual(result.text, sample)
        }
    }
}
