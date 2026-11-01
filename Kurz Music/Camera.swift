import AVFoundation
#if os(macOS)
import Combine
import CoreAudio
#endif
import KurzPresentation
import Observation
import os
import Photos
import SwiftUI

// Filma com o som do microfone enquanto a musica toca e guarda na Fototeca o video com a musica juntada.
// So com auscultadores: com o altifalante a musica entrava no microfone (duas vezes no video).
@Observable final class Recorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private static let log = Logger(subsystem: "fyi.kurz.music", category: "camera")       // aparece na consola do Xcode
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCaptureMovieFileOutput()
    @ObservationIgnored private var camera: AVCaptureDeviceInput?
    @ObservationIgnored let preview: AVCaptureVideoPreviewLayer
    #if os(iOS)
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?            // diz a que angulo gravar e mostrar, conforme se segura o telemovel
    @ObservationIgnored private var rotationWatch: NSKeyValueObservation?
    #endif

    override init() {
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        super.init()
    }
    private(set) var isReady = false
    private(set) var isRecording = false
    private(set) var isSaving = false                          // parou de gravar; o video esta a ser juntado com a musica e guardado
    private(set) var headphones = false
    private(set) var recordsMic = true                         // gravar o som do microfone no video (so entao os auscultadores sao precisos)
    @ObservationIgnored private var micInput: AVCaptureDeviceInput?
    var needsHeadphones: Bool { recordsMic && !headphones }
    static let micGain: Float = 1.5, musicGain: Float = 0.8   // calibracao do video final: o microfone costuma soar baixo ao lado de uma musica masterizada
    private(set) var message: String?                          // o aviso por cima do botao de gravar
    // O que a camara de agora sabe fazer (muda ao trocar de camara).
    private(set) var zoom: CGFloat = 1                         // o zoom que se ve: 0,5× 1× 2× 5×...
    private(set) var lenses: [CGFloat] = []                    // as lentes da traseira, no mesmo valor (vazio na frontal)
    private(set) var is4K = false
    private(set) var can4K = false
    private(set) var centerStage = false                       // enquadramento automatico: segue quem filma (a frontal do iPad e do iPhone novo)
    private(set) var canCenterStage = false
    private(set) var torch = false
    private(set) var hasTorch = false
    private(set) var focusRing: CGPoint?                       // onde se tocou para focar
    private(set) var canRotate = false                         // a camara muda de proporcao (so a frontal quadrada do iPhone novo o faz)
    private(set) var horizontal = false                        // o quadro esta deitado
    @ObservationIgnored private var shown: CGFloat = 1         // zoom que se ve = zoom do dispositivo × isto (a ultra-grande-angular faz 0,5× no factor 1)
    // Onde a musica ia, a que velocidade, quanto os auscultadores a atrasam, e o ficheiro da mistura (feito em segundo plano enquanto se grava).
    @ObservationIgnored private var song: (from: Double, rate: Double, delay: Double, music: Task<URL?, Never>)?
    static let nudge = 0.0                                     // s: calibracao fina; positivo atrasa a musica no video, negativo adianta (o atraso dos auscultadores ja entra)

    // Pede as 3 licencas logo (camara, microfone, Fototeca: assim nada se pergunta a meio de guardar), abre a camara e passa o audio ao modo de gravacao.
    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video), await AVCaptureDevice.requestAccess(for: .audio) else {
            message = "Sem acesso à câmara ou ao microfone: ativa-os nos Ajustes."
            return
        }
        let photos = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard photos == .authorized || photos == .limited else {
            message = "Sem acesso à Fototeca: ativa-o nos Ajustes para guardar os vídeos."
            return
        }
        AVCaptureDevice.centerStageControlMode = .cooperative       // o botao liga-o, e o Centro de Controlo tambem
        do {
            #if os(iOS)
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, options: [.allowBluetoothA2DP, .defaultToSpeaker])   // A2DP: auscultadores Bluetooth mantem a qualidade, o microfone e o do iPhone; sem microfone a musica pode sair no altifalante
            try audio.setActive(true)
            session.automaticallyConfiguresApplicationAudioSession = false
            #endif
            session.beginConfiguration()
            try setCamera(.front)
            setMic(recordsMic)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        } catch { message = "Erro ao abrir a câmara: " + error.localizedDescription; return }
        refreshRoute()
        await Task.detached { [session] in session.startRunning() }.value
        isReady = session.isRunning
        refreshCapabilities()
        #if os(iOS)
        preview.connection?.videoRotationAngle = rotation?.videoRotationAngleForHorizonLevelPreview ?? 90
        setZoom(1)                                                                       // o 1× normal (nas 3 lentes o factor 1 seria o 0,5×)
        #endif
        if !isReady && message == nil { message = "A câmara não arrancou." }
    }

    // Fecha a camara e repoe a categoria da musica (em segundo plano: ambos bloqueiam).
    func stop() {
        guard !isRecording && !isSaving else { return }
        AVCaptureDevice.centerStageControlMode = .user
        #if os(iOS)
        setTorch(false)        #endif
        DispatchQueue.global().async { [session] in
            session.stopRunning()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            #endif
        }
    }

    func refreshRoute() {
        #if os(iOS)
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        headphones = !ports.isEmpty && !ports.contains { $0 == .builtInSpeaker || $0 == .builtInReceiver }
        #else
        headphones = Self.outputIsPrivate()
        #endif
    }

    #if os(macOS)
    // O som sai por auscultadores? A saida do Mac nao e a embutida (Bluetooth, USB, AirPlay...) ou e a embutida com a ficha de auscultadores.
    static func outputIsPrivate() -> Bool {
        func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: inout T) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        }
        var device = AudioDeviceID(0), transport = UInt32(0), source = UInt32(0)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &device),
              get(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport) else { return false }
        if transport != kAudioDeviceTransportTypeBuiltIn { return true }
        return get(device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, &source) && source == 0x6864_706E    // 'hdpn'
    }
    #endif

    // O sistema interrompeu ou parou a camara: mostra o codigo, para se saber o que foi.
    func sessionProblem(_ n: Notification) {
        #if os(iOS)
        let code = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? 0
        #else
        let code = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
        #endif
        message = n.name == AVCaptureSession.runtimeErrorNotification ? "Erro da câmara (\(code))." : "A câmara foi interrompida (motivo \(code))."
    }

    // Ligar ou desligar o microfone do video: sem ele o video so leva a musica (e nao ha eco, por isso nao pede auscultadores).
    func setMic(_ on: Bool) {
        recordsMic = on
        session.beginConfiguration()
        if on, micInput == nil, let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input); micInput = input
        } else if !on, let input = micInput {
            session.removeInput(input); micInput = nil
        }
        session.commitConfiguration()
    }

    // O nivel que o microfone capta agora (0 a 1), para se ver que esta mesmo a gravar.
    func micLevel() -> Double {
        let db = output.connection(with: .audio)?.audioChannels.map(\.averagePowerLevel).max() ?? -160
        return Double(max(0, min(1, (db + 60) / 60)))
    }

    private func setCamera(_ position: AVCaptureDevice.Position) throws {
        #if os(iOS)
        // A traseira e a virtual com todas as lentes que o aparelho tiver (3 no Pro/Pro Max): assim o zoom passa de uma a outra sozinho.
        let types: [AVCaptureDevice.DeviceType] = position == .back ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera] : [.builtInWideAngleCamera]
        // A frontal "Center Stage" do iPhone novo (sensor quadrado, muda de proporcao) e a ultra-grande-angular da frente, nao a grande-angular.
        let square = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front).flatMap { position == .front && $0.formats.contains { !$0.supportedDynamicAspectRatios.isEmpty } ? $0 : nil }
        guard let device = square ?? types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: position) }).first else { return }
        #else
        guard let device = AVCaptureDevice.default(for: .video) else { return }              // a camara do Mac (ou o iPhone, como camara)
        #endif
        let input = try AVCaptureDeviceInput(device: device)
        if let old = camera { session.removeInput(old) }
        if session.canAddInput(input) {
            session.addInput(input); camera = input
            is4K = is4K && device.supportsSessionPreset(.hd4K3840x2160)
            session.sessionPreset = is4K ? .hd4K3840x2160 : .high
            #if os(iOS)
            watchRotation(device)
            #endif
        }
    }

    // O que a camara de agora permite: 4K, Center Stage (no iPad a frontal fica bem na horizontal), e no iPhone as lentes e a lanterna.
    private func refreshCapabilities() {
        guard let d = camera?.device else { return }
        can4K = d.supportsSessionPreset(.hd4K3840x2160)
        canCenterStage = d.formats.contains(where: \.isCenterStageSupported)
        centerStage = canCenterStage && AVCaptureDevice.isCenterStageEnabled
        #if os(iOS)
        let over = d.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        shown = d.constituentDevices.first?.deviceType == .builtInUltraWideCamera ? 1 / (over.first ?? 1) : 1
        hasTorch = d.hasTorch
        // A frontal quadrada so muda de proporcao em alguns formatos (o de 4032 so faz 4:3): escolhe-se um que faca 16:9 e 9:16, o mais perto de 1080p, a 30 fps.
        // Nada de 4K nem 60 fps aqui: um sensor quadrado de 14 MP a gravar com a musica, o microfone e a estabilizacao era carga a mais.
        func ok(_ f: AVCaptureDevice.Format) -> Bool { f.supportedDynamicAspectRatios.contains(.ratio16x9) && f.supportedDynamicAspectRatios.contains(.ratio9x16) }
        if d.position == .front, !ok(d.activeFormat), (try? d.lockForConfiguration()) != nil {
            let fits = d.formats.filter { ok($0) && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 } }
            if let best = fits.min(by: { abs(Int($0.formatDescription.dimensions.width) - 1920) < abs(Int($1.formatDescription.dimensions.width) - 1920) }) {
                d.activeFormat = best
                d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                let size = best.formatDescription.dimensions
                Self.log.info("frontal quadrada: formato \(size.width)x\(size.height), 30 fps, \(fits.count) formatos serviam")
            }
            d.unlockForConfiguration()
        }
        let ratios = d.activeFormat.supportedDynamicAspectRatios
        canRotate = !ratios.isEmpty
        if canRotate { can4K = false; is4K = false }
        preview.videoGravity = canRotate ? .resizeAspect : .resizeAspectFill                 // o que se ve e o que fica gravado, com margens se for preciso
        reframe()
        guard d.position == .back else { lenses = []; return }
        var stops: Set<CGFloat> = [1, 2]
        if d.minAvailableVideoZoomFactor * shown < 0.9 { stops.insert(d.minAvailableVideoZoomFactor * shown) }       // 0,5×
        stops.formUnion(over.map { $0 * shown }.filter { $0 > 1.5 })                                               // a teleobjetiva: 3×, 4× ou 5×
        lenses = stops.sorted()
        #endif
    }

    // 4K e Center Stage nao andam juntos (o Center Stage so existe em formatos mais pequenos).
    func set4K(_ on: Bool) {
        if on { setCenterStage(false) }
        session.beginConfiguration()
        is4K = on && can4K
        session.sessionPreset = is4K ? .hd4K3840x2160 : .high
        session.commitConfiguration()
        refreshCapabilities()                                                              // o formato mudou
    }

    func setCenterStage(_ on: Bool) {
        guard canCenterStage || !on else { return }
        if on && is4K { set4K(false) }
        AVCaptureDevice.isCenterStageEnabled = on
        centerStage = on
        guard on, let d = camera?.device else { return }
        Task { try? await Task.sleep(for: .seconds(0.6)); centerStage = d.isCenterStageActive }       // se o formato nao o deixar, o botao apaga-se
    }

    // Tocar no ecra: foca e mede a luz ali.
    func focus(at point: CGPoint) {
        guard let d = camera?.device, d.isFocusPointOfInterestSupported || d.isExposurePointOfInterestSupported,
              (try? d.lockForConfiguration()) != nil else { return }
        let p = preview.captureDevicePointConverted(fromLayerPoint: point)
        if d.isFocusPointOfInterestSupported && d.isFocusModeSupported(.continuousAutoFocus) { d.focusPointOfInterest = p; d.focusMode = .continuousAutoFocus }
        if d.isExposurePointOfInterestSupported && d.isExposureModeSupported(.continuousAutoExposure) { d.exposurePointOfInterest = p; d.exposureMode = .continuousAutoExposure }
        d.unlockForConfiguration()
        focusRing = point
        Task { try? await Task.sleep(for: .seconds(0.8)); focusRing = nil }
    }

    #if os(iOS)
    func toggleHorizontal() {
        horizontal.toggle()
        reframe()
    }

    // Pede a proporcao que da, no video final, vertical ou horizontal: so o botao a muda, rodar o telemovel nao. O buffer sai na orientacao do sensor e roda-se
    // com o angulo da gravacao (por isso ao rodar o telemovel volta a pedir-se, para o video final ficar igual). `wide` diz que buffer se quer; depois confere-se
    // pelo tamanho real e, se vier ao contrario, troca-se.
    private func reframe(wide forced: Bool? = nil, retry: Bool = true) {
        guard let d = camera?.device, !isRecording, !d.activeFormat.supportedDynamicAspectRatios.isEmpty else { return }
        let turned = Int(rotation?.videoRotationAngleForHorizonLevelCapture ?? 90) % 180 != 0       // o sensor da frontal nova esta montado em pe, a do iPhone antigo deitado: o angulo ja conta com isso
        let wide = forced ?? (horizontal != turned)
        let options: [AVCaptureDevice.AspectRatio] = wide ? [.ratio16x9, .ratio4x3] : [.ratio9x16, .ratio3x4]
        guard let ratio = options.first(where: d.activeFormat.supportedDynamicAspectRatios.contains), (try? d.lockForConfiguration()) != nil else { return }
        d.setDynamicAspectRatio(ratio) { [weak self] _, _ in
            let size = d.dynamicDimensions
            Task { @MainActor in
                if retry, (size.width > size.height) != wide { self?.reframe(wide: !wide, retry: false) }
            }
        }
        d.unlockForConfiguration()
    }

    // `value`: o zoom que se ve (0,5× 1× 2×...). `smooth`: desliza em vez de saltar (os botoes das lentes).
    func setZoom(_ value: CGFloat, smooth: Bool = false) {
        guard let d = camera?.device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        let factor = min(max(value / shown, d.minAvailableVideoZoomFactor), min(d.maxAvailableVideoZoomFactor, 30 / shown))
        if smooth { d.ramp(toVideoZoomFactor: factor, withRate: 4) } else { d.videoZoomFactor = factor }
        zoom = factor * shown
    }

    func setTorch(_ on: Bool) {
        guard let d = camera?.device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        if on { try? d.setTorchModeOn(level: 1) } else { d.torchMode = .off }
        torch = d.torchMode == .on
    }

    func flip() {
        setTorch(false)
        session.beginConfiguration()
        try? setCamera(camera?.device.position == .front ? .back : .front)
        session.commitConfiguration()
        refreshCapabilities()
        setZoom(1)
    }

    // A pre-visualizacao acompanha o telemovel (em pe ou deitado); o mesmo angulo grava-se no video ao comecar.
    private func watchRotation(_ device: AVCaptureDevice) {
        let c = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotation = c
        rotationWatch = c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.preview.connection?.videoRotationAngle = angle; self?.reframe() }   // ao rodar, o "como seguras" muda de proporcao
        }
    }
    #endif

    // Gravar / parar. `position`: onde a musica vai (s) ao comecar; `mix`: a mistura de agora, que se faz em segundo plano enquanto se grava.
    func toggle(at position: Double, rate: Double, mix: @escaping @Sendable () -> Data) {
        if isRecording {
            output.stopRecording()
            (isRecording, isSaving, message) = (false, true, "A guardar o vídeo…")        // logo: o resto demora
            return
        }
        guard isReady, !needsHeadphones, !isSaving else { return }
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        let latency = audio.outputLatency + audio.ioBufferDuration
        #else
        let latency = 0.0                                                                  // ponytail: o atraso da saida do Mac nao se mede; ajusta-se com `nudge`
        #endif
        let music = Task.detached(priority: .userInitiated) { () -> URL? in
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
            do { try mix().write(to: url); return url } catch { return nil }
        }
        song = (position, rate, latency + Self.nudge, music)   // quem toca ouve a musica com este atraso, e toca por cima do que ouve
        #if os(iOS)
        if let c = output.connection(with: .video) {                                     // o angulo de agora: em pe ou deitado
            let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .standard }   // a do cinema pesa mais e atrasa o video: aqui a camara tambem tem a musica a tocar
            Self.log.info("a gravar: angulo \(c.videoRotationAngle), estabilizacao \(c.preferredVideoStabilizationMode.rawValue), temperatura \(ProcessInfo.processInfo.thermalState.rawValue)")
        }
        #endif
        output.startRecording(to: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov"), recordingDelegate: self)
        isRecording = true
        message = nil
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        Task { @MainActor in await finish(url, finished: finished, error: error) }
    }

    private func finish(_ url: URL, finished: Bool, error: Error?) async {
        (isRecording, isSaving) = (false, true)
        defer { isSaving = false }
        let music = await song?.music.value
        defer { if let music { try? FileManager.default.removeItem(at: music) } }
        guard finished else {
            let e = error as NSError?
            message = "Erro ao gravar (\(e?.code ?? 0)): " + (e?.localizedDescription ?? "")
            try? FileManager.default.removeItem(at: url)
            return
        }
        message = "A juntar a música…"
        var file = url, note = "Vídeo guardado na Fototeca"
        if let song, let music {
            do { file = try await Self.withMusic(video: url, music: music, from: song.from, rate: song.rate, delay: song.delay) }
            catch { note = "Vídeo guardado sem a música: " + error.localizedDescription }
        }
        message = "A guardar na Fototeca…"
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file) }
            message = note
            try? FileManager.default.removeItem(at: url)
            if file != url { try? FileManager.default.removeItem(at: file) }
        } catch { message = "Não deu para guardar o vídeo: " + error.localizedDescription }    // o ficheiro fica, para nao se perder a gravacao
    }

    // O video (com o som do microfone) e, por baixo, a musica (um WAV) a partir de `from` (s), tocada a `rate` vezes a velocidade e atrasada `delay` (s). Devolve o ficheiro novo.
    private static func withMusic(video: URL, music: URL, from: Double, rate: Double, delay: Double) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        let movie = AVURLAsset(url: video), song = AVURLAsset(url: music), comp = AVMutableComposition()
        let length = try await movie.load(.duration).seconds
        @discardableResult func add(_ type: AVMediaType, from asset: AVURLAsset, start: Double, seconds: Double, at: Double, speed: Double = 1) async throws -> AVMutableCompositionTrack? {
            guard seconds > 0, let src = try await asset.loadTracks(withMediaType: type).first,
                  let dst = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            try dst.insertTimeRange(CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: seconds, preferredTimescale: 600)),
                                    of: src, at: CMTime(seconds: at, preferredTimescale: 600))
            if type == .video { dst.preferredTransform = try await src.load(.preferredTransform) }
            if speed != 1 { dst.scaleTimeRange(CMTimeRange(start: CMTime(seconds: at, preferredTimescale: 600), duration: CMTime(seconds: seconds, preferredTimescale: 600)), toDuration: CMTime(seconds: seconds / speed, preferredTimescale: 600)) }
            return dst
        }
        try await add(.video, from: movie, start: 0, seconds: length, at: 0)
        let mic = try await add(.audio, from: movie, start: 0, seconds: length, at: 0)              // nil se o microfone estava desligado
        let left = try await song.load(.duration).seconds
        let start = delay < 0 ? from - delay * rate : from, at = max(delay, 0)             // atraso negativo: a musica entra ja adiantada
        let music = try await add(.audio, from: song, start: start, seconds: min((length - at) * rate, left - start), at: at, speed: rate)   // a `rate`, o video leva mais ou menos musica
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw CocoaError(.fileWriteUnknown) }
        if let source = try await movie.loadTracks(withMediaType: .video).first, let track = comp.tracks(withMediaType: .video).first {
            let transform = try await source.load(.preferredTransform), size = try await source.load(.naturalSize), fps = try await source.load(.nominalFrameRate)
            let shown = CGRect(origin: .zero, size: size).applying(transform)             // o tamanho ja virado: em pe ou deitado
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            instruction.layerInstructions = [layer]
            let video = AVMutableVideoComposition()
            video.renderSize = CGSize(width: abs(shown.width), height: abs(shown.height))
            video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps.rounded() : 30))
            video.instructions = [instruction]
            export.videoComposition = video                                               // sem isto o video sai virado de lado
        }
        let mix = AVMutableAudioMix()                                                     // com a mistura explicita, as duas faixas de som saem somadas numa so
        mix.inputParameters = [(mic, Self.micGain), (music, Self.musicGain)].compactMap { track, gain in
            track.map { t in let p = AVMutableAudioMixInputParameters(track: t); p.setVolume(gain, at: .zero); return p }
        }
        export.audioMix = mix
        export.audioTimePitchAlgorithm = .spectral                                       // a musica esticada mantem o tom
        try await export.export(to: out, as: .mov)
        return out
    }
}

// A camara ao vivo: a camada de pre-visualizacao do Recorder, a ocupar a vista.
#if os(iOS)
struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    final class Host: UIView {
        var preview: CALayer?
        override func layoutSubviews() { super.layoutSubviews(); preview?.frame = bounds }
    }
    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.layer.addSublayer(layer)
        v.preview = layer
        return v
    }
    func updateUIView(_ v: Host, context: Context) {}
}
#else
struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    final class Host: NSView {
        var preview: CALayer?
        override func layout() { super.layout(); preview?.frame = bounds }
    }
    func makeNSView(context: Context) -> Host {
        let v = Host()
        v.wantsLayer = true
        v.layer?.addSublayer(layer)
        v.preview = layer
        return v
    }
    func updateNSView(_ v: Host, context: Context) {}
}
#endif

extension View {
    // A camara por cima de tudo: ecra inteiro no iPhone e no iPad, folha no Mac.
    func cameraCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { CameraView() }
        #else
        sheet(isPresented: isPresented) { CameraView() }
        #endif
    }
}

// O ecra de filmar: a camara, gravar (a musica toca e para com o video) e o transporte da musica por baixo.
struct CameraView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rec = Recorder()
    #if os(iOS)
    @State private var pinch: CGFloat?                                                          // o zoom de quando a pinca comecou

    // Como na Camara: um toque deita ou levanta o quadro da frontal sem rodar o telemovel.
    private var rotateButton: some View {
        Button { rec.toggleHorizontal() } label: {
            Image(systemName: rec.horizontal ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate").font(.system(size: 20, weight: .medium)).foregroundStyle(K.text)
                .frame(width: 48, height: 48).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).disabled(rec.isRecording || rec.isSaving)
        .accessibilityLabel(rec.horizontal ? "Filmar na vertical" : "Filmar na horizontal")
    }

    // 0,5× 1× 2× 5×: a lente de agora (a mais proxima) mostra o zoom exato, p. ex. "3,2×" no meio de uma pinca.
    private var lensPicker: some View {
        let near = rec.lenses.min { abs($0 - rec.zoom) < abs($1 - rec.zoom) }
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(rec.lenses, id: \.self) { lens($0, on: $0 == near) }
            }
            .padding(4).glassEffect(.regular, in: Capsule())
        }
    }

    private func lens(_ v: CGFloat, on: Bool) -> some View {
        let text: String = Double(on ? rec.zoom : v).formatted(.number.precision(.fractionLength(0...1))) + "×"
        return Button { rec.setZoom(v, smooth: true) } label: {
            Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(on ? K.accentText : K.text)
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(on ? .regular.tint(K.accent.opacity(0.35)).interactive() : .identity, in: Circle())
        .accessibilityLabel("Zoom " + text)
    }
    #endif

    var body: some View {
        let p = app.player
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(layer: rec.preview).ignoresSafeArea()
                .overlay {
                    if let p = rec.focusRing { RoundedRectangle(cornerRadius: 6).stroke(K.accent, lineWidth: 2).frame(width: 72, height: 72).position(p) }
                }
                .onTapGesture { rec.focus(at: $0) }                                              // tocar foca
                #if os(iOS)
                .gesture(MagnifyGesture().onChanged { v in                                       // a pinca faz zoom
                    let from = pinch ?? rec.zoom
                    pinch = from
                    rec.setZoom(from * v.magnification)
                }.onEnded { _ in pinch = nil })
                #endif
            VStack {
                HStack(spacing: 4) {
                    IconButton(system: "xmark", label: "Fechar a câmara") { dismiss() }.disabled(rec.isRecording || rec.isSaving)
                    Spacer()
                    #if os(iOS)
                    if rec.hasTorch {
                        IconButton(system: rec.torch ? "flashlight.on.fill" : "flashlight.off.fill", label: rec.torch ? "Apagar a lanterna" : "Acender a lanterna", on: rec.torch) { rec.setTorch(!rec.torch) }
                    }
                    #endif
                    if rec.can4K {
                        IconButton(system: rec.is4K ? "4k.tv.fill" : "4k.tv", label: rec.is4K ? "Gravar em HD" : "Gravar em 4K", on: rec.is4K) { rec.set4K(!rec.is4K) }
                            .disabled(rec.isRecording || rec.isSaving)
                    }
                    if rec.canCenterStage {
                        IconButton(system: "person.fill.viewfinder", label: rec.centerStage ? "Desligar o Center Stage" : "Ligar o Center Stage", on: rec.centerStage) { rec.setCenterStage(!rec.centerStage) }
                            .disabled(rec.isRecording || rec.isSaving)
                    }
                    IconButton(system: rec.recordsMic ? "mic.fill" : "mic.slash.fill", label: rec.recordsMic ? "Desligar o microfone" : "Ligar o microfone", on: rec.recordsMic) { rec.setMic(!rec.recordsMic) }
                        .disabled(rec.isRecording || rec.isSaving)
                    #if os(iOS)
                    IconButton(system: "arrow.triangle.2.circlepath.camera", label: "Trocar de câmara") { rec.flip() }.disabled(rec.isRecording || rec.isSaving)
                    #endif
                }
                Spacer()
                #if os(iOS)
                if rec.canRotate { rotateButton }
                if rec.lenses.count > 1 { lensPicker }
                #endif
                if rec.recordsMic && rec.isReady {                                               // o nivel do microfone: se mexe, esta a gravar
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let level = rec.micLevel()
                        Capsule().fill(.white.opacity(0.25)).frame(width: 140, height: 6)
                            .overlay(alignment: .leading) { Capsule().fill(level > 0.9 ? K.danger : K.done).frame(width: 140 * level) }
                    }
                }
                if let hint = rec.message ?? (rec.needsHeadphones ? "Use auscultadores para gravar o microfone, ou desligue-o" : nil) {
                    Label { Text(hint) } icon: { if rec.isSaving { ProgressView() } else { Image(systemName: "headphones") } }.font(.system(size: 14)).foregroundStyle(.black).padding(.horizontal, 16).padding(.vertical, 10).background(.white, in: Capsule())
                }
                Button {
                    let was = rec.isRecording
                    rec.toggle(at: p.position, rate: p.metronome.speed, mix: p.mixRenderer())
                    if rec.isRecording && !p.isPlaying { p.togglePlay() }          // grava e toca juntos
                    else if was && p.isPlaying { p.togglePlay() }
                } label: {
                    Circle().fill(rec.isRecording ? Color.white : K.danger).frame(width: 64, height: 64)
                        .overlay { if rec.isRecording { RoundedRectangle(cornerRadius: 6).fill(K.danger).frame(width: 24, height: 24) } }
                        .padding(4).overlay(Circle().stroke(.white, lineWidth: 3))
                }
                .buttonStyle(.plain).disabled(!rec.isReady || rec.needsHeadphones || rec.isSaving).opacity(!rec.needsHeadphones && !rec.isSaving ? 1 : 0.5)
                .accessibilityLabel(rec.isRecording ? "Parar de gravar" : "Gravar")
                PlaybackRow().padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 640)
        #endif
        .task { await rec.start() }
        .onDisappear { rec.stop() }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in rec.refreshRoute() }        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification, object: rec.session)) { rec.sessionProblem($0) }
        #else
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in rec.refreshRoute() }       // o Mac nao avisa quando se ligam os auscultadores
        #endif
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: rec.session)) { rec.sessionProblem($0) }
    }
}
