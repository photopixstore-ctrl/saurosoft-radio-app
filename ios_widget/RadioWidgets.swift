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
}

struct RadioEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let cover: UIImage?

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

struct RadioWidgetView: View {
    let entry: RadioEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                RadioCover(image: entry.cover, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(RadioColors.accent)
                    Text("IN ONDA")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(RadioColors.dim)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(entry.title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(RadioColors.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.artist)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(RadioColors.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
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
