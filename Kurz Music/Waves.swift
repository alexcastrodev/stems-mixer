import KurzCore
import KurzPresentation
import SwiftUI

// A onda de um stem, espelhada a partir dos picos (0...1); a parte ja tocada mais clara. Tocar salta para ali; arrastar escolhe um trecho a repetir.
struct WaveformView: View {
    @Environment(AppModel.self) private var app
    let track: Track

    var body: some View {
        let peaks = track.peaks ?? [], progress = track.progress, dim = track.dim, color = Color(hex: track.lane)
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                var played = Path(), rest = Path()
                let px = progress * size.width
                for x in stride(from: 0.0, to: size.width, by: 2) {
                    let h = max(1, Double(peaks[min(peaks.count - 1, Int(x / size.width * Double(peaks.count)))]) * size.height * 0.9)
                    let r = CGRect(x: x, y: (size.height - h) / 2, width: 1.5, height: h)
                    if x < px { played.addRect(r) } else { rest.addRect(r) }
                }
                ctx.fill(rest, with: .color(Color(hex: "#0b2a33")))
                ctx.fill(played, with: .color(.white.opacity(0.85)))
                ctx.fill(Path(CGRect(x: px, y: 0, width: 1, height: size.height)), with: .color(.white))
            }
            .opacity(dim)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                let w = max(geo.size.width, 1), a = min(max(v.startLocation.x / w, 0), 1), b = min(max(v.location.x / w, 0), 1)
                if abs(v.location.x - v.startLocation.x) < 6 { app.player.seek(b) } else { app.player.setLoop(a, b) }
            })
        }
        .background(color)
    }
}

// A faixa do metronomo: um traco por batida (mais alto no 1.o tempo de cada compasso), na mesma escala das ondas.
struct BeatGridView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let map = app.player.metronome.map, duration = app.player.length, progress = app.player.progress
        GeometryReader { geo in
            Canvas { ctx, size in
                guard duration > 0 else { return }
                if size.width * 60 / map.bpm / duration >= 3 {           // batidas mais juntas que 3 px nao se distinguem
                    for i in map.times.indices {
                        let x = map.times[i] / duration * size.width, h = map.down[i] ? 0.6 : 0.3
                        var p = Path(); p.move(to: CGPoint(x: x, y: size.height * (1 - h) / 2)); p.addLine(to: CGPoint(x: x, y: size.height * (1 + h) / 2))
                        ctx.stroke(p, with: .color(map.down[i] ? Color(hex: "#6b717a") : Color(hex: "#3a3f47")), lineWidth: 1)
                    }
                }
                ctx.fill(Path(CGRect(x: progress * size.width, y: 0, width: 1, height: size.height)), with: .color(.white))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in app.player.seek(min(max(v.location.x / max(geo.size.width, 1), 0), 1)) })
        }
        .background(Color(hex: "#101114"))
    }
}

// Faixa de secoes (Intro, Verse, Chorus...): um bloco por secao, posicionado pelo tempo.
struct SectionStrip: View {
    let sections: [KurzCore.Section], duration: Double

    var body: some View {
        Canvas { ctx, size in
            guard duration > 0 else { return }
            for s in sections {
                let x = s.start / duration * size.width, w = (s.end - s.start) / duration * size.width
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Color(hex: "#2a2e35")))
                guard w >= 24, let first = s.label.first else { continue }
                let label = Text(String(first).uppercased() + s.label.dropFirst()).font(.system(size: 11)).foregroundStyle(Color(white: 0.86))
                ctx.draw(ctx.resolve(label), in: CGRect(x: x + 5, y: 0, width: w - 8, height: size.height))
            }
        }
        .background(Color(hex: "#181b20"))
    }
}

// O trecho em repeticao: uma faixa translucida por cima de todas as ondas.
struct LoopBand: View {
    let start: Double, end: Double
    var body: some View {
        GeometryReader { geo in
            if end > start {
                Rectangle().fill(.white.opacity(0.2)).frame(width: (end - start) * geo.size.width)
                    .overlay(alignment: .leading) { Rectangle().fill(.white).frame(width: 2) }
                    .overlay(alignment: .trailing) { Rectangle().fill(.white).frame(width: 2) }
                    .offset(x: start * geo.size.width)
            }
        }
        .allowsHitTesting(false)
    }
}

// A aba dos compassos: todos, a deslizar; segue a musica e tocar num compasso salta para ele.
struct BarsTab: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let p = app.player, m = p.metronome, beat = m.cell
        let cur = Int((beat / 4).rounded(.down)), inBar = Int((beat - Double(cur) * 4).rounded(.down))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(m.map.minBar..<max(m.map.barCount, m.map.minBar + 1), id: \.self) { b in
                        BarRow(bar: b, cur: cur, inBar: inBar).contentShape(Rectangle()).onTapGesture { p.seekBar(b) }.id(b)
                    }
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo(cur, anchor: .center) }
            .onChange(of: cur) { withAnimation { proxy.scrollTo(cur, anchor: .center) } }   // ponytail: segue sempre; se arrastares a lista enquanto toca, volta ao compasso atual no compasso seguinte
        }
    }
}

// Um compasso: o numero e os 4 tempos. No compasso atual os tempos ja tocados ficam cinzentos e o atual acende.
struct BarRow: View {
    let bar: Int, cur: Int, inBar: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("\(bar + 1)").font(.system(size: 13)).foregroundStyle(Color(white: 0.86)).frame(width: 36, alignment: .trailing).padding(.trailing, 8)
            ForEach(0..<4, id: \.self) { c in
                RoundedRectangle(cornerRadius: 4).fill(bar == cur ? (c < inBar ? Color(hex: "#4a4d55") : c == inBar ? Color(hex: "#e6e9f5") : Color(hex: "#25282d")) : Color(hex: "#25282d"))
                    .frame(height: 44)
            }
        }
    }
}
