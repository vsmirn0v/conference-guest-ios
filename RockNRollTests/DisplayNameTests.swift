import XCTest
@testable import RockNRoll

@MainActor
final class DisplayNameTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: "savedDisplayName")
        UserDefaults.standard.removeObject(forKey: "savedDisplayName")
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: "savedDisplayName")
        super.tearDown()
    }

    func testNewProfileIsEmptyAndFirstJoinAsksForName() {
        let model = ConferenceModel()
        XCTAssertEqual(model.displayName, "")
        XCTAssertNil(UserDefaults.standard.string(forKey: "savedDisplayName"))
        model.invite = "https://rock.glowsoft.ru/jams/test"
        model.join()
        XCTAssertTrue(model.showingNameEditor)
        XCTAssertTrue(model.isNameRequiredForJoin)
        XCTAssertFalse(model.isJoining)
    }

    func testWhitespaceCannotConfirmAndCancelDoesNotJoin() {
        let model = ConferenceModel()
        model.invite = "https://rock.glowsoft.ru/jams/test"
        model.join()
        model.displayName = "  \n"
        model.confirmNameEntry()
        XCTAssertTrue(model.showingNameEditor)
        model.showingNameEditor = false
        model.nameEditorDismissed()
        XCTAssertFalse(model.isNameRequiredForJoin)
        XCTAssertFalse(model.isJoining)
        XCTAssertEqual(model.invite, "https://rock.glowsoft.ru/jams/test")
    }

    func testEnteredNameSurvivesModelRecreationAndIsEditable() {
        let first = ConferenceModel()
        first.displayName = "Ani"
        let second = ConferenceModel()
        XCTAssertEqual(second.displayName, "Ani")
        second.displayName = "Aram"
        XCTAssertEqual(ConferenceModel().displayName, "Aram")
    }

    func testNativeLinkWaitsForNameAndKeepsLatestInvitation() {
        let model = ConferenceModel()
        model.receive(url: URL(string: "jcp://jazz?code=first@meeting.example.test&psw=one")!)
        XCTAssertTrue(model.showingNameEditor)
        model.displayName = " Ani "
        model.receive(url: URL(string: "jcp://jazz?code=second@meeting.example.test&psw=two")!)
        XCTAssertTrue(model.invite.contains("second"))
        XCTAssertTrue(model.showingNameEditor)
        model.confirmNameEntry()
        XCTAssertEqual(model.displayName, "Ani")
        XCTAssertFalse(model.showingNameEditor)
        model.nameEditorDismissed()
        XCTAssertFalse(model.isNameRequiredForJoin)
        // No configured view in this unit test: resumption reached the next join gate.
        XCTAssertEqual(model.status, "Jam view is unavailable.")
    }
}
