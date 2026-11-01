import Foundation
import KurzCore
import KurzData
import Testing
@testable import KurzPresentation

@MainActor @Suite struct ToastTests {
    @Test func aFinishedMessageVanishesButAWorkingOneStays() async throws {
        let t = ToastViewModel()
        t.lifetime = .milliseconds(20)
        t.show("Convite aceite")
        #expect(t.isVisible && t.text == "Convite aceite")
        try await Task.sleep(for: .milliseconds(80))
        #expect(!t.isVisible)
        t.show("A descarregar…")
        try await Task.sleep(for: .milliseconds(80))
        #expect(t.text == "A descarregar…")
        t.show("Outra"); t.show("Mais nova")                                  // a mais nova cancela o relogio da anterior
        #expect(t.text == "Mais nova")
        t.show(nil)
        #expect(!t.isVisible)
    }
}

@MainActor @Suite struct AccountViewModelTests {
    @Test func theBadgeSaysWhatTheServerSaid() async {
        let w = World()
        #expect(w.account.badgeText == "Servidor" && w.account.badgeIcon == "icloud")
        await w.account.refreshStatus()
        #expect(w.account.isOnline && w.account.badgeShortText == "Ana" && w.account.badgeText == "Servidor · Ana · cpu" && w.account.badgeIcon == "checkmark.icloud")
        #expect(w.account.canEditName && w.account.nameDraft == "Ana")
        w.up = false
        await w.account.refreshStatus()
        #expect(w.account.badgeText == "Offline" && !w.account.isOnline && !w.account.canEditName)
    }

    @Test func withoutAnInviteTheServerRefusalOpensThePanelOnceAndLoginThenSavesIt() async {
        let w = World(invite: nil)
        #expect(!w.account.hasInvite)
        w.account.show(ServerStatus(.unauthorized))
        #expect(w.account.isInviteOpen && w.account.isBad && w.account.badgeShortText == "Sem convite")
        w.account.cancelInvite()
        w.account.show(ServerStatus(.unauthorized))
        #expect(!w.account.isInviteOpen)                                      // so abre sozinho uma vez
        w.account.pasteInvite(nil)
        #expect(w.account.inviteError != nil)
        w.account.pasteInvite("  code-9 \n")
        #expect(w.account.inviteCode == "code-9" && w.account.inviteError == nil)
        await w.account.submitInvite()
        #expect(!w.account.isInviteOpen && w.account.hasInvite && w.account.inviteCode == "" && w.notes.contains("Convite aceite") && w.account.isOnline)
    }

    @Test func aRefusedInviteExplainsWhy() async {
        let w = World(invite: nil)
        w.account.askInvite()
        w.account.inviteCode = "x"
        w.up = false
        await w.account.submitInvite()
        #expect(w.account.isInviteOpen && w.account.inviteError == "Sem ligação ao servidor. Verifique a rede e tente outra vez.")
    }

    @Test func renamingKeepsTheNewNameAndLogoutForgetsTheAccount() async {
        let w = World(invite: nil)
        #expect(await w.stems.tryInvite("ok") == .online)                      // um convite colado (nao o de fora): esse pode sair
        await w.account.refreshStatus()
        w.account.nameDraft = "Bia"
        await w.account.saveName()
        #expect(w.account.status?.name == "Bia" && w.account.nameDraft == "Bia" && w.notes.contains("Nome guardado") && w.account.nameError == nil)
        await w.start([w.job("a")])
        w.account.logout()
        #expect(!w.account.hasInvite && w.library.songs.isEmpty && w.account.isInviteOpen && w.account.status?.state == .unauthorized)
    }
}

@MainActor @Suite struct LibraryViewModelTests {
    @Test func filtersAndSortsAndOnlyRebuildsRowsWhenSomethingShownChanged() async {
        let w = World()
        await w.start([w.job("b", name: "Beta.mp3", created: 200), w.job("a", name: "alfa.mp3", created: 300), w.job("c", name: "Gama.mp3", created: 100)])
        #expect(w.library.shown.map(\.id) == ["b", "a", "c"] && w.library.countText == "Todas (3)")
        w.library.sort = .newestFirst
        #expect(w.library.shown.map(\.id) == ["a", "b", "c"] && w.library.sortText == "Data ↓")
        w.library.cycleSort()
        #expect(w.library.shown.map(\.id) == ["c", "b", "a"])
        w.library.cycleSort()
        #expect(w.library.shown.map(\.id) == ["a", "b", "c"] && w.library.sortText == "Título A–Z")
        w.library.search = " ALF "
        #expect(w.library.shown.map(\.id) == ["a"] && w.library.countText == "Todas (1)")
        w.library.search = ""
        let before = w.library.rows
        w.library.applyFilter()
        #expect(w.library.rows.first === before.first)                        // nada mudou: as mesmas linhas
        #expect(w.library.recent.count == 3)
    }

    @Test func offlineTheSavedListShowsDimmedAndTheNotOpenedOnesRefuseToOpen() async {
        let w = World()
        await w.start([w.job("a")])
        w.up = false
        await w.library.refresh(quiet: true)
        #expect(w.library.rows.count == 1 && w.library.rows[0].offline && w.library.rows[0].opacity == 0.45)
        let opened = await w.library.openOrFetch(w.library.songs[0])
        #expect(!opened && w.notes.last == "Sem servidor, e esta música ainda não foi guardada neste Mac.")
        w.up = true
        await w.library.refresh()
        #expect(w.notes.contains("De volta online"))
    }

    @Test func openingASongNotOnDiskDownloadsItThenOpensItByItself() async {
        let w = World()
        await w.start([w.job("a")])
        let first = await w.library.openOrFetch(w.library.songs[0])
        #expect(!first && w.notes.last == "A descarregar «a»: abre quando acabar" && w.library.rows[0].step == .fetch)
        await w.waitUntil { w.player.current != nil }
        #expect(w.played == ["a"] && w.shown == 1 && w.library.openId == "a" && w.library.rows[0].current && w.library.rows[0].saved)
        #expect(w.notes.contains("«a» guardada"))
    }

    @Test func aSongThatJustFinishedSeparatingIsDownloadedAtOnce() async {
        let w = World()
        await w.start([w.job("a", status: "processing")])
        #expect(w.library.rows[0].step == .separate)
        w.jobs = [w.job("a")]
        await w.library.refresh()
        await w.waitUntil { w.library.rows.first?.saved == true }
        #expect(w.library.rows[0].saved && w.player.current == nil)           // so descarrega, nao abre
    }

    @Test func downloadButtonSavesRemovesAndTheTwoPlacesAgree() async {
        let w = World()
        await w.start([w.job("a")])
        w.library.toggleDownload(w.library.rows[0])
        await w.waitUntil { w.library.rows[0].saved }
        #expect(w.library.rows[0].state == .saved && w.library.rows[0].sub == "2 stems · guardada")
        w.library.toggleDownload(w.library.rows[0])
        #expect(w.library.rows[0].state == .none)
        #expect(w.notes.last == "«a» removida do Mac")
    }

    @Test func deletingAskedThenConfirmedRemovesItAndClosesTheOpenSong() async {
        let w = World()
        await w.start([w.job("a"), w.job("b")])
        _ = await w.library.openOrFetch(w.library.songs[0]); await w.waitUntil { w.player.current != nil }
        w.library.askDeleteOpen()
        #expect(w.library.isDeleteOpen && w.library.deleteText.hasPrefix("«a» e todos os seus stems"))
        w.library.cancelDelete()
        #expect(!w.library.isDeleteOpen && w.jobs.count == 2)
        w.library.askDeleteOpen()
        await w.library.confirmDelete()
        #expect(w.player.current == nil && w.library.songs.map(\.id) == ["b"] && w.notes.contains("«a» apagada"))
        w.up = false
        await w.library.refresh(quiet: true)
        w.library.askDelete(w.library.songs[0])
        #expect(!w.library.isDeleteOpen && w.notes.last == "Sem servidor: apagar precisa de ligação.")
    }

    @Test func uploadShowsTheSongAtStepOneThenHandsItToTheServer() async throws {
        let w = World()
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID()).mp3")
        try Data("x".utf8).write(to: f)
        w.importer.add([PickedFile(name: "Nova.mp3", url: f), PickedFile(name: "Nova.mp3", url: f), PickedFile(name: "nota.txt", url: f)])
        #expect(w.importer.pending.map(\.name) == ["Nova.mp3"] && w.importer.hint == "2 ignorado(s): não é áudio ou já estava na lista.")
        w.importer.model = ImportViewModel.quality; w.importer.hiFi = false
        await w.importer.start()
        #expect(w.uploads == 1 && w.shown == 1 && !w.importer.isOpen && w.importer.pending.isEmpty && w.importer.startText == "Separar")
        #expect(w.library.shown.allSatisfy { !$0.isUploading })               // acabou: ja nao ha "a enviar"
    }

    @Test func importNeedsTheServerAndKeepsTheFiles() async {
        let w = World()
        w.up = false
        await w.library.refresh(quiet: true)
        w.importer.add([PickedFile(name: "a.mp3", url: URL(fileURLWithPath: "/dev/null")), PickedFile(name: "b.mp3", url: URL(fileURLWithPath: "/dev/null"))])
        #expect(w.importer.startText == "Separar 2 músicas")
        await w.importer.start()
        #expect(w.notes.last == "Sem servidor: importar precisa de ligação." && w.importer.pending.count == 2 && w.uploads == 0)
        w.importer.close()
        #expect(w.importer.pending.isEmpty && !w.importer.isOpen)
    }
}

@MainActor @Suite struct PlayerViewModelTests {
    func opened(_ w: World, stems: [String] = ["drums", "vocals"], bpm: Int? = 120) async -> Bool {
        await w.start([w.job("a", stems: stems, bpm: bpm)])
        return await w.player.play(w.library.songs[0])
    }

    @Test func playingASongLoadsTheStemsInTheServerOrderAndSumsThem() async throws {
        let w = World()
        #expect(await opened(w, stems: ["other", "vocals", "drums"]))
        let p = w.player!
        #expect(p.tops.map(\.name) == ["Bateria", "Vocais", "Outros"])
        #expect(p.isPlaying)
        #expect(p.hasSong && p.current?.id == "a")
        #expect(p.length == 1)
        #expect(p.infoText == "3 stems · Hi-Fi · 0:01 · 120 BPM" && p.total == "0:01")
        #expect(p.tops[0].peaks?.count == 1200 && p.tops[0].pcm?.count == 88200)
        var out = [Int16](repeating: 0, count: 4)
        out.withUnsafeMutableBufferPointer { p.mixer.fill($0.baseAddress!, frames: 2) }
        #expect(out == [5000, 5000, 5000, 5000])                              // 2000 (bateria) + 1000 (vocais) + 2000 (outros)
    }

    @Test func muteSoloAndResetChangeWhatIsHeardAndDimTheWave() async {
        let w = World()
        #expect(await opened(w))
        let p = w.player!, drums = p.tops[0], vocals = p.tops[1]
        p.toggleMute(drums)
        #expect(drums.dim == 0.25 && vocals.dim == 1)
        p.toggleSolo(vocals)
        #expect(drums.dim == 0.25 && vocals.dim == 1)
        p.toggleMute(drums); p.toggleSolo(vocals)
        #expect(drums.dim == 1 && vocals.dim == 1)
        drums.volume = 0.3; p.toggleMute(vocals); p.metronome.volume = 0.9
        await p.resetAll()
        #expect(drums.volume == 1 && !vocals.muted && p.metronome.volume == 0.25 && !p.isLooping && w.notes.last == "Configurações repostas")
    }

    @Test func transportScrubSeekAndTheEndOfTheSong() async throws {
        let w = World()
        #expect(await opened(w))
        let p = w.player!
        p.togglePlay()
        #expect(!p.isPlaying)
        p.beginScrub(0.5)
        #expect(p.isScrubbing && p.progress == 0.5)
        #expect(p.elapsed == "0:00")
        #expect(p.remaining == "-0:00")                                       // faltam 0,5 s: a musica tem 1 s
        p.tick()
        #expect(p.progress == 0.5)                                            // o tick nao mexe enquanto se arrasta
        p.endScrub(0.5)
        #expect(!p.isScrubbing && abs(p.position - 0.5) < 0.001 && abs(p.progress - 0.5) < 0.001)
        p.togglePlay()
        var out = [Int16](repeating: 0, count: 2 * 44100)
        out.withUnsafeMutableBufferPointer { p.mixer.fill($0.baseAddress!, frames: 44100) }   // toca o resto: o fim chega
        await w.waitUntil { !p.isPlaying }
        #expect(!p.isPlaying && p.progress == 1 && p.elapsed == "0:01")
    }

    @Test func theMarkedLoopOnPhoneIsStartThenEndThenOff() async throws {
        let w = World()
        #expect(await opened(w))
        let p = w.player!
        p.seek(0.2)
        p.toggleLoopMark()
        #expect(p.loopMark != nil && p.isLoopActive && !p.isLooping)
        p.seek(0.3)
        p.toggleLoopMark()                                                    // 0,1 s: curto demais
        #expect(!p.isLoopActive && w.notes.last == "Trecho demasiado curto")
        p.seek(0.2); p.toggleLoopMark(); p.seek(0.7); p.toggleLoopMark()
        #expect(p.isLooping && abs(p.loopStart - 0.2) < 0.001 && abs(p.loopEnd - 0.7) < 0.001 && abs(p.position - 0.2) < 0.001)
        p.toggleLoopMark()
        #expect(!p.isLooping && w.notes.last == "Repetição desligada")
        p.setLoop(0.8, 0.4)                                                   // arrastar ao contrario: o mesmo trecho
        #expect(p.isLooping && abs(p.loopStart - 0.4) < 0.001)
        p.clearLoop()
        #expect(!p.isLoopActive)
    }

    @Test func previousAndNextWalkTheShownDoneSongsWithoutWrapping() async {
        let w = World()
        await w.start([w.job("a"), w.job("b", status: "queued"), w.job("c")])
        _ = await w.player.play(w.library.songs[0])
        await w.player.next()
        await w.waitUntil { w.player.current?.id == "c" }
        #expect(w.player.current?.id == "c")
        await w.player.next()
        #expect(w.player.current?.id == "c")                                  // sem dar a volta
        w.player.seek(0.5)
        await w.player.previous()                                             // ja vai adiantada (> 3 s e dos 1 s da musica? nao: <3 s) volta a anterior
        await w.waitUntil { w.player.current?.id == "a" }
        #expect(w.player.current?.id == "a")
    }

    @Test func splittingTheDrumsReloadsWithThePartsOpenedAndKeepsThePosition() async {
        let w = World()
        #expect(await opened(w))
        w.player.expandPartsAfterSplit = true
        w.player.seek(0.4)
        #expect(w.player.tops[0].canSplit)
        w.jobs = [w.job("a", stems: ["drums", "vocals"]).replacingOccurrences(of: "\"format\"", with: "\"drum_stems\":[\"drum_kick\"],\"format\"")]
        await w.player.splitDrums()
        let drums = w.player.tops[0]
        #expect(drums.parts.map(\.name) == ["Bombo"] && drums.expanded && w.player.laneRows.map(\.name) == ["Bateria", "Bombo", "Vocais"] && !w.player.isSplitting)
        #expect(abs(w.player.position - 0.4) < 0.01)
        #expect(w.player.isPlaying)                                           // tocava: volta a tocar
        #expect(w.notes.last == "Bateria dividida")
        #expect(drums.parts[0].parent === drums && !drums.canSplit)
    }

    @Test func theBpmIsTheSpeedAndTheSubdivisionOnlyChangesTheClick() async {
        let w = World()
        #expect(await opened(w))
        let m = w.player.metronome, mixer = w.player.mixer
        m.saveDelay = .milliseconds(20)
        #expect(m.bpmText == "120" && !m.isOn && m.speed == 1 && mixer.rate == 1)
        m.bpmUp(); m.bpmUp(); m.bpmDown()
        #expect(m.bpmText == "121" && abs(m.bpm - 121) < 1e-9 && abs(mixer.rate - 121.0 / 120) < 1e-9)   // 121 BPM numa musica de 120: toca 0,8% mais depressa
        m.setBpm(60)
        #expect(m.speed == 0.5 && mixer.rate == 0.5 && m.bpmText == "60")
        m.double()                                                            // a subdivisao: o clique passa ao dobro, a musica nao muda de velocidade
        #expect(mixer.rate == 0.5 && m.speed == 0.5 && m.bpm == 120)
        m.setBpm(1000); #expect(m.bpm == 240 && m.bpmRange.upperBound == 240)  // o limite e 210, ou o da propria musica se for mais rapida
        m.setBpm(1); #expect(m.bpm == 30)
        await w.waitUntil { w.notes.contains("Tempo guardado") }               // so a subdivisao grava (a velocidade nao)
        #expect(w.patches.map(\.1) == ["{\"bpm\":240,\"downbeat_offset\":0}"])
    }

    @Test func theMetronomeSavesTheBarAndOfflineQueuesIt() async {
        let w = World()
        #expect(await opened(w))
        let m = w.player.metronome
        m.toggleClick()
        #expect(m.isOn && w.player.mixer.metronome)
        m.toggleSolo()
        #expect(m.isSolo && w.player.mixer.soloClick)
        m.toggleClick()
        #expect(!m.isOn && !m.isSolo && !w.player.mixer.soloClick)            // sem clique nao ha solo
        w.up = false
        await m.markBar()
        #expect(w.notes.last == "Tempo guardado offline: segue quando o servidor voltar")
    }

    @Test func resetGoesBackToTheTempoTheServerDetected() async {
        let w = World()
        #expect(await opened(w, bpm: 90))
        let m = w.player.metronome
        m.setBpm(200)
        #expect(m.speed > 2)
        await m.reset()
        #expect(m.bpm == 100 && m.bpmText == "100" && m.speed == 1 && w.player.mixer.rate == 1 && w.notes.last == "Configurações repostas")      // o servidor de mentira responde bpm 100
    }

    @Test func aSongWithoutStemsOnDiskAndWithoutServerFailsWithAWordForTheUser() async {
        let w = World()
        await w.start([w.job("a")])
        w.up = false
        let ok = await w.player.play(w.library.songs[0])
        #expect(!ok && w.notes.last == "Sem servidor, e esta música ainda não foi guardada neste Mac." && w.player.current == nil && !w.player.isLoading)
    }

    @Test func closingStopsAndEmptiesEverything() async {
        let w = World()
        #expect(await opened(w))
        w.player.close()
        #expect(w.player.current == nil && w.player.tracks.isEmpty && w.player.laneRows.isEmpty && w.player.length == 0 && !w.player.isPlaying && w.library.openId == nil)
    }

    @Test func theMixCanBeExportedAsOneWav() async {
        let w = World()
        #expect(await opened(w))
        let wav = w.player.renderMix()
        #expect(wav.count == 44 + 44100 * 4 && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
    }
}
