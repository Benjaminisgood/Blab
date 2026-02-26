import SwiftUI
import SwiftData
import AppKit
import UserNotifications

@main
struct BlabApp: App {
    @NSApplicationDelegateAdaptor(BlabNotificationDelegate.self) private var notificationDelegate

    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Member.self,
            MemberFollow.self,
            LabItem.self,
            LabLocation.self,
            EventParticipant.self,
            LabEvent.self,
            LabAttachment.self,
            LabLog.self,
            LabMessage.self,
            AISettings.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    init() {
        HousekeeperRuntimeService.shared.startIfNeeded(modelContainer: sharedModelContainer)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .commands {
            SidebarCommands()
        }
    }
}

extension Notification.Name {
    static let blabAlertNotificationTapped = Notification.Name("blab.alert.notification.tapped")
}

enum AlertDeepLinkEntity: String {
    case item
    case location
}

struct AlertNotificationRoute {
    static let marker = "blab_alert_route_v1"

    var memberID: UUID
    var entity: AlertDeepLinkEntity
    var targetID: UUID
    var targetName: String
    var message: String

    var userInfo: [AnyHashable: Any] {
        [
            "route_marker": Self.marker,
            "member_id": memberID.uuidString,
            "entity": entity.rawValue,
            "target_id": targetID.uuidString,
            "target_name": targetName,
            "message": message
        ]
    }

    init?(
        memberID: UUID,
        entity: AlertDeepLinkEntity,
        targetID: UUID,
        targetName: String,
        message: String
    ) {
        guard !targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.memberID = memberID
        self.entity = entity
        self.targetID = targetID
        self.targetName = targetName
        self.message = message
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let marker = userInfo["route_marker"] as? String,
              marker == Self.marker,
              let memberToken = userInfo["member_id"] as? String,
              let memberID = UUID(uuidString: memberToken),
              let entityToken = userInfo["entity"] as? String,
              let entity = AlertDeepLinkEntity(rawValue: entityToken),
              let targetToken = userInfo["target_id"] as? String,
              let targetID = UUID(uuidString: targetToken),
              let targetName = userInfo["target_name"] as? String,
              let message = userInfo["message"] as? String else {
            return nil
        }

        self.memberID = memberID
        self.entity = entity
        self.targetID = targetID
        self.targetName = targetName
        self.message = message
    }
}

final class BlabNotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = AlertNotificationRoute(userInfo: response.notification.request.content.userInfo) else {
            return
        }

        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .blabAlertNotificationTapped,
                object: nil,
                userInfo: route.userInfo
            )
        }
    }
}

@MainActor
final class AlertNotificationService {
    static let shared = AlertNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    private let authRequestedKey = "blab.notifications.auth.requested.v1"
    private let routeStateKey = "blab.notifications.route.state.v1"

    private var didLoadState = false
    private var lastStatusByRouteKey: [String: String] = [:]

    private init() {}

    func refresh(items: [LabItem], locations: [LabLocation]) {
        loadRouteStateIfNeeded()
        requestAuthorizationIfNeeded()

        var activeRouteKeys = Set<String>()

        for item in items {
            guard let status = item.status, status.isAlert else { continue }
            for member in item.responsibleMembers {
                let routeKey = "item|\(item.id.uuidString)|\(member.id.uuidString)"
                activeRouteKeys.insert(routeKey)

                let statusToken = status.rawValue
                if lastStatusByRouteKey[routeKey] == statusToken {
                    continue
                }

                lastStatusByRouteKey[routeKey] = statusToken
                let message = "物品「\(item.name)」状态「\(status.rawValue)」，建议\(status.alertActionLabel)。"
                postNotification(
                    for: member,
                    route: AlertNotificationRoute(
                        memberID: member.id,
                        entity: .item,
                        targetID: item.id,
                        targetName: item.name,
                        message: message
                    ),
                    statusToken: statusToken
                )
            }
        }

        for location in locations {
            guard let status = location.status, status.isAlert else { continue }
            for member in location.responsibleMembers {
                let routeKey = "location|\(location.id.uuidString)|\(member.id.uuidString)"
                activeRouteKeys.insert(routeKey)

                let statusToken = status.rawValue
                if lastStatusByRouteKey[routeKey] == statusToken {
                    continue
                }

                lastStatusByRouteKey[routeKey] = statusToken
                let message = "空间「\(location.name)」状态「\(status.rawValue)」，建议\(status.alertActionLabel)。"
                postNotification(
                    for: member,
                    route: AlertNotificationRoute(
                        memberID: member.id,
                        entity: .location,
                        targetID: location.id,
                        targetName: location.name,
                        message: message
                    ),
                    statusToken: statusToken
                )
            }
        }

        for key in lastStatusByRouteKey.keys where !activeRouteKeys.contains(key) {
            lastStatusByRouteKey.removeValue(forKey: key)
        }

        persistRouteState()
    }

    private func postNotification(
        for member: Member,
        route: AlertNotificationRoute?,
        statusToken: String
    ) {
        guard let route else { return }

        let content = UNMutableNotificationContent()
        content.title = "Blab 告警提醒"
        content.subtitle = "收件人：\(member.displayName)（@\(member.username)）"
        content.body = "给 \(member.displayName)：\(route.message)"
        content.sound = .default
        content.userInfo = route.userInfo

        let requestID = [
            "blab",
            "alert",
            route.entity.rawValue,
            route.targetID.uuidString,
            member.id.uuidString,
            statusToken
        ].joined(separator: ".")

        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func loadRouteStateIfNeeded() {
        guard !didLoadState else { return }
        didLoadState = true
        if let dictionary = defaults.dictionary(forKey: routeStateKey) as? [String: String] {
            lastStatusByRouteKey = dictionary
        } else {
            lastStatusByRouteKey = [:]
        }
    }

    private func persistRouteState() {
        defaults.set(lastStatusByRouteKey, forKey: routeStateKey)
    }

    private func requestAuthorizationIfNeeded() {
        guard !defaults.bool(forKey: authRequestedKey) else { return }
        defaults.set(true, forKey: authRequestedKey)

        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }
}
