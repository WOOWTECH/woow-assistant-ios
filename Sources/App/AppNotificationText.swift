import AssistantDomain

extension AppLocalizer {
    static func notificationAuthorization(_ value: TaskNotificationAuthorization) -> AppText {
        switch value {
        case .unknown: return .commonUnknown
        case .notDetermined: return .notificationNotAsked
        case .denied: return .notificationDenied
        case .authorized: return .notificationAuthorized
        case .provisional: return .notificationProvisional
        case .ephemeral: return .notificationEphemeral
        }
    }
    static func notificationSetting(_ value: TaskNotificationSetting) -> AppText {
        switch value {
        case .unknown: return .commonUnknown
        case .notSupported: return .notificationNotSupported
        case .disabled: return .notificationOff
        case .enabled: return .notificationOn
        }
    }
    static func notificationNotice(_ value: TaskNotificationNotice) -> AppText {
        switch value {
        case .authorizationUnavailable: return .notificationAuthorizationError
        case .deliveryUnavailable: return .notificationDeliveryError
        }
    }
    func notificationTitle(_ kind: TaskNotificationKind) -> String {
        switch kind {
        case .completed: return text(.notificationCompletedTitle)
        case .approval: return text(.notificationApprovalTitle)
        case .test: return text(.notificationTestTitle)
        }
    }
    func notificationBody(_ kind: TaskNotificationKind) -> String {
        switch kind {
        case .completed: return text(.notificationCompletedBody)
        case .approval: return text(.notificationApprovalBody)
        case .test: return text(.notificationTestBody)
        }
    }
}
