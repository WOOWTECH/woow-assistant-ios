#!/usr/bin/env python3
"""Run the exact XCTest bodies against actual Models source; no service or user data."""
import hashlib,json,subprocess,tempfile
from pathlib import Path
repo=Path(__file__).resolve().parents[1]
out=Path(tempfile.mkdtemp(prefix='woow-run-reference-core-'))
paths=sorted(repo.glob('Sources/AssistantModels/*.swift'))+[repo/'Tests/AssistantModelsTests/RunReferenceContextTests.swift',Path(__file__).resolve()]
hashes={}
for p in paths:
    r=p.relative_to(repo);data=p.read_bytes();hashes[str(r)]=hashlib.sha256(data).hexdigest()
    dest=out/r;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
common=['swiftc','-swift-version','5','-warnings-as-errors','-parse-as-library']
subprocess.run(common+['-emit-module','-emit-library','-module-name','AssistantModels','-emit-module-path',str(out/'AssistantModels.swiftmodule')]+list(map(str,sorted((out/'Sources/AssistantModels').glob('*.swift'))))+['-o',str(out/'libAssistantModels.dylib')],check=True,timeout=180)
test=out/'Tests/AssistantModelsTests/RunReferenceContextTests.swift'
subprocess.run(['swiftc','-frontend','-parse','-warnings-as-errors',str(test)],check=True,timeout=30)
subprocess.run(common+['-DRUN_REFERENCE_STANDALONE','-I',str(out),'-L',str(out),'-lAssistantModels','-Xlinker','-rpath','-Xlinker',str(out),str(test),'-o',str(out/'checks')],check=True,timeout=120)
r=subprocess.run([str(out/'checks')],capture_output=True,text=True,check=True,timeout=30)
result=json.loads(r.stdout);assert result['failed']==0 and sum(result['groups'].values())==result['passed']
current=all(hashlib.sha256((repo/p).read_bytes()).hexdigest()==v for p,v in hashes.items())
report={'status':'PASS' if current else 'SOURCE_CHANGED','source_still_current':current,'result':result,'source_sha256':hashes,'warnings_as_errors':True,'native_xctest_execution':False}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(r.stdout.strip());print('REPORT='+str(out/'report.json'))
assert current
