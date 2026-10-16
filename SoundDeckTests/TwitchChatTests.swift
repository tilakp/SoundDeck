import Foundation
import Testing
@testable import SoundDeck

struct IRCMessageTests {
    @Test func parsesAChatLineWithTags() throws {
        let line = "@badges=broadcaster/1,subscriber/0;display-name=Ann\\sB;mod=0 "
            + ":ann!ann@ann.tmi.twitch.tv PRIVMSG #chan :!sound gong now\r\n"
        let message = try #require(IRCMessage.parse(line))
        #expect(message.tags["badges"] == "broadcaster/1,subscriber/0")
        #expect(message.tags["display-name"] == "Ann B")
        #expect(message.tags["mod"] == "0")
        #expect(message.prefix == "ann!ann@ann.tmi.twitch.tv")
        #expect(message.nick == "ann")
        #expect(message.command == "PRIVMSG")
        #expect(message.params == ["#chan"])
        #expect(message.trailing == "!sound gong now")
    }

    @Test func parsesLinesWithoutTagsOrPrefix() throws {
        let ping = try #require(IRCMessage.parse("PING :tmi.twitch.tv"))
        #expect(ping.command == "PING")
        #expect(ping.prefix == nil)
        #expect(ping.params.isEmpty)
        #expect(ping.trailing == "tmi.twitch.tv")

        let welcome = try #require(IRCMessage.parse(":tmi.twitch.tv 001 justinfan123 :Welcome, GLHF!"))
        #expect(welcome.command == "001")
        #expect(welcome.params == ["justinfan123"])
        #expect(welcome.trailing == "Welcome, GLHF!")

        let join = try #require(IRCMessage.parse(":justinfan1!justinfan1@justinfan1.tmi.twitch.tv JOIN #chan"))
        #expect(join.command == "JOIN")
        #expect(join.params == ["#chan"])
        #expect(join.trailing == nil)
    }

    @Test func rejectsEmptyLines() {
        #expect(IRCMessage.parse("") == nil)
        #expect(IRCMessage.parse("\r\n") == nil)
        #expect(IRCMessage.parse(":prefix.only") == nil)
    }

    @Test func unescapesTagValues() {
        #expect(IRCMessage.unescapeTagValue("a\\sb\\:c\\\\d") == "a b;c\\d")
        #expect(IRCMessage.unescapeTagValue("") == "")
    }
}

struct ChatTriggerTests {
    private let pads = ["Gong", "Airhorn", "Sad trombone"]
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    private func chat(_ text: String, user: String = "ann", tags: [String: String] = [:]) -> IRCMessage {
        IRCMessage(tags: tags, prefix: "\(user)!\(user)@\(user).tmi.twitch.tv",
                   command: "PRIVMSG", params: ["#chan"], trailing: text)
    }

    @Test func findsThePadAfterThePrefix() {
        #expect(ChatTriggerGate.padQuery(in: "!sound gong", prefix: "!sound") == "gong")
        #expect(ChatTriggerGate.padQuery(in: "  !SOUND   Sad trombone ", prefix: "!sound") == "Sad trombone")
        #expect(ChatTriggerGate.padQuery(in: "!soundboard", prefix: "!sound") == nil)
        #expect(ChatTriggerGate.padQuery(in: "!sound", prefix: "!sound") == nil)
        #expect(ChatTriggerGate.padQuery(in: "hello", prefix: "!sound") == nil)
        #expect(ChatTriggerGate.padQuery(in: "!sfx gong", prefix: "!sfx") == "gong")
    }

    @Test func playsAPadOfTheActiveDeck() {
        var gate = ChatTriggerGate()
        let outcome = gate.evaluate(chat("!sound gong", tags: ["display-name": "Ann"]),
                                    settings: ChatTriggerSettings(), activePads: pads, now: start)
        #expect(outcome == .play(user: "Ann", pad: "Gong"))
    }

    @Test func ignoresOtherMessages() {
        var gate = ChatTriggerGate()
        let settings = ChatTriggerSettings()
        #expect(gate.evaluate(chat("hello"), settings: settings, activePads: pads, now: start) == .ignored)
        let ping = IRCMessage(command: "PING", trailing: "!sound gong")
        #expect(gate.evaluate(ping, settings: settings, activePads: pads, now: start) == .ignored)
        #expect(gate.evaluate(chat("!sound nothing"), settings: settings, activePads: pads, now: start) == .unknownPad)
        // A rejected message does not start a cooldown.
        #expect(gate.lastGlobal == nil)
    }

    @Test func onlyTheListedPadsPlay() {
        var gate = ChatTriggerGate()
        var settings = ChatTriggerSettings()
        settings.allowAllPads = false
        settings.allowedPads = ChatTriggerSettings.padList(" Airhorn, ,Gong ")
        #expect(settings.allowedPads == ["Airhorn", "Gong"])
        #expect(gate.evaluate(chat("!sound sad trombone"), settings: settings, activePads: pads, now: start) == .unknownPad)
        #expect(gate.evaluate(chat("!sound airhorn"), settings: settings, activePads: pads, now: start)
                == .play(user: "ann", pad: "Airhorn"))
    }

    @Test func globalCooldownBlocksEveryViewer() {
        var gate = ChatTriggerGate()
        let settings = ChatTriggerSettings()
        #expect(gate.evaluate(chat("!sound gong", user: "ann"), settings: settings, activePads: pads, now: start)
                == .play(user: "ann", pad: "Gong"))
        let early = start.addingTimeInterval(9.9)
        #expect(gate.evaluate(chat("!sound gong", user: "bob"), settings: settings, activePads: pads, now: early)
                == .cooldown)
        let later = start.addingTimeInterval(10)
        #expect(gate.evaluate(chat("!sound gong", user: "bob"), settings: settings, activePads: pads, now: later)
                == .play(user: "bob", pad: "Gong"))
    }

    @Test func userCooldownBlocksTheSameViewer() {
        var gate = ChatTriggerGate()
        let settings = ChatTriggerSettings()
        _ = gate.evaluate(chat("!sound gong", user: "ann"), settings: settings, activePads: pads, now: start)
        let afterGlobal = start.addingTimeInterval(15)
        #expect(gate.evaluate(chat("!sound gong", user: "ann"), settings: settings, activePads: pads, now: afterGlobal)
                == .cooldown)
        // The blocked attempt does not start the cooldown again.
        let afterUser = start.addingTimeInterval(30)
        #expect(gate.evaluate(chat("!sound gong", user: "ann"), settings: settings, activePads: pads, now: afterUser)
                == .play(user: "ann", pad: "Gong"))
    }

    @Test func userIdIsTheKeyOfTheUserCooldown() {
        var gate = ChatTriggerGate()
        var settings = ChatTriggerSettings()
        settings.globalCooldown = 0
        _ = gate.evaluate(chat("!sound gong", user: "ann", tags: ["user-id": "7"]),
                          settings: settings, activePads: pads, now: start)
        // A new name with the same account id is the same viewer.
        let renamed = chat("!sound gong", user: "ann2", tags: ["user-id": "7"])
        #expect(gate.evaluate(renamed, settings: settings, activePads: pads, now: start.addingTimeInterval(1)) == .cooldown)
        let other = chat("!sound gong", user: "bob", tags: ["user-id": "8"])
        #expect(gate.evaluate(other, settings: settings, activePads: pads, now: start.addingTimeInterval(1))
                == .play(user: "bob", pad: "Gong"))
    }

    @Test func privilegedOnlyAllowsSubscribersModeratorsAndTheBroadcaster() {
        var settings = ChatTriggerSettings()
        settings.privilegedOnly = true
        settings.globalCooldown = 0
        settings.userCooldown = 0
        var gate = ChatTriggerGate()
        let viewer = chat("!sound gong", tags: ["subscriber": "0", "mod": "0", "badges": "premium/1"])
        #expect(gate.evaluate(viewer, settings: settings, activePads: pads, now: start) == .notAllowed)
        let allowed: [[String: String]] = [["subscriber": "1"], ["mod": "1"], ["badges": "vip/1,broadcaster/1"]]
        for tags in allowed {
            #expect(gate.evaluate(chat("!sound gong", tags: tags), settings: settings, activePads: pads, now: start)
                    == .play(user: "ann", pad: "Gong"))
        }
    }

    @Test func channelNameIsNormalized() {
        #expect(TwitchChat.normalizedChannel("  #MyChannel ") == "mychannel")
        #expect(TwitchChat.normalizedChannel("") == "")
    }
}
