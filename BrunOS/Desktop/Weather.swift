import Foundation
import UIKit

/// El tiempo de la barra superior, de Open-Meteo.
///
/// **Por qué no WeatherKit**: pide activar su servicio en el App ID desde el
/// portal de desarrolladores y un permiso más en la firma. Open-Meteo es
/// gratis, sin clave ni cuenta, y sólo recibe las coordenadas de la ciudad
/// elegida (redondeadas a dos decimales, un par de kilómetros).
///
/// **Por qué ciudades y no la ubicación**: pedir la ubicación saca el aviso
/// de permiso en la pantalla del iPhone, que con monitor está en negro. Las
/// ciudades se eligen por nombre y se guardan; se alterna entre ellas desde la
/// barra (botón derecho o rueda sobre el icono) y desde las pestañas del
/// desplegable.
@MainActor
final class WeatherService {

    static let didChange = Notification.Name("BrunOSWeatherDidChange")

    struct Place: Codable, Equatable {
        var name: String
        var detail: String
        var latitude: Double
        var longitude: Double

        /// Dos resultados con las mismas coordenadas son la misma ciudad.
        var id: String { "\(latitude),\(longitude)" }
    }

    struct Hour: Equatable {
        var label: String
        var code: Int
        var temperature: Double
    }

    struct Day: Equatable {
        var label: String
        var code: Int
        var low: Double
        var high: Double
        var rainChance: Int?
    }

    struct Forecast: Equatable {
        var temperature: Double
        var feelsLike: Double
        var humidity: Int
        var wind: Double
        var code: Int
        var isDay: Bool
        var hours: [Hour]
        var days: [Day]
        var fetched: Date
    }

    enum State: Equatable {
        case noPlace
        case loading
        case ready(Forecast)
        case failed(String)
    }

    // MARK: - Ciudades

    /// Las ciudades, en el orden en que se añadieron (Bruno, 30-sep-2026: el
    /// tiempo de varios sitios, alternando desde la barra).
    private(set) var places: [Place] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(places) {
                UserDefaults.standard.set(data, forKey: Self.placesKey)
            }
        }
    }

    /// La que se ve en la barra y en el desplegable.
    private(set) var selectedIndex = 0 {
        didSet { UserDefaults.standard.set(selectedIndex, forKey: Self.selectedKey) }
    }

    /// Más no caben como pestañas en el desplegable.
    static let maxPlaces = 6

    var place: Place? {
        places.indices.contains(selectedIndex) ? places[selectedIndex] : nil
    }

    /// El pronóstico de la ciudad elegida, aunque sea de la vez anterior:
    /// mejor eso que quedarse en blanco mientras se actualiza.
    var forecast: Forecast? {
        place.flatMap { forecasts[$0.id] }
    }

    func forecast(for place: Place) -> Forecast? {
        forecasts[place.id]
    }

    var state: State {
        guard let place else { return .noPlace }
        if let forecast = forecasts[place.id] { return .ready(forecast) }
        if failed.contains(place.id) { return .failed("No se pudo consultar el tiempo") }
        return .loading
    }

    private var forecasts: [String: Forecast] = [:]
    private var failed: Set<String> = []

    /// Antes había una sola ciudad, en `weather.place`: se recoge al arrancar.
    private static let legacyPlaceKey = "weather.place"
    private static let placesKey = "weather.places"
    private static let selectedKey = "weather.selected"
    /// Cada cuánto se vuelve a pedir: el tiempo no cambia a cada minuto.
    private static let refreshInterval: TimeInterval = 20 * 60
    private var refreshTimer: Timer?
    private var task: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.placesKey),
           let saved = try? JSONDecoder().decode([Place].self, from: data) {
            places = saved
        } else if let data = defaults.data(forKey: Self.legacyPlaceKey),
                  let saved = try? JSONDecoder().decode(Place.self, from: data) {
            places = [saved]
            // En el `init` no salta el `didSet`: sin guardarlo aquí, la
            // ciudad de antes se perdía en el segundo arranque.
            if let data = try? JSONEncoder().encode(places) {
                defaults.set(data, forKey: Self.placesKey)
            }
            defaults.removeObject(forKey: Self.legacyPlaceKey)
        }
        selectedIndex = min(max(0, defaults.integer(forKey: Self.selectedKey)), max(0, places.count - 1))
    }

    /// Arranca las actualizaciones. Lo llama el escritorio al aparecer.
    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { AppServices.shared.weather.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Añade una ciudad y la deja elegida. Si ya estaba, sólo la elige.
    func add(_ place: Place) {
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            select(index)
            return
        }
        guard places.count < Self.maxPlaces else { return }
        places.append(place)
        selectedIndex = places.count - 1
        refresh()
    }

    func remove(at index: Int) {
        guard places.indices.contains(index) else { return }
        let removed = places.remove(at: index)
        forecasts[removed.id] = nil
        failed.remove(removed.id)
        if selectedIndex >= index, selectedIndex > 0 { selectedIndex -= 1 }
        notify()
    }

    func select(_ index: Int) {
        guard places.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        notify()
    }

    /// La siguiente o la anterior, dando la vuelta.
    func cycle(by delta: Int) {
        guard places.count > 1 else { return }
        select((selectedIndex + delta + places.count) % places.count)
    }

    /// Pide el tiempo de todas las ciudades, la elegida la primera.
    func refresh() {
        guard let place else {
            notify()
            return
        }
        task?.cancel()
        let order = [place] + places.filter { $0.id != place.id }
        notify()
        task = Task { [weak self] in
            for place in order {
                do {
                    let forecast = try await Self.fetch(place)
                    guard !Task.isCancelled else { return }
                    self?.forecasts[place.id] = forecast
                    self?.failed.remove(place.id)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.failed.insert(place.id)
                }
                self?.notify()
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - Open-Meteo

    /// Busca ciudades por nombre, para elegir una.
    static func search(_ name: String) async throws -> [Place] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: "es"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        struct Response: Decodable {
            struct Result: Decodable {
                var name: String
                var latitude: Double
                var longitude: Double
                var country: String?
                var admin1: String?
            }
            var results: [Result]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.results ?? []).map { result in
            let detail = [result.admin1, result.country].compactMap { $0 }.joined(separator: ", ")
            return Place(
                name: result.name,
                detail: detail,
                latitude: (result.latitude * 100).rounded() / 100,
                longitude: (result.longitude * 100).rounded() / 100
            )
        }
    }

    private static func fetch(_ place: Place) async throws -> Forecast {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "6"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct Response: Decodable {
            struct Current: Decodable {
                var time: String
                var temperature_2m: Double
                var apparent_temperature: Double
                var relative_humidity_2m: Double
                var weather_code: Int
                var wind_speed_10m: Double
                var is_day: Int
            }
            struct Hourly: Decodable {
                var time: [String]
                var temperature_2m: [Double?]
                var weather_code: [Int?]
            }
            struct Daily: Decodable {
                var time: [String]
                var weather_code: [Int?]
                var temperature_2m_max: [Double?]
                var temperature_2m_min: [Double?]
                var precipitation_probability_max: [Double?]?
            }
            var current: Current
            var hourly: Hourly
            var daily: Daily
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        // Las horas llegan en la hora local de la ciudad (`timezone=auto`) y
        // con el mismo formato que la actual: se comparan como texto.
        let hourly = decoded.hourly
        let start = hourly.time.firstIndex { $0 >= String(decoded.current.time.prefix(13)) } ?? 0
        var hours: [Hour] = []
        for index in start..<min(start + 8, hourly.time.count) {
            guard let temperature = hourly.temperature_2m[index], let code = hourly.weather_code[index] else { continue }
            let label = index == start ? "Ahora" : String(hourly.time[index].dropFirst(11).prefix(2)) + " h"
            hours.append(Hour(label: label, code: code, temperature: temperature))
        }

        let daily = decoded.daily
        let dayParser = DateFormatter()
        dayParser.dateFormat = "yyyy-MM-dd"
        dayParser.timeZone = TimeZone(identifier: "UTC")
        let dayName = DateFormatter()
        dayName.locale = Locale(identifier: "es_ES")
        dayName.dateFormat = "EEE"
        dayName.timeZone = TimeZone(identifier: "UTC")
        var days: [Day] = []
        for index in daily.time.indices {
            guard let code = daily.weather_code[index],
                  let low = daily.temperature_2m_min[index],
                  let high = daily.temperature_2m_max[index]
            else { continue }
            let label = index == 0
                ? "Hoy"
                : dayParser.date(from: daily.time[index]).map { dayName.string(from: $0).capitalized } ?? daily.time[index]
            let rain = daily.precipitation_probability_max?[index].map { Int($0.rounded()) }
            days.append(Day(label: label, code: code, low: low, high: high, rainChance: rain))
        }

        let current = decoded.current
        return Forecast(
            temperature: current.temperature_2m,
            feelsLike: current.apparent_temperature,
            humidity: Int(current.relative_humidity_2m.rounded()),
            wind: current.wind_speed_10m,
            code: current.weather_code,
            isDay: current.is_day == 1,
            hours: hours,
            days: days,
            fetched: Date()
        )
    }

    // MARK: - Códigos WMO

    /// El símbolo del sistema para un código del tiempo de la OMM, que es lo
    /// que da Open-Meteo.
    static func symbol(for code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func description(for code: Int) -> String {
        switch code {
        case 0: "Despejado"
        case 1: "Casi despejado"
        case 2: "Parcialmente nuboso"
        case 3: "Nublado"
        case 45, 48: "Niebla"
        case 51, 53, 55: "Llovizna"
        case 56, 57: "Llovizna helada"
        case 61, 80: "Lluvia débil"
        case 63, 81: "Lluvia"
        case 65, 82: "Lluvia fuerte"
        case 66, 67: "Lluvia helada"
        case 71, 85: "Nieve débil"
        case 73: "Nieve"
        case 75, 86: "Nieve fuerte"
        case 77: "Granizo fino"
        case 95: "Tormenta"
        case 96, 99: "Tormenta con granizo"
        default: "—"
        }
    }

    static func degrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }
}

/// El desplegable del tiempo, al estilo del widget de macOS: ahora, las
/// próximas horas y los próximos días. Cuelga de su icono de la barra.
///
/// **Con los colores de la interfaz**, como cualquier otra ventana, y
/// siguiendo el modo claro u oscuro. La primera versión llevaba un cielo fijo
/// con los colores del fondo Golden Gate, y a Bruno no le cuadraba con el
/// resto (24-sep-2026).
@MainActor
final class WeatherPopover: UIView {

    var onDismiss: (() -> Void)?
    /// Pulsaron «Añadir ciudad».
    var onAddPlace: (() -> Void)?

    private let card = CardView()
    private var addFrame: CGRect = .zero
    private var removeFrame: CGRect = .zero
    private var refreshFrame: CGRect = .zero
    /// Una pestaña por ciudad, si hay más de una.
    private var tabFrames: [CGRect] = []

    static let width: CGFloat = 330

    init(anchor: CGPoint, in bounds: CGRect) {
        super.init(frame: bounds)
        backgroundColor = .clear

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 18
        card.layer.borderWidth = 1
        card.setThemedBorder(Tokens.Color.border)
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.4
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        card.drawContent = { [weak self] context in
            guard let self else { return }
            // `CardView` entrega el contexto en coordenadas de la ventana, y
            // aquí todo se cuenta desde la esquina de la tarjeta. Sin esto se
            // dibujaba desplazado, fuera del recorte: Bruno veía sólo el color
            // de fondo y ningún enlace que pulsar (24-sep-2026).
            context.translateBy(x: self.card.frame.minX, y: self.card.frame.minY)
            self.drawCard(in: context)
        }
        addSubview(card)

        let height = contentHeight
        let x = min(max(8, anchor.x - Self.width / 2), bounds.maxX - Self.width - 8)
        card.frame = CGRect(x: x, y: anchor.y + 6, width: Self.width, height: height)

        NotificationCenter.default.addObserver(
            self, selector: #selector(weatherChanged), name: WeatherService.didChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    private var weather: WeatherService { AppServices.shared.weather }

    private static let primary = Tokens.Color.text
    private static let dimmed = Tokens.Color.textSecondary
    /// El ámbar de la marca, para los enlaces y la barra de temperaturas.
    private static let amber = Tokens.Color.accent

    private var contentHeight: CGFloat {
        (weather.forecast == nil ? 150 : 430) + tabsShift
    }

    /// Lo que bajan el resto de cosas cuando hay pestañas.
    private var tabsShift: CGFloat {
        weather.places.count > 1 ? 32 : 0
    }

    @objc private func weatherChanged() {
        card.frame.size.height = contentHeight
        card.setNeedsDisplay()
    }

    // MARK: - Dibujo

    private func text(_ string: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular,
                      color: UIColor = WeatherPopover.primary, width: CGFloat? = nil, align: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let height = size * 1.4
        (string as NSString).draw(
            in: CGRect(x: point.x, y: point.y, width: width ?? (Self.width - point.x - 16), height: height),
            withAttributes: attributes
        )
    }

    private func symbol(_ name: String, in frame: CGRect, size: CGFloat) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(UIImage.SymbolConfiguration.preferringMulticolor())
        guard let image = UIImage.crispSymbol(name, configuration: configuration, scale: card.layer.contentsScale)
        else { return }
        image.draw(at: CGPoint(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2))
    }

    private func drawCard(in context: CGContext) {
        let place = weather.place
        text(place?.name ?? "El tiempo", at: CGPoint(x: 16, y: 14), size: 15, weight: .semibold, width: 190)
        if let detail = place?.detail, !detail.isEmpty {
            text(detail, at: CGPoint(x: 16, y: 35), size: 11, color: Self.dimmed, width: 190)
        }

        // Enlaces arriba a la derecha: añadir otra ciudad y quitar ésta.
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(11.5, weight: .semibold), .foregroundColor: Self.amber,
        ]
        var right = Self.width - 16
        if place != nil {
            let remove = "Quitar"
            let size = (remove as NSString).size(withAttributes: linkAttributes)
            removeFrame = CGRect(x: right - size.width, y: 16, width: size.width, height: size.height)
            (remove as NSString).draw(at: removeFrame.origin, withAttributes: linkAttributes)
            right = removeFrame.minX - 14
        } else {
            removeFrame = .zero
        }
        if weather.places.count < WeatherService.maxPlaces {
            let add = place == nil ? "Elegir ciudad" : "Añadir"
            let size = (add as NSString).size(withAttributes: linkAttributes)
            addFrame = CGRect(x: right - size.width, y: 16, width: size.width, height: size.height)
            (add as NSString).draw(at: addFrame.origin, withAttributes: linkAttributes)
        } else {
            addFrame = .zero
        }

        drawTabs(in: context)

        // Lo de debajo, igual que con una sola ciudad, más abajo si hay
        // pestañas. Las zonas pulsables se apuntan sumando lo mismo.
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: tabsShift)

        guard let forecast = weather.forecast else {
            refreshFrame = .zero
            let message = switch weather.state {
            case .noPlace: "Elige tu ciudad para ver el tiempo."
            case .loading: "Consultando el tiempo…"
            case .failed(let reason): reason + ". Se vuelve a probar en un rato."
            case .ready: ""
            }
            text(message, at: CGPoint(x: 16, y: 70), size: 13, color: Self.dimmed)
            return
        }

        // Ahora.
        symbol(WeatherService.symbol(for: forecast.code, isDay: forecast.isDay),
               in: CGRect(x: 16, y: 62, width: 56, height: 56), size: 38)
        text(WeatherService.degrees(forecast.temperature), at: CGPoint(x: 80, y: 58), size: 40, weight: .light, width: 120)
        text(WeatherService.description(for: forecast.code), at: CGPoint(x: 190, y: 66), size: 13, weight: .medium, width: 124)
        if let today = forecast.days.first {
            text("Máx \(WeatherService.degrees(today.high))  Mín \(WeatherService.degrees(today.low))",
                 at: CGPoint(x: 190, y: 87), size: 12, color: Self.dimmed, width: 124)
        }
        text("Sensación \(WeatherService.degrees(forecast.feelsLike)) · Humedad \(forecast.humidity) % · Viento \(Int(forecast.wind.rounded())) km/h",
             at: CGPoint(x: 16, y: 126), size: 11.5, color: Self.dimmed)

        separator(at: 150, in: context)

        // Las próximas horas.
        let columns = max(1, forecast.hours.count)
        let columnWidth = (Self.width - 24) / CGFloat(columns)
        for (index, hour) in forecast.hours.enumerated() {
            let x = 12 + CGFloat(index) * columnWidth
            text(hour.label, at: CGPoint(x: x, y: 160), size: 10.5, color: Self.dimmed,
                 width: columnWidth, align: .center)
            symbol(WeatherService.symbol(for: hour.code), in: CGRect(x: x, y: 176, width: columnWidth, height: 24), size: 15)
            text(WeatherService.degrees(hour.temperature), at: CGPoint(x: x, y: 203), size: 12, weight: .medium,
                 width: columnWidth, align: .center)
        }

        separator(at: 228, in: context)

        // Los próximos días, con la barra de mínima a máxima de la semana.
        let days = Array(forecast.days.prefix(6))
        let weekLow = days.map(\.low).min() ?? 0
        let weekHigh = days.map(\.high).max() ?? 1
        let span = max(1, weekHigh - weekLow)
        for (index, day) in days.enumerated() {
            let y = 236 + CGFloat(index) * 28
            text(day.label, at: CGPoint(x: 16, y: y + 5), size: 12.5, weight: .medium, width: 50)
            symbol(WeatherService.symbol(for: day.code), in: CGRect(x: 66, y: y + 2, width: 28, height: 24), size: 14)
            if let rain = day.rainChance, rain >= 20 {
                text("\(rain) %", at: CGPoint(x: 96, y: y + 7), size: 10, color: Tokens.Color.accentAlt, width: 40)
            }
            text(WeatherService.degrees(day.low), at: CGPoint(x: 140, y: y + 5), size: 12,
                 color: Self.dimmed, width: 34, align: .right)
            let track = CGRect(x: 182, y: y + 13, width: 94, height: 4)
            context.setFillColor(Tokens.Color.text.withAlphaComponent(0.14).desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: track, cornerRadius: 2).cgPath)
            context.fillPath()
            let start = track.minX + track.width * CGFloat((day.low - weekLow) / span)
            let end = track.minX + track.width * CGFloat((day.high - weekLow) / span)
            context.setFillColor(Self.amber.desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(x: start, y: track.minY, width: max(4, end - start), height: 4),
                                         cornerRadius: 2).cgPath)
            context.fillPath()
            text(WeatherService.degrees(day.high), at: CGPoint(x: 284, y: y + 5), size: 12, weight: .medium, width: 34)
        }

        // Pie: de dónde salen los datos y cuándo.
        let footerY = contentHeight - tabsShift - 26
        text("Open-Meteo · \(forecast.fetched.formatted(date: .omitted, time: .shortened))",
             at: CGPoint(x: 16, y: footerY), size: 10.5, color: Self.dimmed, width: 200)
        let refresh = "Actualizar"
        let refreshSize = (refresh as NSString).size(withAttributes: linkAttributes)
        refreshFrame = CGRect(x: Self.width - 16 - refreshSize.width, y: footerY, width: refreshSize.width, height: refreshSize.height)
        (refresh as NSString).draw(at: refreshFrame.origin, withAttributes: linkAttributes)
        // Se dibuja desplazado, pero se pulsa en coordenadas de la tarjeta.
        refreshFrame.origin.y += tabsShift
    }

    /// Las pestañas de las ciudades, bajo el nombre. Cada una con su
    /// temperatura si ya se sabe, para comparar de un vistazo.
    private func drawTabs(in context: CGContext) {
        let places = weather.places
        guard places.count > 1 else {
            tabFrames = []
            return
        }
        let font = Tokens.sans(11.5, weight: .medium)
        let titles = places.map { place in
            weather.forecast(for: place).map { "\(place.name) \(WeatherService.degrees($0.temperature))" } ?? place.name
        }
        let spacing: CGFloat = 6
        let available = Self.width - 32
        let natural = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 18 }
        let fits = natural.reduce(0, +) + spacing * CGFloat(places.count - 1) <= available
        let even = (available - spacing * CGFloat(places.count - 1)) / CGFloat(places.count)

        var x: CGFloat = 16
        tabFrames = []
        for (index, title) in titles.enumerated() {
            let frame = CGRect(x: x, y: 56, width: fits ? natural[index] : even, height: 22)
            tabFrames.append(frame)
            x = frame.maxX + spacing
            let selected = index == weather.selectedIndex
            context.setFillColor((selected ? Self.amber.withAlphaComponent(0.22) : Tokens.Color.text.withAlphaComponent(0.07)).desktopCGColor)
            context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 11).cgPath)
            context.fillPath()
            text(title, at: CGPoint(x: frame.minX + 9, y: frame.minY + 3), size: 11.5,
                 weight: selected ? .semibold : .medium, color: selected ? Self.primary : Self.dimmed,
                 width: frame.width - 18, align: .center)
        }
    }

    private func separator(at y: CGFloat, in context: CGContext) {
        context.setFillColor(Tokens.Color.border.desktopCGColor)
        context.fill(CGRect(x: 16, y: y, width: Self.width - 32, height: 1))
    }

    // MARK: - Entrada

    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        if case .scroll(let delta) = kind {
            // La rueda pasa de ciudad, como la del calendario pasa de mes.
            if abs(delta.dy) > 20 { weather.cycle(by: delta.dy > 0 ? -1 : 1) }
            return true
        }
        guard case .down = kind else { return true }
        guard card.frame.contains(point) else {
            onDismiss?()
            return true
        }
        let local = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)
        if let tab = tabFrames.firstIndex(where: { $0.insetBy(dx: -2, dy: -4).contains(local) }) {
            weather.select(tab)
        } else if addFrame.insetBy(dx: -6, dy: -6).contains(local) {
            onAddPlace?()
        } else if removeFrame.insetBy(dx: -6, dy: -6).contains(local) {
            weather.remove(at: weather.selectedIndex)
        } else if refreshFrame.insetBy(dx: -6, dy: -6).contains(local) {
            weather.refresh()
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }
        switch event.key.keyCode {
        case .keyboardEscape: onDismiss?()
        case .keyboardLeftArrow: weather.cycle(by: -1)
        case .keyboardRightArrow: weather.cycle(by: 1)
        default: break
        }
        return true
    }
}
