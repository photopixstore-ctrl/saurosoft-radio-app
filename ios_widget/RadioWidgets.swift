import SwiftUI
import UIKit
import WidgetKit

// Widget "In onda" di Saurosoft Radio: titolo, artista e copertina del brano che si sta
// ASCOLTANDO (non quello appena letto dal server: l'app lo scrive quando lo mostra anche
// sul telefono e in CarPlay, cioe' con il ritardo del buffer).
// Solo la famiglia systemSmall: e' l'unica visibile in CarPlay.
//
// Dati: l'app (AppDelegate.swift, WidgetBridge) scrive nell'App Group
//   title, artist (testi), hasCover (bool) e il file cover.jpg (copertina ridotta a ~300 px)
// e chiede a iOS di ricaricare il widget a ogni cambio brano. Il widget non usa la rete.

@main
struct RadioWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RadioNowPlayingWidget()
    }
}

// MARK: - Dati condivisi con l'app

enum RadioShared {
    static let groupId = "group.it.photopix.saurosoft-radio"
    static let kind = "RadioNowPlayingWidget"
    static let coverFile = "cover.jpg"
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

/// Colori fissi e leggibili anche senza sfondo (in CarPlay il sistema toglie lo sfondo del widget).
enum RadioColors {
    static let background = Color(hex: 0x131922)
    static let card = Color(hex: 0x1A212B)
    static let accent = Color(hex: 0xF5A623)
    static let text = Color(hex: 0xF4F6F8)
    static let dim = Color(hex: 0xB3BDCA)
    static let calendar = Color(hex: 0x4FC3F7)
}

struct RadioEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let cover: UIImage?

    /// L'app manda l'artista come "Nome (1991)": nome e anno si separano qui, nel widget.
    /// L'anno e' valido solo se sono 4 cifre tra parentesi in fondo al testo.
    var artistName: String {
        guard let r = artist.range(of: #"\s*\((\d{4})\)\s*$"#, options: .regularExpression) else { return artist }
        let name = String(artist[artist.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? artist : name
    }

    var year: String? {
        guard let r = artist.range(of: #"\((\d{4})\)\s*$"#, options: .regularExpression) else { return nil }
        let digits = artist[r].filter { $0.isNumber }
        guard !artistName.isEmpty, artistName != artist else { return nil }
        return String(digits)
    }

    static let sample = RadioEntry(date: Date(), title: "Titolo del brano", artist: "Artista (1986)", cover: nil)

    static func load() -> RadioEntry {
        guard let defaults = UserDefaults(suiteName: RadioShared.groupId) else {
            return RadioEntry(date: Date(), title: "Saurosoft Radio", artist: "Tocca per ascoltare", cover: nil)
        }
        func text(_ key: String) -> String {
            (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var title = text("title")
        var artist = text("artist")
        if title.isEmpty {
            title = "Saurosoft Radio"
            if artist.isEmpty { artist = "Tocca per ascoltare" }
        }
        var cover: UIImage? = nil
        if defaults.bool(forKey: "hasCover"),
            let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RadioShared.groupId)
        {
            cover = UIImage(contentsOfFile: dir.appendingPathComponent(RadioShared.coverFile).path)
        }
        return RadioEntry(date: Date(), title: title, artist: artist, cover: cover)
    }
}

// MARK: - Timeline

/// L'app chiede il ricarico a ogni cambio brano (reloadTimelines). Come rete di sicurezza si
/// chiede comunque un giro ogni 30 minuti.
struct RadioProvider: TimelineProvider {
    func placeholder(in context: Context) -> RadioEntry {
        RadioEntry.sample
    }

    func getSnapshot(in context: Context, completion: @escaping (RadioEntry) -> Void) {
        completion(context.isPreview ? RadioEntry.sample : RadioEntry.load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RadioEntry>) -> Void) {
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [RadioEntry.load()], policy: .after(next)))
    }
}

// MARK: - Grafica

struct RadioCover: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        if let image = image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(RadioColors.card)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(RadioColors.accent)
                )
        }
    }
}

/// Logo di Saurosoft Radio (il dinosauro con le cuffie), 120 px, incorporato nel codice:
/// cosi' l'estensione non dipende da risorse da aggiungere al progetto.
enum RadioLogo {
    static let image: UIImage? = {
        let b64 = """
        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
        """
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }()
}

struct RadioWidgetView: View {
    let entry: RadioEntry

    private static let pad: CGFloat = 8
    private static let gap: CGFloat = 3
    private static let colGap: CGFloat = 8
    private static let titleSize: CGFloat = 13
    private static let artistSize: CGFloat = 12
    /// Spazio fisso di DUE righe di titolo (13 pt): se il titolo ne occupa una sola, la seconda
    /// resta vuota, cosi' l'artista sta sempre nella riga piu' bassa.
    private static let titleBoxH: CGFloat = 32
    private static let artistH: CGFloat = 14
    /// Larghezza di onde e logo (stessa misura); colonna a destra della copertina = 2 icone + spazio.
    private static let iconW: CGFloat = 20
    private static let logoSize: CGFloat = 40
    private static let iconGap: CGFloat = 5

    /// La copertina prende tutto lo spazio che resta sopra le due righe del titolo e la riga
    /// dell'artista, senza togliere alla colonna di destra (onde + logo) la larghezza che serve.
    private func coverSide(_ size: CGSize) -> CGFloat {
        let innerW = size.width - 2 * RadioWidgetView.pad
        let innerH = size.height - 2 * RadioWidgetView.pad
        let byHeight = innerH - RadioWidgetView.titleBoxH - RadioWidgetView.artistH - 2 * RadioWidgetView.gap
        let rightMin = 2 * RadioWidgetView.iconW + RadioWidgetView.iconGap + 1
        let byWidth = innerW - RadioWidgetView.colGap - rightMin
        return max(min(byHeight, byWidth, 110), 60)
    }

    var body: some View {
        GeometryReader { geo in
            let side = coverSide(geo.size)
            VStack(alignment: .leading, spacing: RadioWidgetView.gap) {
                HStack(alignment: .top, spacing: RadioWidgetView.colGap) {
                    RadioCover(image: entry.cover, size: side)
                    VStack(alignment: .leading, spacing: 4) {
                        // Logo del dinosauro, grande il doppio di prima.
                        if let logo = RadioLogo.image {
                            Image(uiImage: logo)
                                .resizable()
                                .scaledToFill()
                                .frame(width: RadioWidgetView.logoSize, height: RadioWidgetView.logoSize)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(RadioColors.accent)
                                .frame(width: 13, height: 13)
                            Text("IN ONDA")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(RadioColors.dim)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        // Anno del brano: calendario + (anno). Senza anno la riga non compare.
                        if let year = entry.year {
                            HStack(spacing: 3) {
                                Image(systemName: "calendar")
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundColor(RadioColors.calendar)
                                    .frame(width: 12, height: 12)
                                Text("(\(year))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(RadioColors.dim)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Titolo: sempre due righe di spazio; piu' e' lungo piu' si rimpicciolisce (mai tagliato).
                Text(entry.title)
                    .font(.system(size: RadioWidgetView.titleSize, weight: .bold, design: .rounded))
                    .foregroundColor(RadioColors.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: RadioWidgetView.titleBoxH,
                           maxHeight: RadioWidgetView.titleBoxH, alignment: .topLeading)
                Spacer(minLength: 0)
                // Artista (senza anno, che sta sotto "IN ONDA"): una riga sola, sempre in fondo; se e' lungo si rimpicciolisce.
                Text(entry.artistName)
                    .font(.system(size: RadioWidgetView.artistSize, weight: .regular))
                    .foregroundColor(RadioColors.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity, minHeight: RadioWidgetView.artistH,
                           maxHeight: RadioWidgetView.artistH, alignment: .leading)
            }
            .padding(RadioWidgetView.pad)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .containerBackground(for: .widget) { RadioColors.background }
    }
}

struct RadioNowPlayingWidget: Widget {
    let kind: String = RadioShared.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RadioProvider()) { entry in
            RadioWidgetView(entry: entry)
        }
        .configurationDisplayName("Saurosoft Radio")
        .description("Titolo, artista e copertina del brano in onda.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
