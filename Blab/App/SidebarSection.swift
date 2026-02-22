import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard
    case events
    case items
    case locations
    case members
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            return "总览"
        case .events:
            return "事项"
        case .items:
            return "物品"
        case .locations:
            return "空间"
        case .members:
            return "成员"
        case .logs:
            return "日志"
        case .settings:
            return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            return "square.grid.2x2"
        case .events:
            return "calendar"
        case .items:
            return "shippingbox"
        case .locations:
            return "map"
        case .members:
            return "person.3"
        case .logs:
            return "list.bullet.rectangle"
        case .settings:
            return "slider.horizontal.3"
        }
    }
}
