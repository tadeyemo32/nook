import AppKit
import CoreLocation
import EventKit

final class CalendarService {
    var onEvents: (([CalendarItem]) -> Void)?
    var onReminders: (([ReminderItem]) -> Void)?
    var onBanner: ((Banner) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var announced: Set<String> = []

    func setEnabled(_ enabled: Bool) {
        if enabled, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
            observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in self?.refresh() }
            refresh()
        } else if !enabled, let timer {
            timer.invalidate()
            self.timer = nil
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            onEvents?([])
            onReminders?([])
        }
        // Each permission is asked for only once its feature is on, even if the other one started the service.
        let done: (Bool, Error?) -> Void = { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
        if enabled, Pref.bool(.showCalendar) || Pref.bool(.calendarAlerts),
           EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            store.requestFullAccessToEvents(completion: done)
        }
        if enabled, Pref.bool(.showReminders), EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            store.requestFullAccessToReminders(completion: done)
        }
    }

    func complete(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        refresh()
    }

    private func refreshReminders(now: Date) {
        guard Pref.bool(.showReminders), EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            onReminders?([])
            return
        }
        let endOfToday = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let items = (reminders ?? []).map { reminder in
                ReminderItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder",
                             due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                             color: reminder.calendar.color ?? .systemOrange)
            }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            // Only reminders with a time alert, once, in the minute they fall due.
            let due = (reminders ?? []).filter { reminder in
                guard reminder.dueDateComponents?.hour != nil,
                      let date = reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) })
                else { return false }
                return date <= now && now.timeIntervalSince(date) < 90
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onReminders?(items)
                for reminder in due where announced.insert("reminder-" + reminder.calendarItemIdentifier).inserted {
                    onBanner?(Banner(symbol: "checklist", title: reminder.title ?? "Reminder", value: "Now",
                                     tint: reminder.calendar.color ?? .systemOrange, duration: 6, showsTitle: true))
                }
            }
        }
    }

    /// The first video-call link in an event's URL, location or notes.
    static func meetingURL(in texts: [String?]) -> URL? {
        let pattern = #"https://([\w-]+\.)*(zoom\.us/(j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join/|teams\.live\.com/meet/|webex\.com/|whereby\.com/|facetime\.apple\.com/join|app\.slack\.com/huddle/)[^\s<>"')]*"#
        for text in texts.compactMap({ $0 }) {
            if let range = text.range(of: pattern, options: .regularExpression), let url = URL(string: String(text[range])) {
                return url
            }
        }
        return nil
    }

    private func refresh() {
        let now = Date()
        refreshReminders(now: now)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            onEvents?([])
            return
        }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600),
                                                 end: now.addingTimeInterval(36 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.endDate > now && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }

        onEvents?(events.map {
            CalendarItem(id: ($0.eventIdentifier ?? UUID().uuidString) + "\($0.startDate.timeIntervalSince1970)",
                         title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                         isAllDay: $0.isAllDay, color: $0.calendar.color ?? .systemBlue,
                         meetingURL: Self.meetingURL(in: [$0.url?.absoluteString, $0.location, $0.notes]))
        })

        guard Pref.bool(.calendarAlerts) else { return }
        for event in events where !event.isAllDay {
            let minutes = event.startDate.timeIntervalSince(now) / 60
            let key = (event.eventIdentifier ?? "") + "\(event.startDate.timeIntervalSince1970)"
            guard minutes > 0, minutes <= 5, !announced.contains(key) else { continue }
            announced.insert(key)
            onBanner?(Banner(symbol: "calendar", title: event.title ?? "Event",
                             value: "\(max(1, Int(minutes.rounded()))) min",
                             tint: event.calendar.color ?? .systemRed, duration: 6, showsTitle: true))
        }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }
}

final class WeatherService: NSObject, CLLocationManagerDelegate {
    var onWeather: ((WeatherInfo?) -> Void)?

    private let location = CLLocationManager()
    private var timer: Timer?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
                self?.location.requestLocation()
            }
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
            } else {
                location.requestLocation()
            }
        } else if !enabled, timer != nil {
            timer?.invalidate()
            timer = nil
            onWeather?(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if timer != nil, manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        fetch(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func fetch(latitude: Double, longitude: Double) {
        let fahrenheit = Locale.current.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, _ in
            let info = data.flatMap { try? JSONDecoder().decode(Forecast.self, from: $0) }.map {
                WeatherInfo(temperature: $0.current.temperature_2m,
                            high: $0.daily.temperature_2m_max.first ?? $0.current.temperature_2m,
                            low: $0.daily.temperature_2m_min.first ?? $0.current.temperature_2m,
                            symbol: Self.symbol(code: $0.current.weather_code, day: $0.current.is_day == 1),
                            unit: fahrenheit ? "°F" : "°C")
            }
            DispatchQueue.main.async { if info != nil { self?.onWeather?(info) } }
        }.resume()
    }

    private struct Forecast: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
        struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
        let current: Current
        let daily: Daily
    }

    private static func symbol(code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
