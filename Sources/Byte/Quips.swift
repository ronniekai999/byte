import Foundation

enum Quips {
    static let lines = [
        "Rawr! (That's hello in dino.)",
        "Need a hand? Mine are tiny, but I'm all in.",
        "Thinking… stomp… stomp… stomp…",
        "Stomping through your context window.",
        "Digging up the answer — I'm good at fossils.",
        "Top of the notch, top of the food chain.",
        "Two tiny arms, one big brain.",
        "Don't worry, I won't byte. Much.",
        "Small arms. Huge enthusiasm.",
        "Stuck? Let's dig in together.",
        "Stomp. That was a thought.",
        "Keeping your notch from going extinct.",
        "Prehistoric, but I keep up just fine.",
        "T-rex-cellent to see you.",
        "Let's make today rawr-some."
    ]

    static func random() -> String { lines.randomElement()! }
}
