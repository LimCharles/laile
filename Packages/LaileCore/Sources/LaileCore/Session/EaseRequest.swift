import Foundation

/// "Make it easier", "I can't bend that far": mid-session, the person asks for a smaller target.
/// Matched on whole phrases so "it's not too hard" doesn't count; anything that sounds like pain
/// goes to the symptom rules instead.
public enum EaseRequest {
    static let phrases = [
        "make it easier", "make this easier", "make it a bit easier", "make it a little easier", "easier please",
        "too hard", "too difficult", "too much for me", "be kinder", "go easier", "go easy on me",
        "can't reach", "cant reach", "cannot reach", "can't get there", "cant get there", "can't get that far",
        "can't bend that far", "can't bend it that far", "cant bend that far", "can't go that far", "cant go that far",
        "can't lift it that high", "can't lift that high", "can't lift it", "cant lift it", "can't raise it",
        "can't straighten it", "cant straighten it", "can't straighten that far", "can't straighten my knee",
        "can't hold it", "can't hold that long", "cant hold it",
        "can't do that many", "can't do any more", "can't do one more",
    ]
    static let negators: Set<String> = ["not", "isn't", "isnt", "never", "wasn't", "wasnt"]

    public static func detect(_ text: String) -> Bool {
        let tokens = TextNormalizer.tokens(text)
        for phrase in phrases {
            guard let range = TextNormalizer.range(ofPhrase: phrase, in: tokens) else { continue }
            if range.lowerBound > 0, negators.contains(tokens[range.lowerBound - 1]) { continue }
            let category = UtteranceClassifier.classify(text).category
            return category != .pain && category != .wrongSensation && category != .redFlag
        }
        return false
    }
}
