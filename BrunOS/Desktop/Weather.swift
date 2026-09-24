import Foundation
import UIKit

/// El tiempo de la barra superior, de Open-Meteo.
///
/// **Por qué no WeatherKit**: pide activar su servicio en el App ID desde el
/// portal de desarrolladores y un permiso más en la firma. Open-Meteo es
/// gratis, sin clave ni cuenta, y sólo recibe las coordenadas de la ciudad
/// elegida (redondeadas a dos decimales, un par de kilómetros).
///
/// **Por qué una ciudad y no la ubicación**: pedir la ubicación saca el aviso
/// de permiso en la pantalla del iPhone, que con monitor está en negro. La
/// ciudad se elige una vez, por nombre, y se guarda.
@MainActor
final class WeatherService {

    static let didChange = Notification.Name("BrunOSWeatherDidChange")

    struct Place: Codable, Equatable {
        var name: String
        var detail: String
        var latitude: Double
        var longitude: Double
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

    private(set) var place: Place? {
        didSet {
            if let place, let data = try? JSONEncoder().encode(place) {
                UserDefaults.standard.set(data, forKey: Self.placeKey)
            }
        }
    }

    private(set) var state: State = .noPlace {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    /// Lo último bueno, para no quedarse en blanco mientras se actualiza.
    var forecast: Forecast? {
        if case .ready(let forecast) = state { return forecast }
        return lastForecast
    }
    private var lastForecast: Forecast?

    private static let placeKey = "weather.place"
    /// Cada cuánto se vuelve a pedir: el tiempo no cambia a cada minuto.
    private static let refreshInterval: TimeInterval = 20 * 60
    private var refreshTimer: Timer?
    private var task: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.placeKey),
           let saved = try? JSONDecoder().decode(Place.self, from: data) {
            place = saved
            state = .loading
        }
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

    func setPlace(_ place: Place) {
        self.place = place
        lastForecast = nil
        refresh()
    }

    func refresh() {
        guard let place else {
            state = .noPlace
            return
        }
        task?.cancel()
        if lastForecast == nil { state = .loading }
        task = Task { [weak self] in
            do {
                let forecast = try await Self.fetch(place)
                guard !Task.isCancelled else { return }
                self?.lastForecast = forecast
                self?.state = .ready(forecast)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed("No se pudo consultar el tiempo")
            }
        }
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
/// **Con los colores del fondo Golden Gate** (lo pidió Bruno): un degradado
/// de atardecer, del azul del crepúsculo al ámbar, con el texto en blanco,
/// como el widget del Tiempo. De noche, el mismo cielo más apagado. No
/// cambia con el modo claro u oscuro: es un cielo, no un panel.
@MainActor
final class WeatherPopover: UIView {

    var onDismiss: (() -> Void)?
    /// Pulsaron «Cambiar ciudad».
    var onChangePlace: (() -> Void)?

    private let card = CardView()
    private var changeFrame: CGRect = .zero
    private var refreshFrame: CGRect = .zero

    static let width: CGFloat = 330

    init(anchor: CGPoint, in bounds: CGRect) {
        super.init(frame: bounds)
        backgroundColor = .clear

        card.backgroundColor = Self.sky(isDay: true).last
        card.layer.cornerRadius = 18
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
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

    private static let white = UIColor.white
    private static let dimmed = UIColor.white.withAlphaComponent(0.72)
    /// El ámbar del sol bajo, para los enlaces y la barra de temperaturas.
    private static let amber = UIColor(hex: 0xFFC56E)

    /// El cielo de fondo: de arriba abajo. Colores fijos a propósito (ver
    /// arriba), así que aquí sí vale `.cgColor`.
    static func sky(isDay: Bool) -> [UIColor] {
        isDay
            ? [UIColor(hex: 0x2C4A7E), UIColor(hex: 0x8C5A78), UIColor(hex: 0xE38B55)]
            : [UIColor(hex: 0x141C33), UIColor(hex: 0x2E2B4D), UIColor(hex: 0x6B4150)]
    }

    private var contentHeight: CGFloat {
        weather.forecast == nil ? 150 : 430
    }

    @objc private func weatherChanged() {
        card.frame.size.height = contentHeight
        card.setNeedsDisplay()
    }

    // MARK: - Dibujo

    private func text(_ string: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular,
                      color: UIColor = WeatherPopover.white, width: CGFloat? = nil, align: NSTextAlignment = .left) {
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
        let colors = Self.sky(isDay: weather.forecast?.isDay ?? true)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: [0, 0.55, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: Self.width * 0.35, y: card.bounds.height),
                options: [.drawsAfterEndLocation]
            )
        }
        let place = weather.place
        text(place?.name ?? "El tiempo", at: CGPoint(x: 16, y: 14), size: 15, weight: .semibold, width: 190)
        if let detail = place?.detail, !detail.isEmpty {
            text(detail, at: CGPoint(x: 16, y: 35), size: 11, color: Self.dimmed, width: 190)
        }

        // Enlaces arriba a la derecha.
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.sans(11.5, weight: .semibold), .foregroundColor: Self.amber,
        ]
        let change = place == nil ? "Elegir ciudad" : "Cambiar ciudad"
        let changeSize = (change as NSString).size(withAttributes: linkAttributes)
        changeFrame = CGRect(x: Self.width - 16 - changeSize.width, y: 16, width: changeSize.width, height: changeSize.height)
        (change as NSString).draw(at: changeFrame.origin, withAttributes: linkAttributes)

        guard let forecast = weather.forecast else {
            refreshFrame = .zero
            let message = switch weather.state {
            case .noPlace: "Elige tu ciudad para ver el tiempo."
            case .loading: "Consultando el tiempo…"
            case .failed(let reason): reason + ". Pulsa «Cambiar ciudad» o espera un rato."
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
                text("\(rain) %", at: CGPoint(x: 96, y: y + 7), size: 10, color: UIColor(hex: 0x9FD3FF), width: 40)
            }
            text(WeatherService.degrees(day.low), at: CGPoint(x: 140, y: y + 5), size: 12,
                 color: Self.dimmed, width: 34, align: .right)
            let track = CGRect(x: 182, y: y + 13, width: 94, height: 4)
            context.setFillColor(UIColor.white.withAlphaComponent(0.22).cgColor)
            context.addPath(UIBezierPath(roundedRect: track, cornerRadius: 2).cgPath)
            context.fillPath()
            let start = track.minX + track.width * CGFloat((day.low - weekLow) / span)
            let end = track.minX + track.width * CGFloat((day.high - weekLow) / span)
            context.setFillColor(Self.amber.cgColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(x: start, y: track.minY, width: max(4, end - start), height: 4),
                                         cornerRadius: 2).cgPath)
            context.fillPath()
            text(WeatherService.degrees(day.high), at: CGPoint(x: 284, y: y + 5), size: 12, weight: .medium, width: 34)
        }

        // Pie: de dónde salen los datos y cuándo.
        let footerY = contentHeight - 26
        text("Open-Meteo · \(forecast.fetched.formatted(date: .omitted, time: .shortened))",
             at: CGPoint(x: 16, y: footerY), size: 10.5, color: Self.dimmed, width: 200)
        let refresh = "Actualizar"
        let refreshSize = (refresh as NSString).size(withAttributes: linkAttributes)
        refreshFrame = CGRect(x: Self.width - 16 - refreshSize.width, y: footerY, width: refreshSize.width, height: refreshSize.height)
        (refresh as NSString).draw(at: refreshFrame.origin, withAttributes: linkAttributes)
    }

    private func separator(at y: CGFloat, in context: CGContext) {
        context.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
        context.fill(CGRect(x: 16, y: y, width: Self.width - 32, height: 1))
    }

    // MARK: - Entrada

    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        guard case .down = kind else { return true }
        guard card.frame.contains(point) else {
            onDismiss?()
            return true
        }
        let local = CGPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY)
        if changeFrame.insetBy(dx: -6, dy: -6).contains(local) {
            onChangePlace?()
        } else if refreshFrame.insetBy(dx: -6, dy: -6).contains(local) {
            weather.refresh()
        }
        return true
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        if event.phase == .down, event.key.keyCode == .keyboardEscape { onDismiss?() }
        return true
    }
}
