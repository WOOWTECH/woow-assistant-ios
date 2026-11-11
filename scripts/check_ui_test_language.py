#!/usr/bin/env python3
"""Reject unpinned literal UI launches; named tests retain explicit OS languages.

This checks the current direct launchArguments style, including cleanup. It does
not inject production defaults or treat native UIKit controls as App strings.
"""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def audit(root):
    rows=[]
    for path in sorted((root/'Tests/WoowAssistantUITests').glob('*.swift')):
        text=path.read_text()
        for match in re.finditer(r'\bapp\.launchArguments\s*=\s*\[',text):
            end=text.find(']',match.end());block=text[match.start():end+1]
            expected='"-AppleLanguages", "(zh-Hant)"' in block and '"-AppleLocale", "zh_TW"' in block
            exception=None
            if path.name=='BrowserWorkspaceUITests.swift':
                exception='native-find-English' if ('"-AppleLanguages", nativeFindEnglish ? "(en)" : "(zh-Hant)"' in block and '"-AppleLocale", nativeFindEnglish ? "en_US" : "zh_TW"' in block) else None
            if path.name=='AppLanguageUITests.swift':
                exception='explicit-language-acceptance' if '"-AppleLanguages", systemLanguages' in block and '"-AppleLocale", "zh_TW"' in block else None
            valid=(expected or exception is not None) and block.count('"-AppleLanguages"')==1 and block.count('"-AppleLocale"')==1
            rows.append({'file':str(path.relative_to(root)),'line':text[:match.start()].count('\n')+1,'valid':valid,'exception':exception})
        for match in re.finditer(r'\bapp\.launchArguments\s*\+=([^\n]+)',text):
            if '-AppleLanguages' in match[1] or '-AppleLocale' in match[1]:
                rows.append({'file':str(path.relative_to(root)),'line':text[:match.start()].count('\n')+1,'valid':False,'exception':'duplicate override risk'})
    return rows

if __name__=='__main__':
    rows=audit(ROOT);failed=[r for r in rows if not r['valid']]
    print(json.dumps({'assignments':len(rows),'failed':failed,'native_acceptance':False},ensure_ascii=False))
    raise SystemExit(bool(failed))
