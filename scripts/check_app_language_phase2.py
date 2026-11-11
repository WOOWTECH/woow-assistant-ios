#!/usr/bin/env python3
"""Source-bound language phase2: actual URLSession, UN content and App compile.

MCP uses an intercept-all URLProtocol. No real network, notification center,
credentials or user defaults. SwiftUI is parsed only; CI owns native acceptance.
"""
import hashlib,json,os,subprocess,tempfile
from pathlib import Path
from check_task_notifications import APPS,MODULES
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(tempfile.mkdtemp(prefix='woow-language-phase2-check-'))
ENV={k:v for k,v in os.environ.items() if not k.startswith(('WOOW_','LITELLM_'))}
report={'status':'INCOMPLETE','source_sha256':{},'checks':[],'native_ios_ui':False,'swiftui_typecheck':False,'external_network':False,'system_notification_center_access':False}
def capture(relative):
 p=ROOT/relative;data=p.read_bytes();target=OUT/'source'/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);report['source_sha256'][str(relative)]=hashlib.sha256(data).hexdigest();return str(target)
def save(): (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(name,args,timeout=180):
 r=subprocess.run(args,cwd=ROOT,env=ENV,capture_output=True,text=True,timeout=timeout);(OUT/(name+'.log')).write_text(r.stdout+r.stderr)
 row={'name':name,'exit_code':r.returncode}
 if name.endswith('-run') and r.returncode==0:row['result']=json.loads(r.stdout)
 report['checks'].append(row);save();print(json.dumps(row),flush=True)
 if r.returncode:report['status']='FAIL';save();raise SystemExit(str(OUT/(name+'.log')))
print('EVIDENCE='+str(OUT),flush=True)
capture('scripts/check_app_language_phase2.py')
run('resource-parity',['python3','scripts/generate_app_text.py'])
run('resource-negative-tests',['python3','-m','unittest','discover','-s','scripts','-p','test_app_text_resources.py'])
run('ui-launch-language-check',['python3','scripts/check_ui_test_language.py'])
apps=[capture('Sources/App/'+n+'.swift') for n in dict.fromkeys(APPS+['AppSkillCatalogText'])]
views=[capture('Sources/App/'+n+'.swift') for n in ['MCPToolsView','MCPApprovalView','BrowserView','BrowserLibraryView','BrowserSearchSettingsView','SkillCatalogView','TaskNotificationSettingsView']]
foundation=[capture('Sources/App/'+n+'.swift') for n in ['AppLanguage','AppLanguageStore','AppLanguagePreferences','AppText','AppLocalizer','SelfConfigurationText','AppModelSettingsText','ModelSettings']]
foundation_harness=[capture('scripts/'+n+'.swift') for n in ['CheckAppLanguage','CheckAppLanguageResources','CheckAppLanguageHTTP']]
foundation_fixture=capture('Tests/AssistantSkillsTests/SelfConfigurationFixtures.swift')
fixtures=capture('Tests/AssistantMCPTests/MCPProtocolFixture.swift')
harness=capture('scripts/CheckAppLanguagePhase2.swift')
catalog=capture('Sources/AssistantSkills/Resources/MikaBundledSkills.json')
for p in (ROOT/'Sources/App/Resources').rglob('*'):
 if p.is_file():capture(str(p.relative_to(ROOT)))
for name,deps in MODULES:
 paths=[capture(str(p.relative_to(ROOT))) for p in sorted((ROOT/'Sources'/name).glob('*.swift'))]
 run(name+'-build',['swiftc','-swift-version','5','-parse-as-library','-enable-testing','-emit-module','-emit-library','-module-name',name,'-I',str(OUT),'-L',str(OUT),*paths,*['-l'+d for d in deps],'-emit-module-path',str(OUT/(name+'.swiftmodule')),'-o',str(OUT/('lib'+name+'.dylib'))])
for config,flags in [('Debug',['-DDEBUG']),('Release',[])]:
 foundation_binary=OUT/('foundation-'+config)
 run(config+'-foundation-build',['swiftc','-swift-version','5','-warnings-as-errors','-parse-as-library','-I',str(OUT),'-L',str(OUT),'-lAssistantSkills','-lAssistantModels','-Xlinker','-rpath','-Xlinker',str(OUT),*flags,*foundation,foundation_fixture,*foundation_harness,'-o',str(foundation_binary)])
 run(config+'-foundation-run',[str(foundation_binary),str(OUT/'source/Sources/App/Resources')],45)
 binary=OUT/config
 run(config+'-build',['swiftc','-swift-version','5','-parse-as-library','-I',str(OUT),'-L',str(OUT),*['-l'+m for m,_ in MODULES],'-Xlinker','-rpath','-Xlinker',str(OUT),*flags,*apps,fixtures,harness,'-o',str(binary)])
 run(config+'-run',[str(binary),str(OUT/'source/Sources/App/Resources'),catalog],30)
 run(config+'-iOS-syntax',['swiftc','-frontend','-parse','-target','arm64-apple-ios17.0',*flags,*apps,*views,harness])
report['sources_still_current']=all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in report['source_sha256'].items())
report['status']='PASS' if report['sources_still_current'] else 'SOURCE_CHANGED';save();print('REPORT='+str(OUT/'report.json'))
