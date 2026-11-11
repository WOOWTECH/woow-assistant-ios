import AssistantSkills

extension AppLocalizer {
    static func skillCatalogError(_ error: SkillCatalogError) -> AppText {
        switch error {
        case .unavailable: return .catalogUnavailable
        case .invalidCatalog: return .catalogInvalid
        case .notFound: return .catalogNotFound
        case .alreadyAdded: return .catalogAlreadyAdded
        }
    }
    static func skillReadiness(id: String) -> AppText {
        switch id {
        case "configure-mika": return .catalogReadyAppearance
        case "skill-authoring": return .catalogReadyAuthor
        case "documents": return .catalogReadyDocuments
        case "content-transcribe": return .catalogReadyTranscript
        default: return .catalogReadyOther
        }
    }
    static func skillRequirement(_ requirement: SkillCatalogRequirement) -> AppText {
        switch requirement {
        case .settingsAutomation: return .catalogReqSettings
        case .androidControl: return .catalogReqAndroid
        case .legacyWebTools: return .catalogReqWeb
        case .workspaceFiles: return .catalogReqFiles
        case .python: return .catalogReqPython
        case .shell: return .catalogReqShell
        case .fileExport: return .catalogReqExport
        case .crossOriginResearch: return .catalogReqResearch
        case .accountAccess: return .catalogReqAccount
        case .externalSend: return .catalogReqSend
        case .skillMutationTools: return .catalogReqMutation
        }
    }
}
