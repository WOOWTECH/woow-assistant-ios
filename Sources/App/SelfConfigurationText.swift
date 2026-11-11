import AssistantSkills

/// Stored presentation state can be re-rendered after a language change.
/// The model's question/request/reference remain separate verbatim data.
enum SelfConfigurationMessage: Equatable {
    case idle, running, clarification, unchanged, stopped, notStarted, cancelled
    case changed(SelfConfigurationAppearance)

    func text(using localizer: AppLocalizer) -> String {
        switch self {
        case .idle: return localizer.text(.configurationIdle)
        case .running: return localizer.text(.configurationRunning)
        case .clarification: return localizer.text(.configurationClarification)
        case .unchanged: return localizer.text(.configurationUnchanged)
        case .stopped: return localizer.text(.configurationStopped)
        case .notStarted: return localizer.text(.configurationNotStarted)
        case .cancelled: return localizer.text(.configurationCancelled)
        case .changed(let appearance):
            return localizer.text(.configurationChanged(appearance: localizer.appearanceName(appearance)))
        }
    }
}

extension AppLocalizer {
    func appearanceName(_ appearance: SelfConfigurationAppearance) -> String {
        switch appearance {
        case .system: return text(.appearanceSystem)
        case .light: return text(.appearanceLight)
        case .dark: return text(.appearanceDark)
        }
    }

    func configurationError(_ error: SelfConfigurationError) -> AppText {
        switch error {
        case .permissionRequired: return .configurationErrorPermission
        case .authorizationChanged: return .configurationErrorAuthorization
        case .cancelled: return .configurationErrorCancelled
        case .invalidRequest: return .configurationErrorRequest
        case .invalidCommand: return .configurationErrorCommand
        case .listRequired: return .configurationErrorList
        case .unavailableSetting: return .configurationErrorSetting
        case .invalidValue: return .configurationErrorValue
        case .alreadyUsed: return .configurationErrorUsed
        case .timedOut: return .configurationErrorTimeout
        case .modelFailed: return .configurationErrorModel
        case .persistenceFailed: return .configurationErrorPersistence
        }
    }

    func configurationStep(_ event: SelfConfigurationEvent) -> String {
        switch event {
        case .listedOptions: return text(.configurationStepList)
        case .appliedAppearance(let appearance):
            return text(.configurationStepSet(appearance: appearanceName(appearance)))
        }
    }
}
