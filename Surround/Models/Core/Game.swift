//
//  Game.swift
//  Surround
//
//  Created by Anh Khoa Hong on 4/30/20.
//

import Foundation
import Combine
import DictionaryCoding

enum GameID: Hashable {
    case OGS(Int)
}

class Game: ObservableObject, Identifiable, CustomDebugStringConvertible, Equatable {
    static func == (lhs: Game, rhs: Game) -> Bool {
        return lhs.ID == rhs.ID
    }
    
    @Published var gameData: OGSGame? {
        didSet {
            if let data = gameData {
                self.gameName = data.gameName
                self.blackPlayer = OGSUser.mergeUserInfoFromCache(user: self.blackPlayer, cachedUser: data.players.black)
                self.whitePlayer = OGSUser.mergeUserInfoFromCache(user: self.whitePlayer, cachedUser: data.players.white)
                
                if let rengoTeams = gameData?.rengoTeams {
                    for player in rengoTeams[.black] + rengoTeams[.white] {
                        playerByOGSId[player.id] = player
                    }
                    
                    if let players = gameData?.players {
                        latestPlayerUpdate = OGSPlayerUpdate(
                            players: OGSPlayerUpdate.Players(black: players.black.id, white: players.white.id),
                            rengoTeams: OGSPlayerUpdate.RengoTeams(
                                black: rengoTeams.black.map { $0.id },
                                white: rengoTeams.white.map { $0.id }
                            )
                        )
                    }
                }
                
                if let playerPool = gameData?.playerPool {
                    for player in playerPool.values {
                        playerByOGSId[player.id] = player
                    }
                }
                
                if let blackAcceptedRemovedStones = data.players.black.acceptedStones {
                    self.removedStonesAccepted[.black] = BoardPosition.points(fromPositionString: blackAcceptedRemovedStones)
                }
                if let whiteAcceptedRemovedStones = data.players.white.acceptedStones {
                    self.removedStonesAccepted[.white] = BoardPosition.points(fromPositionString:  whiteAcceptedRemovedStones)
                }
                
                do {
                    if data.initialState.white.count > 0 || data.initialState.black.count > 0 {
                        for point in BoardPosition.points(fromPositionString: data.initialState.black) {
                            initialPosition.putStone(row: point[0], column: point[1], color: .black)
                        }
                        for point in BoardPosition.points(fromPositionString: data.initialState.white) {
                            initialPosition.putStone(row: point[0], column: point[1], color: .white)
                        }
                        initialPosition.nextToMove = data.initialPlayer
                    }
                    var position = initialPosition
                    if !position.hasTheSamePosition(with: moveTree.initialPosition) {
                        moveTree = MoveTree(position: position)
                    } else {
                        position = moveTree.initialPosition
                    }
                    self.positionByLastMoveNumber[position.lastMoveNumber] = position
                    for move in data.moves {
                        var newPosition: BoardPosition? = nil
                        if let handicap = gameData?.handicap, gameData?.freeHandicapPlacement ?? false {
                            if position.lastMoveNumber < handicap - 1 {
                                newPosition = try position.makeHandicapPlacement(move: move.move)
                            }
                        }
                        if newPosition == nil {
                            newPosition = try position.makeMove(move: move.move)
                        }
                        newPosition = moveTree.register(newPosition: newPosition!, fromPosition: position, mainBranch: true)
                        self.positionByLastMoveNumber[newPosition!.lastMoveNumber] = newPosition
                        
                        position = newPosition!
                        latestPlayerUpdate = move.extra?.playerUpdate
                    }
                    currentPosition = position
                } catch {
                    print(error)
                }
                if let removedStones = gameData?.removed {
                    currentPosition.removedStones = BoardPosition.points(fromPositionString: removedStones)
                }
                currentPosition.gameScores = gameData?.score

                pauseControl = data.pauseControl
                clock = data.clock
                
                undoRequested = data.undoRequested

                autoScoringDone = data.autoScoringDone
                // Put this at the end since it will trigger score computing
                gamePhase = data.phase
            }
        }
    }
    var width: Int
    var height: Int
    @Published var blackPlayer: OGSUser? {
        didSet {
            self.blackId = blackPlayer?.id
            if let player = blackPlayer {
                playerByOGSId[player.id] = player
                blackName = player.username
            }
        }
    }
    @Published var whitePlayer: OGSUser? {
        didSet {
            self.whiteId = whitePlayer?.id
            if let player = whitePlayer {
                playerByOGSId[player.id] = player
                whiteName = player.username
            }
        }
    }
    var blackName: String
    var whiteName: String
    @Published var blackId: Int?
    @Published var whiteId: Int?
    @Published var gameName: String?
    @Published var currentPosition: BoardPosition {
        didSet {
            self.positionByLastMoveNumber[currentPosition.lastMoveNumber] = currentPosition
        }
    }
    @Published var undoRequested: Int?
//    var blackFormattedRank: String {
//        return blackPlayer?.formattedRank() ?? "?"
//    }
//    var whiteFormattedRank: String {
//        return whitePlayer?.formattedRank() ?? "?"
//    }
    @Published var moveTree: MoveTree
    var initialPosition: BoardPosition
    var ID: GameID
    var ogsURL: URL? {
        if case .OGS(let id) = self.ID {
            return URL(string: "\(OGSService.ogsRoot)/game/\(id)")
        }
        return nil
    }
    @Published var ogsRawData: [String: Any]? {
        didSet {
            if let players = (ogsRawData ?? [:])["players"] as? [String: Any] {
                let decoder = DictionaryDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                if let black = players["black"] as? [String: Any], let blackPlayer = try? decoder.decode(OGSUser.self, from: black) {
                    self.blackPlayer = blackPlayer
                }
                if let white = players["white"] as? [String: Any], let whitePlayer = try? decoder.decode(OGSUser.self, from: white) {
                    self.whitePlayer = whitePlayer
                }
            }
        }
    }
    @Published var clock: OGSClock?
    @Published var pauseControl: OGSPauseControl?
    var canBeCancelled: Bool {
        if gamePhase != .play {
            return false
        }
        
        if gameData?.tournamentId != nil {
            return false
        }
        
        if gameData?.ladderId != nil {
            return false
        }
        
        var maxMovePlayed = 2
        if let handicap = gameData?.handicap {
            if gameData?.freeHandicapPlacement ?? false {
                maxMovePlayed += handicap - 1
            }
        }
        return currentPosition.lastMoveNumber < maxMovePlayed
    }
    var analysisAvailable: Bool {
        return !isUserPlaying || !(gameData?.disableAnalysis ?? false)
    }
    
    var playerCacheObservingCancellable: AnyCancellable?
    weak var ogs: OGSService? {
        didSet {
            if let ogs = ogs {
                if playerCacheObservingCancellable != nil {
                    playerCacheObservingCancellable?.cancel()
                }
                playerCacheObservingCancellable = ogs.$cachedUsersById.collect(.byTime(DispatchQueue.main, 2.0)).sink(receiveValue: { values in
                    if let cachedPlayersById = values.last {
                        for (playerId, player) in self.playerByOGSId {
                            if let cachedPlayer = cachedPlayersById[playerId] {
                                self.playerByOGSId[playerId] = OGSUser.mergeUserInfoFromCache(user: player, cachedUser: cachedPlayer)
                                if playerId == self.blackPlayer?.id {
                                    self.blackPlayer = self.playerByOGSId[playerId]
                                } else if playerId == self.whitePlayer?.id {
                                    self.whitePlayer = self.playerByOGSId[playerId]
                                }
                            }
                        }
                    }
                })
            } else {
                playerCacheObservingCancellable?.cancel()
                playerCacheObservingCancellable = nil
            }
        }
    }
    
    var autoScoringDone: Bool?
    var autoScoringCancellable: AnyCancellable?
    var toggleRemovedStoneCancellable: AnyCancellable?
    @Published var gamePhase: OGSGamePhase? {
        didSet {
            if gamePhase == .stoneRemoval {
                if !(autoScoringDone ?? false) && isUserPlaying {
                    // Doing score estimating
                    self.autoScoringCancellable = currentPosition.estimateTerritory(on: computeQueue)
                        .receive(on: DispatchQueue.main)
                        .sink(receiveValue: { territory in
                            var estimatedRemovedStones = Set<[Int]>()
                            for row in 0..<self.currentPosition.height {
                                for column in 0..<self.currentPosition.width {
                                    let isCaptured = self.currentPosition[row, column] != .empty && self.currentPosition[row, column] != territory[row][column]
                                    let isDame = territory[row][column] == .empty && self.currentPosition[row, column] == .empty
                                    if isCaptured || isDame {
                                        estimatedRemovedStones.insert([row, column])
                                    }
                                }
                            }
                            self.toggleRemovedStoneCancellable = self.ogs?.toggleRemovedStones(stones: estimatedRemovedStones, forGame: self)
                                .sink(receiveCompletion: { _ in}, receiveValue: { _ in})
                    })
                } else {
                    computeScoresAndUpdate()
                }
            } else if gamePhase == .play {
                DispatchQueue.main.async {
                    self.autoScoringDone = nil
                    self.currentPosition.gameScores = nil
                    self.currentPosition.removedStones = nil
                }
            }
        }
    }
    @Published var removedStonesAccepted = [StoneColor: Set<[Int]>]()
    lazy var computeQueue = DispatchQueue(label: "com.honganhkhoa.Surround.computeQueue", qos: .default)
    
    @Published var chatLog = [OGSChatLine]()
    var positionByLastMoveNumber = [Int: BoardPosition]()
    
    var rengo: Bool { gameData?.rengo ?? false }
    var latestPlayerUpdate: OGSPlayerUpdate? {
        didSet {
            if let update = latestPlayerUpdate {
                for color in [StoneColor.black, StoneColor.white] {
                    orderedRengoTeam[color] = update.rengoTeams[color].map { playerByOGSId[$0]! }
                }
            }
        }
    }
    
    var playerByOGSId: [Int: OGSUser] = [:]
    
    @Published var orderedRengoTeam: [StoneColor: [OGSUser]] = [:]
    func currentPlayer(with color: StoneColor) -> OGSUser? {
        if rengo {
            return orderedRengoTeam[color]?.first
        } else {
            switch color {
            case .black:
                return blackPlayer
            case .white:
                return whitePlayer
            }
        }
    }
    
    var debugDescription: String {
        if case .OGS(let id) = self.ID {
            return "Game #\(id)"
        }
        return ""
    }
    var ogsID: Int? {
        if case .OGS(let id) = self.ID {
            return id
        }
        return nil
    }
    
    func playerIcon(for stoneColor: StoneColor, size: Int) -> String? {
        let iconFromGameData = stoneColor == .black ? gameData?.players.black.iconUrl : gameData?.players.white.iconUrl
        
        guard let icon = iconFromGameData ?? ((self.ogsRawData ?? [:]) as NSDictionary).value(forKeyPath: stoneColor == .black ? "players.black.icon" : "players.white.icon") as? String else {
            return nil
        }
        
        return Game.iconURL(from: icon, withSize: size)
    }
    
//    func rengoTeamOrderedFromNextToMove(with stoneColor: StoneColor) -> [OGSUser] {
//        if let rengoTeamIds = self.latestPlayerUpdate?.rengoTeams[stoneColor] {
//            return rengoTeamIds.map { playerByOGSId[$0]! }
//        }
//        
//        if let rengoTeam = gameData?.rengoTeams?[stoneColor] {
//            if let nextPlayerId = clock?.nextPlayerId(with: stoneColor) {
//                if let nextPlayerIndex = rengoTeam.firstIndex(where: { $0.id == nextPlayerId }) {
//                    return Array(rengoTeam.suffix(from: nextPlayerIndex) + rengoTeam.prefix(upTo: nextPlayerIndex))
//                }
//            }
//        }
//        return []
//    }
    
    static func iconURL(from urlString: String, withSize size: Int) -> String {
        let regex1 = try! NSRegularExpression(pattern: "-[0-9]+.png")
        let regex2 = try! NSRegularExpression(pattern: "s=[0-9]+")
        var result = urlString
        result = regex1.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "-\(size).png")
        result = regex2.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "s=\(size)")
        return result
    }
    
    init(width: Int, height: Int, blackName: String, whiteName: String, gameId: GameID) {
        self.width = width
        self.height = height
        self.blackName = blackName
        self.whiteName = whiteName
        self.ID = gameId
        self.initialPosition = BoardPosition(width: width, height: height)
        self.positionByLastMoveNumber[self.initialPosition.lastMoveNumber] = self.initialPosition
        self.currentPosition = self.initialPosition
        self.moveTree = MoveTree(position: self.initialPosition)
        self._postInit()
    }
    
    init(ogsGame: OGSGame) {
        self.width = ogsGame.width
        self.height = ogsGame.height
        self.blackName = ogsGame.players.black.username
        self.whiteName = ogsGame.players.white.username
        self.blackId = ogsGame.players.black.id
        self.whiteId = ogsGame.players.white.id
        self.ID = .OGS(ogsGame.gameId)
        self.initialPosition = BoardPosition(width: width, height: height)
        self.positionByLastMoveNumber[self.initialPosition.lastMoveNumber] = self.initialPosition
        self.currentPosition = self.initialPosition
        self.moveTree = MoveTree(position: self.initialPosition)
        self.gameData = ogsGame
        self.clock?.calculateTimeLeft(with: ogsGame.timeControl.system, pauseControl: self.pauseControl)
        self._postInit()
    }
    
    private func _postInit() {

    }
    
    @discardableResult
    func makeMove(move: Move, fromAnalyticsPosition: BoardPosition? = nil) throws -> BoardPosition {
        let fromPosition = fromAnalyticsPosition ?? self.currentPosition
        var newPosition: BoardPosition? = nil
        if let handicap = gameData?.handicap {
            if gameData?.freeHandicapPlacement ?? false {
                if fromPosition.lastMoveNumber < handicap - 1 {
                    newPosition = try fromPosition.makeHandicapPlacement(move: move)
                }
            }
        }
        if newPosition == nil {
            newPosition = try fromPosition.makeMove(move: move, allowsSelfCapture: gameData?.allowSelfCapture ?? false)
        }
        if let newPosition = newPosition {
            if fromPosition === currentPosition && fromAnalyticsPosition == nil {
                let registeredPosition = self.moveTree.register(newPosition: newPosition, fromPosition: self.currentPosition, mainBranch: true)
                self.currentPosition = registeredPosition
                self.undoRequested = nil
                return registeredPosition
            }
            if fromPosition === fromAnalyticsPosition {
                return self.moveTree.register(newPosition: newPosition, fromPosition: fromPosition, mainBranch: false)
            }
        }
        
        return newPosition!
    }
    
    func undoMove(numbered moveNumber: Int) {
        var position = currentPosition
        var nextPosition: BoardPosition? = nil
        while position.previousPosition != nil && position.lastMoveNumber >= moveNumber {
            nextPosition = position
            position = position.previousPosition!
        }
        if let nextPosition = nextPosition {
            moveTree.removeData(forPosition: nextPosition)
            var nextMoveNumber = nextPosition.lastMoveNumber
            while positionByLastMoveNumber.removeValue(forKey: nextMoveNumber) != nil {
                nextMoveNumber += 1
            }
        }
        currentPosition = position
        self.undoRequested = nil
    }
    
    func computeScore() -> GameScores? {
        guard let gameData = gameData else {
            return nil
        }
        var score = GameScores(
            black: PlayerScore(
                handicap: 0,
                komi: 0,
                scoringPositions: Set<[Int]>(),
                stones: 0,
                territory: 0,
                prisoners: 0,
                total: 0
            ),
            white: PlayerScore(
                handicap: gameData.handicap,
                komi: gameData.komi,
                scoringPositions: Set<[Int]>(),
                stones: 0,
                territory: 0,
                prisoners: 0,
                total: 0
            )
        )
        let territoryGroups = self.currentPosition.constructTerritoryGroups()
        
        if gameData.agaHandicapScoring && score.white.handicap > 0 {
            score.white.handicap -= 1
        }
        
        if gameData.scoreTerritory {
            for group in territoryGroups {
                group.computeTerritory()
                if group.isTerritory {
                    if group.territoryColor == .black {
                        score.black.scoringPositions.formUnion(group.points)
                        if !group.isDame {
                            score.black.territory += group.points.count
                        }
                    } else {
                        score.white.scoringPositions.formUnion(group.points)
                        if !group.isDame {
                            score.white.territory += group.points.count
                        }
                    }
                }
            }
        }
        
        for row in 0..<width {
            for column in 0..<height {
                if case .hasStone(let color) = currentPosition[row, column] {
                    let isRemoved = currentPosition.removedStones?.contains([row, column]) ?? false
                    if !isRemoved && gameData.scoreStones {
                        if color == .black {
                            score.black.stones += 1
                            score.black.scoringPositions.insert([row, column])
                        } else {
                            score.white.stones += 1
                            score.white.scoringPositions.insert([row, column])
                        }
                    }
                    if isRemoved && gameData.scorePrisoners {
                        if color == .black {
                            score.white.prisoners += 1
                        } else {
                            score.black.prisoners += 1
                        }
                    }
                }
            }
        }
        
        if gameData.scorePrisoners {
            score.white.prisoners += currentPosition.captures[.white] ?? 0
            score.black.prisoners += currentPosition.captures[.black] ?? 0
        }
        
        score.black.total = Double(score.black.stones + score.black.territory + score.black.prisoners) + score.black.komi
        score.white.total = Double(score.white.stones + score.white.territory + score.white.prisoners) + score.white.komi
        if gameData.scoreHandicap {
            score.black.total += Double(score.black.handicap)
            score.white.total += Double(score.white.handicap)
        }
        
        return score
    }
    
    func computeScoresAndUpdate() {
        computeQueue.async {
            if let score = self.computeScore() {
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                    self.currentPosition.gameScores = score
                }
            }
        }
    }
    
    func setRemovedStones(removedString: String) {
        self.currentPosition.removedStones = BoardPosition.points(fromPositionString: removedString)
        if self.gamePhase == .stoneRemoval {
            self.computeScoresAndUpdate()
        }
    }
    
    func setAutoResign(playerId: Int, time: Double) {
        guard let player = playerByOGSId[playerId], let playerColor = stoneColor(of: player) else {
            return
        }
        
        self.clock?.autoResignTime[playerColor] = time
    }
    
    func clearAutoResign(playerId: Int) {
        guard let player = playerByOGSId[playerId], let playerColor = stoneColor(of: player) else {
            return
        }
        
        self.clock?.autoResignTime.removeValue(forKey: playerColor)
    }
    
    var isUserPlaying: Bool {
        guard let user = ogs?.user else {
            return false
        }
        if gameData?.rengo ?? false, let rengoTeams = gameData?.rengoTeams {
            let players = rengoTeams.black + rengoTeams.white
            for player in players {
                if user.id == player.id {
                    return true
                }
            }
            return false
        } else {
            return user.id == self.blackPlayer?.id || user.id == self.whitePlayer?.id
        }
    }
    
    func stoneColor(of player: OGSUser) -> StoneColor? {
        if rengo {
            if let blackTeam = orderedRengoTeam[.black] ?? gameData?.rengoTeams?[.black] {
                for blackMember in blackTeam {
                    if blackMember.id == player.id {
                        return .black
                    }
                }
            }
            if let whiteTeam = orderedRengoTeam[.white] ?? gameData?.rengoTeams?[.white] {
                for whiteMember in whiteTeam {
                    if whiteMember.id == player.id {
                        return .white
                    }
                }
            }
        } else {
            if player.id == self.blackPlayer?.id {
                return .black
            } else if player.id == self.whitePlayer?.id {
                return .white
            }
        }
        return nil
    }
    
    func stoneColor(ofPlayerWithId playerId: Int) -> StoneColor? {
        if let player = playerByOGSId[playerId] {
            return stoneColor(of: player)
        }
        
        return nil
    }
    
    var userStoneColor: StoneColor? {
        guard let user = ogs?.user else {
            return nil
        }
        if !isUserPlaying {
            return nil
        }
        return stoneColor(of: user)
    }
    
    var isUserTurn: Bool {
        guard isUserPlaying else {
            return false
        }
        
        guard let user = ogs?.user else {
            return false
        }
        
        guard self.gamePhase == .play else {
            return false
        }
        
        return self.clock?.currentPlayerId == user.id
    }
    
    var status: String {
        if let outcome = gameData?.outcome {
            if let winnerId = gameData?.winner, let winner = playerByOGSId[winnerId], let winnerColor = stoneColor(of: winner), winnerColor == .black {
                return "Black wins by \(outcome)"
            } else {
                return "White wins by \(outcome)"
            }
        } else if let estimatedScores = currentPosition.estimatedScores {
            var whiteScore: Double = 0
            var blackScore: Double = 0
            for row in 0..<currentPosition.height {
                for column in 0..<currentPosition.width {
                    if case .hasStone(let color) = estimatedScores[row][column] {
                        if color == .black {
                            blackScore += 1
                        } else {
                            whiteScore += 1
                        }
                    }
                }
            }
            let difference = whiteScore + (gameData?.komi ?? 0) - blackScore
            if difference > 0 {
                return String(format: "White by %.1f", difference)
            } else {
                return String(format: "Black by %.1f", -difference)
            }
        } else {
            if gamePhase == .stoneRemoval {
                return "Stone Removal Phase"
            }
            if undoRequested != nil {
                return "Undo requested"
            }
            if isUserPlaying {
                if isUserTurn {
                    if case .pass = currentPosition.lastMove {
                        return "Opponent passed"
                    } else {
                        let time = userStoneColor == .black ? clock?.blackTime : clock?.whiteTime
                        if let timeLeft = time?.timeLeft, timeLeft <= 10 {
                            return "Your move (\(String(format: "%02d", Int(timeLeft))))"
                        }
                        return "Your move"
                    }
                } else {
                    if userStoneColor == clock?.currentPlayerColor {
                        return "Waiting for teammate"
                    } else {
                        return "Waiting for opponent"
                    }
                }
            } else {
                if let currentPlayer = clock?.currentPlayerColor {
                    return "\(currentPlayer == .black ? "Black" : "White") to move"
                } else {
                    return ""
                }
            }
        }
    }
    
    var undoable: Bool {
        guard !rengo else {
            return false
        }
        
        guard isUserPlaying else {
            return false
        }
        
        guard gamePhase == .play && gameData?.outcome == nil else {
            return false
        }
        
        var minimumLastMove = 0
        if let handicap = gameData?.handicap {
            if gameData?.freeHandicapPlacement ?? false {
                minimumLastMove = handicap
            }
        }
        
        return !isUserTurn && undoRequested == nil && currentPosition.lastMoveNumber > minimumLastMove
    }

    var undoacceptable: Bool {
        guard let undoRequested = undoRequested else {
            return false
        }
        return isUserTurn && undoRequested == currentPosition.lastMoveNumber
    }
    
    private var lastSeenChatId: String? = nil
    private var lastSeenChatIndex: Int? = nil
    @Published var chatUnreadCount: Int = 0

    func addChatLine(_ line: OGSChatLine) {
        var line = line
        if let variationData = line.variationData {
            if let basePosition = self.positionByLastMoveNumber[variationData.fromMoveNumber] {
                if let variation = try? Variation(
                    basePosition: basePosition,
                    moves: variationData.moves
                ) {
                    line.variation = variation
                }
            }
        }
        if self.chatLog.count == 0 || self.chatLog.last!.timestamp <= line.timestamp {
            self.chatLog.append(line)
            if line.id == lastSeenChatId {
                lastSeenChatIndex = self.chatLog.count - 1
            }
        } else {
            var i = self.chatLog.count - 1
            while (i >= 0 && self.chatLog[i].timestamp > line.timestamp) {
                i -= 1
            }
            self.chatLog.insert(line, at: i + 1)
            if line.id == lastSeenChatId {
                lastSeenChatIndex = i + 1
            }
        }
        
        if let lastSeenChatIndex = lastSeenChatIndex {
            chatUnreadCount = chatLog.count - lastSeenChatIndex - 1
        } else {
            chatUnreadCount = chatLog.count
        }
    }
    
    func resetChats() {
        self.chatLog.removeAll()
        if let ogsId = self.ogsID {
            lastSeenChatId = userDefaults[.lastSeenChatIdByOGSGameId]?[ogsId]
        }
    }
    
    func markAllChatAsRead() {
        guard let lastChat = chatLog.last, let ogsId = self.ogsID else {
            return
        }
        
        chatUnreadCount = 0
        lastSeenChatIndex = chatLog.count - 1
        if lastSeenChatId != lastChat.id {
            var lastSeenChatIdByOGSGameId = userDefaults[.lastSeenChatIdByOGSGameId] ?? [Int: String]()
            lastSeenChatIdByOGSGameId[ogsId] = lastChat.id
            userDefaults[.lastSeenChatIdByOGSGameId] = lastSeenChatIdByOGSGameId
            lastSeenChatId = lastChat.id
        }
    }
}
