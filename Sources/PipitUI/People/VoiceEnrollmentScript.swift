import Foundation

/// What a person reads to teach Pipit their voice.
///
/// The sentences are the Harvard sentences, standardised as IEEE 297-1969 from
/// work at Harvard's Psycho-Acoustic Laboratory. They are phonetically
/// balanced: each phoneme appears about as often as it does in English, so
/// twenty of them cover the sounds a voice makes without anybody choosing which
/// sounds matter. They are also public domain.
///
/// The prompts after them are not read. A profile built only from reading is
/// built from a speaking style nobody uses in a meeting, and the profile is
/// matched against meetings.
public enum VoiceEnrollmentScript {
    /// One list of ten, as the standard groups them.
    public struct List: Identifiable, Sendable {
        public let number: Int
        public let sentences: [String]

        public var id: Int { number }
    }

    /// Lists 1 to 6 of the standard, which is more than a fast reader gets
    /// through before the meter is full. Another list appears each time the
    /// reader reaches the end of what is on screen.
    public static let lists: [List] = [
        List(number: 1, sentences: [
            "The birch canoe slid on the smooth planks.",
            "Glue the sheet to the dark blue background.",
            "It's easy to tell the depth of a well.",
            "These days a chicken leg is a rare dish.",
            "Rice is often served in round bowls.",
            "The juice of lemons makes fine punch.",
            "The box was thrown beside the parked truck.",
            "The hogs were fed chopped corn and garbage.",
            "Four hours of steady work faced us.",
            "A large size in stockings is hard to sell.",
        ]),
        List(number: 2, sentences: [
            "The boy was there when the sun rose.",
            "A rod is used to catch pink salmon.",
            "The source of the huge river is the clear spring.",
            "Kick the ball straight and follow through.",
            "Help the woman get back to her feet.",
            "A pot of tea helps to pass the evening.",
            "Smoky fires lack flame and heat.",
            "The soft cushion broke the man's fall.",
            "The salt breeze came across from the sea.",
            "The girl at the booth sold fifty bonds.",
        ]),
        List(number: 3, sentences: [
            "The small pup gnawed a hole in the sock.",
            "The fish twisted and turned on the bent hook.",
            "Press the pants and sew a button on the vest.",
            "The swan dive was far short of perfect.",
            "The beauty of the view stunned the young boy.",
            "Two blue fish swam in the tank.",
            "Her purse was full of useless trash.",
            "The colt reared and threw the tall rider.",
            "It snowed, rained, and hailed the same morning.",
            "Read verse out loud for pleasure.",
        ]),
    ]

    /// Said rather than read, once the sentences are done.
    ///
    /// Reading aloud and talking are different speaking styles, and a profile
    /// enrolled on one is matched against the other every time this person
    /// joins a call. Open questions, because a question with a short answer
    /// produces a short answer.
    public static let prompts = [
        "In your own words, what are you working on this week?",
        "Describe the room you are sitting in.",
        "What is the last thing you watched or read, and was it any good?",
    ]

    /// How many sentences are on screen to begin with.
    public static var allSentences: [String] { lists.flatMap(\.sentences) }
}
