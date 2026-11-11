#!/usr/bin/env python3
"""Local actual Foundation/Combine/resource/HTTP checks; no live model or UI claim."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from check_profile_chat_app import APP_SOURCES, MODULES

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(tempfile.mkdtemp(prefix='woow-language-check-'))
ENV = {k:v for k,v in os.environ.items() if not k.startswith(('WOOW_', 'LITELLM_'))}
report = {'checks':[], 'source_sha256':{}, 'native_ios_ui':False, 'swiftui_typecheck':False, 'live_model_requests':0}

def run(name, args, timeout=180):
    result = subprocess.run(args, cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=timeout)
    (OUT/(name+'.log')).write_text(result.stdout+result.stderr)
    row={'name':name,'exit_code':result.returncode}
    if name.endswith('-run') and result.returncode == 0: row['result']=json.loads(result.stdout)
    report['checks'].append(row); (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(row),flush=True)
    if result.returncode: raise SystemExit('FAILED: '+str(OUT/(name+'.log')))

def capture(path):
    path=Path(path);data=path.read_bytes();relative=path.relative_to(ROOT)
    target=OUT/'source'/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    report['source_sha256'][str(relative)] = hashlib.sha256(data).hexdigest()
    return str(target)

print('Local evidence: '+str(OUT),flush=True)
run('resource-parity',['python3','scripts/generate_app_text.py'])
run('resource-negative-tests',['python3','-m','unittest','discover','-s','scripts','-p','test_app_text_resources.py'])
for path in (ROOT/'Sources/App/Resources').rglob('*'):
    if path.is_file(): capture(path)
owned=['AppLanguage','AppLanguageStore','AppLanguagePreferences','AppText','AppLocalizer','SelfConfigurationText','AppModelSettingsText']
foundation=[capture(ROOT/'Sources/App'/f'{name}.swift') for name in owned]
apps=[capture(ROOT/'Sources/App'/f'{name}.swift') for name in APP_SOURCES if name not in owned]
apps += [capture(ROOT/'Sources/App/SelfConfigurationSession.swift'), capture(ROOT/'Sources/App/SkillWorkerSettings.swift')]
model_settings=capture(ROOT/'Sources/App/ModelSettings.swift')
views=[capture(ROOT/'Sources/App/SelfConfigurationView.swift'),capture(ROOT/'Sources/App/AppLanguageEnvironment.swift'),capture(ROOT/'Sources/App/SkillWorkerSettingsView.swift')]
fixtures=capture(ROOT/'Tests/AssistantSkillsTests/SelfConfigurationFixtures.swift')
harness=[capture(ROOT/'scripts'/name) for name in ['CheckAppLanguage.swift','CheckAppLanguageResources.swift','CheckAppLanguageHTTP.swift']]
for name,deps in MODULES:
    paths=[capture(p) for p in sorted((ROOT/'Sources'/name).glob('*.swift'))]
    run(name+'-build',['swiftc','-swift-version','5','-parse-as-library','-enable-testing','-emit-module','-emit-library','-module-name',name,'-I',str(OUT),'-L',str(OUT),*paths,*['-l'+d for d in deps],'-emit-module-path',str(OUT/(name+'.swiftmodule')),'-o',str(OUT/('lib'+name+'.dylib'))])
for config,flags in [('Debug',['-DDEBUG']),('Release',[])]:
    binary=OUT/('checks-'+config)
    run(config+'-build',['swiftc','-swift-version','5','-warnings-as-errors','-parse-as-library','-I',str(OUT),'-L',str(OUT),'-lAssistantSkills','-lAssistantModels','-Xlinker','-rpath','-Xlinker',str(OUT),*flags,*foundation,model_settings,fixtures,*harness,'-o',str(binary)])
    run(config+'-run',[str(binary),str(OUT/'source/Sources/App/Resources')],45)
    run(config+'-App-typecheck',['swiftc','-swift-version','5','-typecheck','-I',str(OUT),*flags,*apps,*foundation])
    run(config+'-iOS-syntax',['swiftc','-frontend','-parse','-target','arm64-apple-ios17.0',*flags,*views,*foundation,*apps])
for name,source in [('wrong-parameter','let value: AppText = .configurationStepCount(count: "two")'),('unknown-key','let value: AppText = .arbitraryModelText')]:
    p=OUT/(name+'.swift');p.write_text(source+'\n')
    result=subprocess.run(['swiftc','-typecheck',str(OUT/'source/Sources/App/AppText.swift'),str(p)],capture_output=True,text=True,env=ENV)
    if result.returncode == 0: raise SystemExit('Expected compile-time rejection: '+name)
    report['checks'].append({'name':name,'expected_compile_rejection':True})
report['sources_still_current']=all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in report['source_sha256'].items())
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS: '+str(OUT/'report.json'))
