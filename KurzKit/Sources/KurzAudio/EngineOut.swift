import AVFoundation

// A saida de som do sistema: um AVAudioEngine com uma fonte que puxa do mixer. Igual no Mac, no iPad e no iPhone.
public final class EngineOut: AudioOut {
    public var pull: Pull?
    let engine = AVAudioEngine()
    let timePitch = AVAudioUnitTimePitch()                          // estica ou encolhe o tempo sem mudar o tom
    var configured = false
    var wanted = false                                              // o utilizador quer som: se o sistema parar o motor (mudanca de rota, de categoria), volta-se a ligar
    static let maxFrames = 4096
    let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: maxFrames * 2)

    public init() {}
    deinit { engine.stop(); scratch.deallocate() }

    // Guardada: perguntar ao motor a cada tick (20 vezes por segundo, da UI) podia atrapalhar o fio de audio. Atualiza-se ao tocar e quando o sistema reconfigura.
    public private(set) var latency = 0.0
    public var rate: Double {
        get { Double(timePitch.rate) }
        set { timePitch.rate = Float(newValue); timePitch.bypass = newValue == 1; if configured { refreshLatency() } }   // a 1.0 passa direto: sem custo nem latencia
    }
    func refreshLatency() { latency = engine.outputNode.presentationLatency + (timePitch.bypass ? 0 : timePitch.auAudioUnit.latency) }
    var sessionReady = false                                       // a sessao so se configura uma vez (e depois de uma interrupcao): cada chamada bloqueia o fio principal

    // A ativacao da sessao bloqueia quem a chama: faz-se aqui, em segundo plano, quando o mixer abre; o 1.o "tocar" ja a encontra pronta.
    public func prepare() {
        #if os(iOS)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, (try? setUpSession()) != nil else { return }
            DispatchQueue.main.async { self.sessionReady = true }
        }
        #endif
    }

    #if os(iOS)
    func setUpSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord { return }           // a camara esta a gravar: qualquer mudanca na sessao interrompe-a
        try session.setCategory(.playback)                         // a musica continua com o ecra bloqueado (UIBackgroundModes: audio)
        try? session.setPreferredIOBufferDuration(0.04)            // folga contra picos da UI (a latencia que isto traz ja entra em `latency`)
        try session.setActive(true)
    }
    #endif

    public func play() throws {
        #if os(iOS)
        if !sessionReady { try setUpSession(); sessionReady = true }   // se o prepare ainda nao acabou (ou depois de uma interrupcao)
        #endif
        if !configured { configure() }
        wanted = true
        if !engine.isRunning { try engine.start() }
        refreshLatency()
    }

    public func pause() { wanted = false; engine.pause() }

    func configure() {
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioFile.rate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            var done = 0
            while done < Int(frames) {
                let n = min(Int(frames) - done, Self.maxFrames)
                if let pull { pull(scratch, n) } else { scratch.update(repeating: 0, count: n * 2) }
                for (ch, buffer) in buffers.enumerated() where ch < 2 {
                    let dst = buffer.mData!.assumingMemoryBound(to: Float.self) + done
                    for i in 0..<n { dst[i] = Float(scratch[i * 2 + ch]) / 32768 }
                }
                done += n
            }
            return noErr
        }
        engine.attach(source)
        engine.attach(timePitch)
        engine.connect(source, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, wanted, !engine.isRunning else { return }
            try? engine.start()
            refreshLatency()
        }
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            if n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue { self?.sessionReady = false }   // uma chamada: o proximo play reativa a sessao
        }
        #endif
        configured = true
    }
}
