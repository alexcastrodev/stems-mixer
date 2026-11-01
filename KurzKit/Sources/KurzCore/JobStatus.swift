// Onde vai um job: queued e processing no servidor, depois done ou error. uploading so existe neste aparelho (a musica ainda a enviar).
// Os nomes no JSON ("done", "queued"...) so se conhecem em JobDTO.
public enum JobStatus: Sendable { case queued, processing, done, error, uploading }

// Como o servidor guarda (e serve) os stems de uma musica: WAV (antigos), FLAC (Hi-Fi, sem perdas) ou Opus (otimizado, mais leve).
public enum StemFormat: String, Sendable { case wav, flac, opus
    public var ext: String { rawValue }
}
