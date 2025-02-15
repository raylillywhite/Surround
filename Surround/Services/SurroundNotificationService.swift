//
//  NotificationService.swift
//  Surround
//
//  Created by Anh Khoa Hong on 10/19/20.
//

import Foundation
import UIKit
import DictionaryCoding
import Alamofire
import WidgetKit
import BackgroundTasks

class SurroundNotificationService {
    static let shared = SurroundNotificationService()
    
    var userId: Int? { userDefaults[.ogsUIConfig]?.user.id }
    var notificationCheckCounter = [String: Int]()
    var notificationScheduledCounter = [String: Int]()
    
    func activeOGSGamesById(from data: [String: Any]) -> [Int: Game] {
        var result = [Int: Game]()
        if let activeGamesData = data["active_games"] as? [[String: Any]] {
            let decoder = DictionaryDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            for gameData in activeGamesData {
                if let jsonData = gameData["json"] as? [String: Any] {
                    if let ogsGame = try? decoder.decode(OGSGame.self, from: jsonData) {
                        let game = Game(ogsGame: ogsGame)
                        result[game.ogsID!] = game
                    }
                }
            }
        }
        return result
    }
    
    func scheduleNotification(title: String, message: String, game: Game, setting: SettingKey<Bool>) {
        guard userDefaults[setting] == true else {
            return
        }

        UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { notifications in
            var toBeRemovedNotificationIndentifiers = [String]()
            for notification in notifications {
                let userInfo = notification.request.content.userInfo
                if let ogsGameId = userInfo["ogsGameId"] as? Int, let notificationCategory = userInfo["notificationCategory"] as? String {
                    if ogsGameId == game.ogsID && notificationCategory == setting.mainName {
                        toBeRemovedNotificationIndentifiers.append(notification.request.identifier)
                    }
                }
            }
            if toBeRemovedNotificationIndentifiers.count > 0 {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: toBeRemovedNotificationIndentifiers)
            }
        })
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.categoryIdentifier = "GAME"
        content.sound = .default
        content.userInfo = [
            "rootView": RootView.home.rawValue,
            "ogsGameId": game.ogsID!,
            "notificationCategory": setting.mainName
        ]

        let uuidString = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { (error) in
           if let error = error {
              print(error)
           }
        }
    }
    
    func scheduleNewMoveNotificationIfNecessary(oldGame: Game, newGame: Game) -> Bool {
        if let userId = userId {
            let opponentName = newGame.stoneColor(ofPlayerWithId: userId) == .black ? newGame.whiteName : newGame.blackName
    //        print(oldGame.ogsID, oldGame.clock?.currentPlayerId, newGame.clock?.currentPlayerId)
            if oldGame.clock?.currentPlayerId != newGame.clock?.currentPlayerId
                && newGame.clock?.currentPlayerId == userId {
                self.scheduleNotification(
                    title: "Your turn",
                    message: "It is your turn in the game with \(opponentName).",
                    game: newGame,
                    setting: .notificationOnUserTurn
                )
                return true
            }
        }
        return false
    }
    
    func scheduleTimeRunningOutNotificationIfNecessary(oldGame: Game, newGame: Game) -> Bool {
        if let lastCheck = userDefaults[.latestOGSOverviewTime], let userId = userId {
            if oldGame.clock?.currentPlayerId == userId
                && newGame.clock?.currentPlayerId == userId
                && !(newGame.pauseControl?.isPaused() ?? false) {
                let thinkingTime = newGame.stoneColor(ofPlayerWithId: userId) == .black ? newGame.clock?.blackTime : newGame.clock?.whiteTime
                if let timeLeft = thinkingTime?.timeLeft {
                    let lastTimeLeft = timeLeft + Date().timeIntervalSince(lastCheck)
                    let twelveHours = Double(12 * 3600)
                    let threeHours = Double(3 * 3600)
                    let opponentName = newGame.stoneColor(ofPlayerWithId: userId) == .black ? newGame.whiteName : newGame.blackName
                    if lastTimeLeft > twelveHours && timeLeft <= twelveHours {
                        self.scheduleNotification(
                            title: "Time running out",
                            message: "You have 12 hours to make your move in the game with \(opponentName).",
                            game: newGame,
                            setting: .notificationOnTimeRunningOut
                        )
                        return true
                    } else if lastTimeLeft > threeHours && timeLeft <= threeHours {
                        self.scheduleNotification(
                            title: "Time running out",
                            message: "You have 3 hours to make your move in the game with \(opponentName).",
                            game: newGame,
                            setting: .notificationOnTimeRunningOut
                        )
                        return true
                    }
                }
            }
        }
        return false
    }
    
    func scheduleGameEndNotificationIfNecessary(oldGame: Game, newGame: Game) -> Bool {
        if let outcome = newGame.gameData?.outcome, let userId = userId {
            if oldGame.gameData?.outcome == nil {
                let opponentName = newGame.stoneColor(ofPlayerWithId: userId) == .black ? newGame.whiteName : newGame.blackName
                let result = newGame.gameData?.winner == userId ? "won" : "lost"
                self.scheduleNotification(
                    title: "Game has ended",
                    message: "Your game with \(opponentName) has ended. You \(result) by \(outcome).",
                    game: newGame,
                    setting: .notiticationOnGameEnd
                )
                return true
            }
        }
        return false
    }
    
    func scheduleGameEndNotificationIfNecessary(oldGame: Game, completionHandler: ((Bool) -> Void)? = nil) {
        if let ogsId = oldGame.ogsID {
            AF.request("\(OGSService.ogsRoot)/api/v1/games/\(ogsId)").responseJSON { response in
                if case .success = response.result {
                    if let data = response.value as? [String: Any] {
                        if let gameData = data["gamedata"] as? [String: Any] {
                            let decoder = DictionaryDecoder()
                            decoder.keyDecodingStrategy = .convertFromSnakeCase
                            if let ogsGame = try? decoder.decode(OGSGame.self, from: gameData) {
                                let newGame = Game(ogsGame: ogsGame)
                                let result = self.scheduleGameEndNotificationIfNecessary(oldGame: oldGame, newGame: newGame)
                                if let callback = completionHandler {
                                    callback(result)
                                }
                                return
                            }
                        }
                    }
                }
                if let callback = completionHandler {
                    callback(false)
                }
            }
        } else {
            if let callback = completionHandler {
                callback(false)
            }
        }
    }
    
    func scheduleNewGameNotificationIfNecessary(newGame: Game) -> Bool {
        if let userId = userId {
            let opponentName = newGame.stoneColor(ofPlayerWithId: userId) == .black ? newGame.whiteName : newGame.blackName
            self.scheduleNotification(
                title: "Game started",
                message: "Your game with \(opponentName) has started.",
                game: newGame,
                setting: .notificationOnNewGame
            )
            return true
        }
        return false
    }
    
    func scheduleNotificationsIfNecessary(withOldOverviewData oldData: Data, newOverviewData newData: Data, completionHandler: ((Int) -> Void)? = nil) {
        guard userDefaults[.notificationEnabled] == true else {
            if let callback = completionHandler {
                callback(0)
            }
            return
        }
        
        let sessionId = UUID().uuidString
        self.notificationCheckCounter[sessionId] = 0
        self.notificationScheduledCounter[sessionId] = 0
        
        let checkForCompletion: () -> Void = {
            if self.notificationCheckCounter[sessionId] == 0 {
                if let callback = completionHandler {
                    let result = self.notificationScheduledCounter[sessionId]
                    self.notificationScheduledCounter.removeValue(forKey: sessionId)
                    self.notificationCheckCounter.removeValue(forKey: sessionId)
                    callback(result!)
                }
            }
        }
        
        if let oldData = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any],
           let newData = try? JSONSerialization.jsonObject(with: newData) as? [String: Any] {
            let oldActiveGamesById = activeOGSGamesById(from: oldData)
            let newActiveGamesById = activeOGSGamesById(from: newData)
//            self.scheduleNotification(title: "Test", message: "Testing...", game: newActiveGamesById.values.first!, setting: .notificationEnabled)
            for oldGame in oldActiveGamesById.values {
                if let newGame = newActiveGamesById[oldGame.ogsID!] {
                    if self.scheduleNewMoveNotificationIfNecessary(oldGame: oldGame, newGame: newGame) {
                        self.notificationScheduledCounter[sessionId]! += 1
                    }
                    if self.scheduleTimeRunningOutNotificationIfNecessary(oldGame: oldGame, newGame: newGame) {
                        self.notificationScheduledCounter[sessionId]! += 1
                    }
                    if self.scheduleGameEndNotificationIfNecessary(oldGame: oldGame, newGame: newGame) {
                        self.notificationScheduledCounter[sessionId]! += 1
                    }
                } else {
                    self.notificationCheckCounter[sessionId]! += 1
                    self.scheduleGameEndNotificationIfNecessary(oldGame: oldGame, completionHandler: { notified in
                        if notified {
                            self.notificationScheduledCounter[sessionId]! += 1
                        }
                        self.notificationCheckCounter[sessionId]! -= 1
                        checkForCompletion()
                    })
                }
            }
            for newGame in newActiveGamesById.values {
                if oldActiveGamesById[newGame.ogsID!] == nil {
                    if self.scheduleNewGameNotificationIfNecessary(newGame: newGame) {
                        self.notificationScheduledCounter[sessionId]! += 1
                    }
                }
            }
        }
        checkForCompletion()
    }
}
