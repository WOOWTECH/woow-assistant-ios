#!/usr/bin/env python3
"""Exact multi-source core bodies and App/real local WebKit reference checks.
No personal credentials, public network, source substitution or infrastructure.
"""
import hashlib,json,re,subprocess,tempfile,time
from pathlib import Path
from check_profile_chat_app import APP_SOURCES,MODULES

repo=Path(__file__).resolve().parents[1]
out=Path(tempfile.mkdtemp(prefix='woow-multi-reference-'));source=out/'source'
report={'status':'INCOMPLETE','source_sha256':{},'checks':[],
        'native_ios_execution':False,'production_source_substitution':False,
        'debug_actual_app_two_webkit_sources':True,'release_webkit_source_reads':False,
        'release_scope':'actual preflight, approved-site capture, cancellation, storage-unavailable; no fixture root reads',
        'scope':'shared references, multi-source research; route replay not integrated',
        'context_ceiling':{'characters':120000,'encoded_message_array_bytes':480000,
            'new_explicit_total_limit':True,
            'basis':'existing 15 x 8000 page allowance; NEW total ceiling also charges system, goal and JSON metadata, so stricter near the limit',
            'required_overflow':'fixed error, no model call; complete observed receipt events retained',
            'references':'whole immutable block omitted if remaining space is insufficient'},
        'website_capture':{'approved_plan_roots_maximum':3,'global_website_rows_maximum':5,
            'combined_reference_characters':6000,'combined_reference_utf8_bytes':24000,
            'origin_deduplicated':True,'reference_urls_grant_navigation':False},
        'transport':'synthetic in-process model; old core regression uses real loopback HTTP',
        'external_network_requests':0,'actual_encrypted_store':True}
def copy(path):
    data=(repo/path).read_bytes();target=source/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    report['source_sha256'][path]=hashlib.sha256(data).hexdigest();return str(target)
def save():
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(name,args,timeout=180):
    start=time.monotonic();p=subprocess.run(args,capture_output=True,timeout=timeout)
    (out/(name+'.log')).write_bytes(p.stdout+p.stderr)
    row={'name':name,'exit_code':p.returncode,'seconds':round(time.monotonic()-start,3)}
    if name.endswith('-run') and p.returncode==0:
        if name=='existing-core-run':
            match=re.search(rb'PASS multisource: (\d+) assertions',p.stdout)
            if match is None:raise RuntimeError('missing_existing_summary')
            row['result']={'passed':int(match.group(1)),'failed':0}
        else:row['result']=json.loads(p.stdout)
    report['checks'].append(row);save();print(json.dumps(row),flush=True)
    if p.returncode:raise RuntimeError(name+'_failed')
print('REPORT='+str(out/'report.json'),flush=True)
try:
    copy('scripts/check_multi_source_references.py');copy('scripts/check_profile_chat_app.py')
    modules={name:[copy(str(p.relative_to(repo))) for p in sorted((repo/'Sources'/name).glob('*.swift'))] for name,_ in MODULES}
    apps=[copy('Sources/App/'+name+'.swift') for name in APP_SOURCES]
    core=copy('Tests/AssistantDomainTests/MultiSourceReferenceTests.swift')
    previous=copy('Tests/AssistantDomainTests/MultiSourceResearchTests.swift')
    app=copy('scripts/CheckMultiSourceReferenceApp.swift')
    for name,deps in MODULES:
        run(name+'-build',['swiftc','-swift-version','5','-enable-testing','-parse-as-library','-emit-module','-emit-library','-module-name',name,'-emit-module-path',str(out/(name+'.swiftmodule')),'-I',str(out),'-L',str(out),*modules[name],*['-l'+d for d in deps],'-o',str(out/('lib'+name+'.dylib'))])
    for name,macro,test in [('reference-core','MULTI_REFERENCE_STANDALONE',core),('existing-core','MULTI_SOURCE_RESEARCH_SMOKE',previous)]:
        binary=out/name
        run(name+'-syntax',['swiftc','-frontend','-parse','-warnings-as-errors',test])
        run(name+'-build',['swiftc','-swift-version','5','-warnings-as-errors','-parse-as-library','-D'+macro,'-I',str(out),'-L',str(out),'-lAssistantModels','-lAssistantBrowser','-Xlinker','-rpath','-Xlinker',str(out),test,'-o',str(binary)])
        run(name+'-run',[str(binary)],timeout=45)
    for config,flags in [('Debug',['-DDEBUG']),('Release',[])]:
        run(config+'-syntax',['swiftc','-frontend','-parse','-target','arm64-apple-ios17.0',*flags,*apps,app])
        binary=out/config
        run(config+'-build',['swiftc','-swift-version','5','-parse-as-library','-DMULTI_REFERENCE_APP_STANDALONE',*flags,'-I',str(out),'-L',str(out),*['-l'+m for m,_ in MODULES],'-Xlinker','-rpath','-Xlinker',str(out),*apps,app,'-o',str(binary)])
        run(config+'-run',[str(binary)],timeout=400)
    report['source_still_current']=all(hashlib.sha256((repo/p).read_bytes()).hexdigest()==h for p,h in report['source_sha256'].items())
    report['status']='PASS' if report['source_still_current'] else 'SOURCE_CHANGED'
except (RuntimeError,subprocess.TimeoutExpired) as e:
    report['status']='FAIL';report['failure']='bounded_deadline' if isinstance(e,subprocess.TimeoutExpired) else str(e)
finally:
    save();print('REPORT='+str(out/'report.json'),flush=True)
raise SystemExit(0 if report['status']=='PASS' else 1)
