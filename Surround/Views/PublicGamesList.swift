//
//  PublicGamesList.swift
//  Surround
//
//  Created by Anh Khoa Hong on 5/1/20.
//

import SwiftUI
import Combine

struct PublicGamesList: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var ogs: OGSService
    @State var games: [Game] = []
    @State var gameDetailCancellable: AnyCancellable?
    @State var publicGamesCancellable: AnyCancellable?
    @State var gameToShowDetail: Game? = nil
    @State var showDetail = false
    
    var body: some View {
        Group {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))]) {
                    ForEach(games) { game in
                        GameCell(game: game)
                            .onTapGesture {
                                self.gameToShowDetail = game
                                self.showDetail = true
                                self.gameDetailCancellable = ogs.getGameDetailAndConnect(gameID: game.gameData!.gameId).sink(receiveCompletion: { _ in
                                }, receiveValue: { value in
                                })
                            }
                            .padding()
                    }
                }
                .background(Color(colorScheme == .dark ? UIColor.systemGray5 : UIColor.white))
                NavigationLink(destination: gameToShowDetail == nil ? nil : GameDetailView(currentGame: gameToShowDetail!), isActive: $showDetail) {
                    EmptyView()
                }
            }
        }
        .onAppear {
            print("Appeared \(self)")
            if self.games.count == 0 && self.publicGamesCancellable == nil {
                self.publicGamesCancellable = ogs.fetchAndConnectToPublicGames().sink(receiveCompletion: { completion in

                }) { games in
                    self.games = games
                }
            }
        }
        .onDisappear {
            print("Disappeared \(self) \(String(describing: gameToShowDetail))")
            for game in games {
                if game.ID != gameToShowDetail?.ID {
                    ogs.disconnect(from: game)
                } else {
                    print("Skipped")
                }
            }
            DispatchQueue.main.async {
                games = []
                publicGamesCancellable = nil
            }
        }
        .navigationBarTitle(Text("Public live games"))
        .modifier(RootViewSwitchingMenu())
    }
}

struct PublicGamesList_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            PublicGamesList()
        }
        .environmentObject(OGSService.previewInstance())
        .colorScheme(.dark)
    }
}
