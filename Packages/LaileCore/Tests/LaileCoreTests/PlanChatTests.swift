import Foundation
import Testing
@testable import LaileCore

@Suite struct PlanChatTests {
    @Test(arguments: ["I want a new program", "can you make me a plan?", "my goals have changed", "Change my goals please",
                      "build me a program for my back", "I'd like a harder program"])
    func asksForANewPlan(_ text: String) {
        #expect(PlanChat.wantsNewPlan(text), "\(text)")
    }

    @Test(arguments: ["how am I doing?", "my knee hurts", "I don't want a new program", "what's in my program"])
    func ordinaryChatIsNotPlanning(_ text: String) {
        #expect(!PlanChat.wantsNewPlan(text), "\(text)")
    }

    @Test func fiveQuestionsThenBuild() throws {
        var message = PlanChat.start(at: Date(), supervised: false, clinician: nil)
        #expect(PlanChat.isPlanQuestion(message))
        // Typed in their own words, tapped, typed, tapped, typed.
        let turns: [(String?, String?)] = [(nil, "I want to get stronger and loosen up"), ("min:15", nil), (nil, "I go to the gym sometimes"),
                                           ("area:wrists", nil), (nil, "no, nothing like that")]
        var built: PlanChat.Answers?
        for (actionId, text) in turns {
            switch PlanChat.answer(dedupeKey: try #require(message.dedupeKey), actionId: actionId, text: text) {
            case .ask(let step, let answers, let lead)?:
                #expect(lead == nil, "every answer here is clear")
                message = PlanChat.question(step, answers: answers, at: Date())
            case .build(let answers)?:
                built = answers
            case nil:
                Issue.record("unreadable key")
            }
        }
        let answers = try #require(built)
        #expect(answers.goals == [.getStronger, .flexibility])
        #expect(answers.minutes == 15)
        #expect(answers.experience == .some)
        #expect(answers.areas == [.wrists])
        #expect(answers.safetyConcern == false)
        let profile = answers.profile(base: nil, at: Date())
        #expect(profile.precautions.noWristLoading)
        #expect(profile.notes.contains("get stronger"))
    }

    @Test func unclearAnswerAsksAgainKeepingProgress() throws {
        let first = PlanChat.start(at: Date(), supervised: true, clinician: "Dr Nair")
        #expect(first.text.contains("Dr Nair"))
        guard case .ask(.minutes, let answers, _)? = PlanChat.answer(dedupeKey: try #require(first.dedupeKey), actionId: "goal:moveMore", text: nil) else {
            Issue.record("expected the minutes question"); return
        }
        let minutes = PlanChat.question(.minutes, answers: answers, at: Date())
        guard case .ask(.minutes, let kept, let lead)? = PlanChat.answer(dedupeKey: try #require(minutes.dedupeKey), actionId: nil, text: "hmm not sure") else {
            Issue.record("expected the same question again"); return
        }
        #expect(lead != nil)
        #expect(kept.goals == [.moveMore])
    }
}
