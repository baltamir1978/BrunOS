import UIKit

// Sacado de `DesktopViewController`, que pasaba de 2.600 líneas (punto 4 de la
// 0.2.0). Las propiedades con estado siguen allí: una extensión no puede
// guardarlas.

// MARK: - Barra superior: Tailscale, el tiempo, el calendario y los avisos del iPhone

extension DesktopViewController {

    /// El menú de Tailscale: el estado, conectar o desconectar por Atajos y
    /// cómo preparar el atajo la primera vez.
    func tailscaleMenu() -> [ContextMenu.Entry] {
        let tailscale = services.tailscale
        tailscale.refresh()
        let up = tailscale.isLikelyUp
        var entries = [
            ContextMenu.Entry(
                title: up ? "Tailscale conectado" : "Tailscale desconectado",
                symbol: up ? "checkmark.circle.fill" : "xmark.circle",
                isEnabled: false
            ) {},
            ContextMenu.Entry(title: up ? "Desconectar" : "Conectar", symbol: "power") {
                tailscale.toggle(on: !up)
            },
        ]
        if tailscale.lastToggle == .missingShortcut {
            entries.append(ContextMenu.Entry(
                title: "Falta el atajo «\(TailscaleMonitor.shortcutName)»",
                symbol: "exclamationmark.triangle",
                isEnabled: false
            ) {})
        }
        entries.append(ContextMenu.Entry(title: "Cómo crear el atajo…", symbol: "questionmark.circle") {
            [weak self] in self?.explainTailscaleShortcut()
        })
        return entries
    }

    /// La explicación está con la de AssistiveTouch, en Ajustes › Atajos.
    func explainTailscaleShortcut() {
        presentSettings(.global, page: SettingsPages.shortcutsPageIndex)
    }


    /// El calendario del mes, colgando de la hora.
    func presentCalendar(anchor: CGPoint) {
        dismissCalendar()
        let popover = CalendarPopover(anchor: anchor, in: CGRect(origin: .zero, size: logicalSize))
        popover.onDismiss = { [weak self] in self?.dismissCalendar() }
        canvas.addSubview(popover)
        applyContentsScale(to: popover)
        calendarPopover = popover
        applyContentsScale(to: popover)
    }

    func dismissCalendar() {
        calendarPopover?.removeFromSuperview()
        calendarPopover = nil
    }

    func presentWeather(anchor: CGPoint) {
        dismissWeather()
        let popover = WeatherPopover(anchor: anchor, in: CGRect(origin: .zero, size: logicalSize))
        popover.onDismiss = { [weak self] in self?.dismissWeather() }
        popover.onAddPlace = { [weak self] in
            self?.dismissWeather()
            self?.askWeatherPlace(anchor: anchor)
        }
        canvas.addSubview(popover)
        weatherPopover = popover
        applyContentsScale(to: popover)
        services.weather.refresh()
    }

    // MARK: - Mira el iPhone


    /// Avisa en el monitor de que hay que mirar la pantalla del iPhone. Ver
    /// `PhoneNotice`.
    func showPhoneNotice(_ text: String) {
        let notice = phoneNotice ?? PhoneNotice()
        notice.text = text
        let size = notice.fittingSize(maxWidth: min(560, logicalSize.width - 40))
        let top = services.desktop.isFullScreen ? 12 : Tokens.Metric.topBarHeight + 12
        notice.frame = pixelAligned(CGRect(
            x: (logicalSize.width - size.width) / 2, y: top, width: size.width, height: size.height
        ))
        if phoneNotice == nil {
            notice.alpha = 0
            canvas.addSubview(notice)
            applyContentsScale(to: notice)
            phoneNotice = notice
            UIView.animate(withDuration: 0.2) { notice.alpha = 1 }
        }
        canvas.bringSubviewToFront(notice)

        phoneNoticeTask?.cancel()
        phoneNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, let self, let notice = self.phoneNotice else { return }
            self.phoneNotice = nil
            UIView.animate(withDuration: 0.3, animations: { notice.alpha = 0 }) { _ in
                notice.removeFromSuperview()
            }
        }
    }

    @objc func folderPickerRequested() {
        showPhoneNotice("Elige la carpeta en la pantalla del iPhone")
    }

    @objc func bookmarksPickerRequested() {
        showPhoneNotice("Elige el fichero de favoritos en la pantalla del iPhone")
    }

    func dismissWeather() {
        weatherPopover?.removeFromSuperview()
        weatherPopover = nil
    }

    /// Las ciudades del tiempo, con la que se ve marcada, y añadir otra.
    func weatherMenu(anchor: CGPoint) -> [ContextMenu.Entry] {
        let weather = services.weather
        var entries = weather.places.enumerated().map { (index, place) -> ContextMenu.Entry in
            let degrees = weather.forecast(for: place).map { " · \(WeatherService.degrees($0.temperature))" } ?? ""
            return ContextMenu.Entry(
                title: place.name + degrees,
                symbol: index == weather.selectedIndex ? "checkmark" : "mappin.and.ellipse"
            ) { weather.select(index) }
        }
        entries.append(ContextMenu.Entry(
            title: weather.places.isEmpty ? "Elegir ciudad…" : "Añadir ciudad…",
            symbol: "plus",
            isEnabled: weather.places.count < WeatherService.maxPlaces
        ) { [weak self] in self?.askWeatherPlace(anchor: anchor) })
        return entries
    }

    /// Una ciudad por golpe de rueda: sin la pausa, un solo giro se saltaba
    /// varias.
    func cycleWeatherPlace(delta: CGVector) {
        guard abs(delta.dy) > 20, Date().timeIntervalSince(lastWeatherCycle) > 0.35 else { return }
        lastWeatherCycle = Date()
        services.weather.cycle(by: delta.dy > 0 ? -1 : 1)
    }

    /// Pide una ciudad por nombre y, si hay varias con ese nombre, deja elegir.
    /// Se añade a las que hubiera.
    func askWeatherPlace(anchor: CGPoint) {
        presentPrompt(title: "Añadir una ciudad al tiempo", value: "") { [weak self] name in
            guard self != nil, let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            Task { [weak self] in
                let places = (try? await WeatherService.search(name)) ?? []
                guard let self else { return }
                switch places.count {
                case 0:
                    self.presentConfirm(
                        title: "No encuentro «\(name)»",
                        message: "Prueba con otro nombre, o con el de la ciudad más cercana.",
                        destructive: "Vale",
                        isDestructive: false
                    ) { _ in }
                case 1:
                    self.services.weather.add(places[0])
                    self.presentWeather(anchor: anchor)
                default:
                    let entries = places.map { place in
                        ContextMenu.Entry(
                            title: place.detail.isEmpty ? place.name : "\(place.name) · \(place.detail)",
                            symbol: "mappin.and.ellipse"
                        ) { [weak self] in
                            self?.services.weather.add(place)
                            self?.presentWeather(anchor: anchor)
                        }
                    }
                    self.presentContextMenu(entries, at: CGPoint(x: anchor.x - 100, y: anchor.y))
                }
            }
        }
    }
}
