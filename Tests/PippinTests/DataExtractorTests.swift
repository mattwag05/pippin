@testable import PippinLib
import XCTest

private struct FakeExtractAIProvider: AIProvider {
    let response: String
    func complete(prompt _: String, system _: String) throws -> String {
        response
    }
}

private struct FailingExtractAIProvider: AIProvider {
    func complete(prompt _: String, system _: String) throws -> String {
        throw AIProviderError.networkError("simulated")
    }
}

final class DataExtractorTests: XCTestCase {
    // MARK: - 1. Valid JSON

    func testExtractParsesValidJSON() throws {
        let json = """
        {
          "dates": [{"text": "March 15", "isoDate": "2026-03-15", "context": "Meeting on March 15"}],
          "amounts": [{"text": "$50.00", "value": 50.0, "currency": "USD", "context": "Pay $50.00 by Friday"}],
          "trackingNumbers": ["1Z999AA10123456784"],
          "actionItems": ["Reply by Friday", "Book the flight"],
          "contacts": [{"name": "Jane Doe", "email": "jane@example.com", "phone": "555-1234"}],
          "urls": ["https://example.com"]
        }
        """
        let provider = FakeExtractAIProvider(response: json)
        let result = try DataExtractor.extract(messageBody: "body", subject: "Test", provider: provider)

        XCTAssertEqual(result.dates.count, 1)
        XCTAssertEqual(result.dates[0].text, "March 15")
        XCTAssertEqual(result.dates[0].isoDate, "2026-03-15")
        XCTAssertEqual(result.dates[0].context, "Meeting on March 15")

        XCTAssertEqual(result.amounts.count, 1)
        XCTAssertEqual(result.amounts[0].text, "$50.00")
        XCTAssertEqual(result.amounts[0].value, 50.0)
        XCTAssertEqual(result.amounts[0].currency, "USD")
        XCTAssertEqual(result.amounts[0].context, "Pay $50.00 by Friday")

        XCTAssertEqual(result.trackingNumbers, ["1Z999AA10123456784"])
        XCTAssertEqual(result.actionItems, ["Reply by Friday", "Book the flight"])

        XCTAssertEqual(result.contacts.count, 1)
        XCTAssertEqual(result.contacts[0].name, "Jane Doe")
        XCTAssertEqual(result.contacts[0].email, "jane@example.com")
        XCTAssertEqual(result.contacts[0].phone, "555-1234")

        XCTAssertEqual(result.urls, ["https://example.com"])
    }

    // MARK: - 2. Empty arrays

    func testExtractHandlesEmptyArrays() throws {
        let json = """
        {
          "dates": [],
          "amounts": [],
          "trackingNumbers": [],
          "actionItems": [],
          "contacts": [],
          "urls": []
        }
        """
        let provider = FakeExtractAIProvider(response: json)
        let result = try DataExtractor.extract(messageBody: "body", subject: "Empty", provider: provider)
        XCTAssertTrue(result.dates.isEmpty)
        XCTAssertTrue(result.amounts.isEmpty)
        XCTAssertTrue(result.trackingNumbers.isEmpty)
        XCTAssertTrue(result.actionItems.isEmpty)
        XCTAssertTrue(result.contacts.isEmpty)
        XCTAssertTrue(result.urls.isEmpty)
    }

    // MARK: - 3. Markdown fence stripping

    func testExtractStripsMarkdownFences() throws {
        let json = """
        ```json
        {
          "dates": [],
          "amounts": [],
          "trackingNumbers": [],
          "actionItems": ["Check inbox"],
          "contacts": [],
          "urls": []
        }
        ```
        """
        let provider = FakeExtractAIProvider(response: json)
        let result = try DataExtractor.extract(messageBody: "body", subject: "Fenced", provider: provider)
        XCTAssertEqual(result.actionItems, ["Check inbox"])
    }

    // MARK: - 4. Throws malformedAIResponse on bad JSON

    func testExtractThrowsMalformedAIResponseOnBadJSON() throws {
        let provider = FakeExtractAIProvider(response: "Sorry, I cannot help with that")
        XCTAssertThrowsError(
            try DataExtractor.extract(messageBody: "body", subject: "Bad", provider: provider)
        ) { error in
            guard case MailAIError.malformedAIResponse = error else {
                XCTFail("Expected MailAIError.malformedAIResponse, got \(error)")
                return
            }
        }
    }

    // MARK: - 5. ExtractionResult codable round-trip

    func testExtractResultCodableRoundTrip() throws {
        let original = ExtractionResult(
            dates: [ExtractedDate(text: "Monday", isoDate: "2026-03-23", context: "See you Monday")],
            amounts: [ExtractedAmount(text: "$10", value: 10.0, currency: "USD", context: "Pay $10")],
            trackingNumbers: ["TRACK123"],
            actionItems: ["Do the thing"],
            contacts: [ExtractedContact(name: "Bob", email: "bob@test.com", phone: nil)],
            urls: ["https://bob.com"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExtractionResult.self, from: data)

        XCTAssertEqual(decoded.dates.count, 1)
        XCTAssertEqual(decoded.dates[0].text, "Monday")
        XCTAssertEqual(decoded.dates[0].isoDate, "2026-03-23")
        XCTAssertEqual(decoded.amounts[0].value, 10.0)
        XCTAssertEqual(decoded.amounts[0].currency, "USD")
        XCTAssertEqual(decoded.trackingNumbers, ["TRACK123"])
        XCTAssertEqual(decoded.actionItems, ["Do the thing"])
        XCTAssertEqual(decoded.contacts[0].name, "Bob")
        XCTAssertNil(decoded.contacts[0].phone)
        XCTAssertEqual(decoded.urls, ["https://bob.com"])
    }

    // MARK: - 6. ExtractedDate with nil isoDate

    func testExtractedDateCodable() throws {
        let date = ExtractedDate(text: "next week", isoDate: nil, context: "arrives next week")
        let data = try JSONEncoder().encode(date)
        let decoded = try JSONDecoder().decode(ExtractedDate.self, from: data)
        XCTAssertEqual(decoded.text, "next week")
        XCTAssertNil(decoded.isoDate)
        XCTAssertEqual(decoded.context, "arrives next week")
    }

    // MARK: - 7. ExtractedAmount with nil value and currency

    func testExtractedAmountCodable() throws {
        let amount = ExtractedAmount(text: "some money", value: nil, currency: nil, context: "pay some money")
        let data = try JSONEncoder().encode(amount)
        let decoded = try JSONDecoder().decode(ExtractedAmount.self, from: data)
        XCTAssertEqual(decoded.text, "some money")
        XCTAssertNil(decoded.value)
        XCTAssertNil(decoded.currency)
        XCTAssertEqual(decoded.context, "pay some money")
    }

    // MARK: - 8. ExtractedContact with all-nil fields

    func testExtractedContactCodable() throws {
        let contact = ExtractedContact(name: nil, email: nil, phone: nil)
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(ExtractedContact.self, from: data)
        XCTAssertNil(decoded.name)
        XCTAssertNil(decoded.email)
        XCTAssertNil(decoded.phone)
    }

    // MARK: - 9. Malformed response includes raw output

    func testExtractMalformedResponseIncludesRawOutput() throws {
        let rawResponse = "This is definitely not JSON at all."
        let provider = FakeExtractAIProvider(response: rawResponse)
        do {
            _ = try DataExtractor.extract(messageBody: "body", subject: "Test", provider: provider)
            XCTFail("Expected throw")
        } catch let MailAIError.malformedAIResponse(msg) {
            XCTAssertEqual(msg, rawResponse, "Raw AI response should be preserved in the error")
        } catch {
            XCTFail("Expected MailAIError.malformedAIResponse, got \(error)")
        }
    }
}
