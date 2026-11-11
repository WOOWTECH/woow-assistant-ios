#!/usr/bin/env python3
"""Source-bound candidate ledger, deliberately not a whole-App coverage claim.

Every candidate retains file/line/line hash; unresolved dynamic values require
semantic review. Pure source scanning cannot prove that a String is UI or data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
SKIP={'BrowserLoginFixture.swift','BrowserUploadFixture.swift','LiveModelUITestSupport.swift','SkillExecutionUITestSupport.swift','TranscriptUITestSupport.swift','UITestMCPFixture.swift','UITestModelFixture.swift'}
GENERATED={'AppText.swift'}
UI=re.compile(r'\b(Text|Button|Label|Section|Picker|Toggle|TextField|SecureField|navigationTitle|alert|confirmationDialog|accessibilityLabel|accessibilityHint|accessibilityValue)\s*\(')
CJK=re.compile('[\u3400-\u9fff]')

def inventory():
    files=[];sites=[]
    for path in sorted((ROOT/'Sources/App').glob('*.swift')):
        if path.name in SKIP|GENERATED: continue
        raw=path.read_bytes();relative=str(path.relative_to(ROOT));filehash=hashlib.sha256(raw).hexdigest()
        files.append({'file':relative,'sha256':filehash})
        for number,line in enumerate(raw.decode().splitlines(),1):
            if line.lstrip().startswith('//'):continue
            kinds=[]
            match=UI.search(line)
            if match:kinds.append('ui_expression_requires_provenance_review')
            if CJK.search(line) and '"' in line:kinds.append('chinese_literal_candidate_not_necessarily_ui')
            if '.accessibilityIdentifier(' in line:kinds.append('stable_identifier_do_not_translate')
            if re.search(r'localizer\.(text|appearanceName|languageName|configurationStep)|text\(using: localizer\)',line):kinds.append('typed_localized_render')
            if not kinds:continue
            review='pending'
            if kinds==['stable_identifier_do_not_translate']:review='excluded_machine_identifier'
            elif path.name in {'SelfConfigurationView.swift','SkillWorkerSettingsView.swift'}:
                review='migrated_settings_view' if 'typed_localized_render' in kinds else 'settings_manual_reviewed'
                if 'Text(verbatim: question)' in line:review='excluded_model_clarification_verbatim'
            elif path.name in {'MCPToolsView.swift','MCPApprovalView.swift','BrowserSearchSettingsView.swift','BrowserLibraryView.swift','SkillCatalogView.swift','TaskNotificationSettingsView.swift'}:
                review='phase2_typed_render' if 'typed_localized_render' in kinds else 'phase2_dynamic_or_data_field_review_required'
            elif path.name=='SelfConfigurationSession.swift' and 'let reference =' in line:review='excluded_model_protocol_reference'
            sites.append({'file':relative,'line':number,'line_sha256':hashlib.sha256(line.encode()).hexdigest(),'kinds':kinds,'review':review})
    errors=[]
    for path in sorted((ROOT/'Sources').rglob('*.swift')):
        raw=path.read_bytes();text=raw.decode()
        if 'errorDescription' not in text:continue
        for number,line in enumerate(text.splitlines(),1):
            if line.lstrip().startswith('//') or 'return "' not in line or not CJK.search(line):continue
            errors.append({'file':str(path.relative_to(ROOT)),'file_sha256':hashlib.sha256(raw).hexdigest(),'line':number,'line_sha256':hashlib.sha256(line.encode()).hexdigest(),'review':'settings_closed_error_adapter' if path.name=='SelfConfigurationStore.swift' else ('worker_only_model_settings_adapter' if path.name=='ModelSettings.swift' else 'pending_error_or_other_return_semantic_review')})
    return {'schema_version':1,'base_commit':'2758966f51134fd9684549d537d9e08d15cb9d3e','method':'Candidate scan including English-only UI expressions and raw dynamic Text arguments; categories overlap. Manual settings-page coverage is separate from heuristic counts. Not proof of complete UI coverage.','implemented_screen_migrations':['SelfConfigurationView: controls, help, state, error adapter, tool steps, human AX labels; model clarification remains verbatim', 'SkillWorkerSettingsView/Preferences: controls, placeholders, notices and known-error adapter', 'MCPTools/Approval/Results: fixed UI, phase/error/notice/count adapters; tool names/arguments/results verbatim', 'BrowserSearchSettings/BrowserLibrary: controls and workspace errors; saved page/search/site content verbatim', 'SkillCatalog: navigation, fixed help, closed catalog errors, requirements/readiness; original archive and remaining LearningStore errors verbatim', 'TaskNotificationSettings/CenterAdapter: human labels/notices and fixed delivery title/body; machine AX state remains raw'],'not_complete':['Root and chat including three stream-preview status messages','Browser main pages/statuses/find/dialogs/downloads; only workspace errors/site-mode notice migrated','Learning/profile/memory; catalog title/adaptation metadata and LearningStore import errors remain untranslated','Document/transcript/research/skill execution','Native notification permission/banner/delivery acceptance and human-only AX value separation remain unverified','System-owned Files/share/permission UI is outside App localization'],'files':files,'sites':sites,'error_candidates':errors,'counts':{'source_files':len(files),'candidate_sites':len(sites),'typed_render_sites':sum('typed_localized_render' in s['kinds'] for s in sites),'pending_candidate_sites':sum(s['review']=='pending' for s in sites),'error_candidates':len(errors)},'full_app_localized':False,'native_ui_verified':False,'mika_explicit_languages':10,'implemented_resource_languages':3,'mika_language_parity':False}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--write',action='store_true');a=p.parse_args()
    data=(json.dumps(inventory(),ensure_ascii=False,indent=2)+'\n').encode();path=ROOT/'Localization/Coverage.json'
    if a.write:path.write_bytes(data)
    elif not path.exists() or path.read_bytes()!=data:raise SystemExit('Localization coverage ledger is stale; review before regeneration.')
    print(json.dumps(inventory()['counts']))
