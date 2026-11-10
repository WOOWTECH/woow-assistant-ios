#!/usr/bin/env python3
"""Actual encrypted LearningStore + browser runner checks; optional unchanged Chat regression.
No production defaults, personal Keychain, network requests or substituted App source.
"""
import argparse,hashlib,json,re,subprocess,tempfile,time
from pathlib import Path
from check_profile_chat_app import APP_SOURCES,MODULES
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--regression',action='store_true')
args=parser.parse_args()
repo=Path(__file__).resolve().parents[1];out=Path(tempfile.mkdtemp(prefix='woow-learning-run-app-'));source=out/'source'
report={'status':'INCOMPLETE','checks':[],'source_sha256':{},'production_source_substitutions':False,'actual_encrypted_store':True,'native_ios_execution':False,'network_requests':0,'actual_mac_webkit':True,'synthetic_local_html':True,'scope':'shared references and single-site research only; multi-source/route unchanged'}
def copy(relative):
    data=(repo/relative).read_bytes();target=source/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    report['source_sha256'][relative]=hashlib.sha256(data).hexdigest();return str(target)
def save():
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(name,command,timeout=180):
    started=time.monotonic();p=subprocess.run(command,capture_output=True,timeout=timeout)
    (out/(name+'.log')).write_bytes(p.stdout+p.stderr)
    row={'name':name,'exit_code':p.returncode,'seconds':round(time.monotonic()-started,3)}
    if name.endswith('-run') and p.returncode==0:
        if name=='research-regression-run':
            match=re.search(rb'PASS research native checks: (\d+) assertions',p.stdout)
            if match is None:raise RuntimeError('research_regression_summary_missing')
            row['result']={'passed':int(match.group(1)),'failed':0}
        else:row['result']=json.loads(p.stdout)
    report['checks'].append(row);save();print(json.dumps(row),flush=True)
    if p.returncode:raise RuntimeError(name+'_failed')
print('REPORT='+str(out/'report.json'),flush=True)
try:
    copy('scripts/check_learning_run_context_app.py');copy('scripts/check_profile_chat_app.py')
    modules={name:[copy(str(p.relative_to(repo))) for p in sorted((repo/'Sources'/name).glob('*.swift'))] for name,_ in MODULES}
    apps=[copy('Sources/App/'+name+'.swift') for name in list(dict.fromkeys(APP_SOURCES+['LearningRunContext']))]
    views=[copy('Sources/App/ContentView.swift'),copy('Sources/App/UserProfileView.swift')]
    harness=copy('scripts/CheckLearningRunContextApp.swift')
    research=copy('Tests/AssistantDomainTests/WebResearchRunnerTests.swift')
    old=copy('scripts/CheckProfileChatApp.swift') if args.regression else None
    for name,deps in MODULES:
        run(name+'-build',['swiftc','-swift-version','5','-parse-as-library','-emit-module','-emit-library','-module-name',name,'-emit-module-path',str(out/(name+'.swiftmodule')),'-I',str(out),'-L',str(out),*modules[name],*['-l'+d for d in deps],'-o',str(out/('lib'+name+'.dylib'))])
    binary=out/'research-regression'
    run('research-regression-build',['swiftc','-swift-version','5','-warnings-as-errors','-parse-as-library','-DWEB_RESEARCH_SMOKE','-I',str(out),'-L',str(out),'-lAssistantModels','-lAssistantBrowser','-Xlinker','-rpath','-Xlinker',str(out),research,'-o',str(binary)])
    run('research-regression-run',[str(binary)],timeout=30)
    for config,flags in [('Debug',['-DDEBUG']),('Release',[])]:
        run(config+'-syntax',['swiftc','-frontend','-parse','-target','arm64-apple-ios17.0',*flags,*apps,*views,harness])
        common=['swiftc','-swift-version','5','-parse-as-library','-I',str(out),'-L',str(out),*['-l'+m for m,_ in MODULES],'-Xlinker','-rpath','-Xlinker',str(out),*flags,*apps]
        binary=out/('checks-'+config)
        run(config+'-build',common+['-DLEARNING_RUN_APP_STANDALONE',harness,'-o',str(binary)])
        # Five distinct native WebKit cases, each with an explicit initial-load
        # deadline; not a retry or a larger production research deadline.
        run(config+'-run',[str(binary)],timeout=400)
        if old:
            binary=out/('chat-regression-'+config)
            run(config+'-chat-build',common+['-DPROFILE_CHAT_APP_STANDALONE',old,'-o',str(binary)])
            run(config+'-chat-run',[str(binary)],timeout=60)
    report['source_still_current']=all(hashlib.sha256((repo/p).read_bytes()).hexdigest()==v for p,v in report['source_sha256'].items())
    report['status']='PASS' if report['source_still_current'] else 'SOURCE_CHANGED'
except (RuntimeError,subprocess.TimeoutExpired) as e:
    report['status']='FAIL';report['failure']='deadline' if isinstance(e,subprocess.TimeoutExpired) else str(e)
finally:
    save();print('REPORT='+str(out/'report.json'),flush=True)
raise SystemExit(0 if report['status']=='PASS' else 1)
