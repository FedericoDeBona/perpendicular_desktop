#!/bin/bash
# A visible window is NEVER launched without explicit --run-visible mode or
# opening an explicitly prepared --build-pair app. Pair preparation never runs UI.
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
mode="${1:---build-only}"
if [[ "$mode" != --build-only && "$mode" != --build-pair && "$mode" != --run-visible ]]; then
    echo '{"status":"refused","reason":"use_--build-only_--build-pair_or_explicit_--run-visible"}' >&2
    exit 2
fi
python3 - "$repo_dir" "$mode" "${2:-}" <<'PY'
from pathlib import Path
import hashlib,json,os,plistlib,shutil,stat,subprocess,sys,tempfile
root=Path(sys.argv[1]); mode=sys.argv[2]
probe_keys=('PERPENDICULAR_PRESENTATION_PROBE_MODE','PERPENDICULAR_PRESENTATION_PROBE_PARENT_INVALIDATION','PERPENDICULAR_PRESENTATION_PROBE_HIDDEN_ASSIGNMENT')
requested={key:os.environ[key] for key in probe_keys if key in os.environ}
host_mode=requested.get(probe_keys[0],'standalone')
invalidate=requested.get(probe_keys[1],'0')
hidden=requested.get(probe_keys[2],'0')
if host_mode not in ('standalone','parent-flipped') or invalidate not in ('0','1') or hidden not in ('0','1') or (host_mode=='standalone' and invalidate=='1'):
    print(json.dumps({'status':'refused','reason':'invalid_probe_environment'}));raise SystemExit(2)
output=Path(sys.argv[3]) if sys.argv[3] else Path(tempfile.mkdtemp(prefix='perpendicular-visible-probe-',dir='/tmp'))
if sys.argv[3]:
    if not output.is_absolute() or output.exists() or output.is_symlink():
        print(json.dumps({'status':'refused','reason':'fresh_absolute_output_directory_required'}));raise SystemExit(2)
    output.mkdir(mode=0o700)
assert not output.is_symlink() and output.stat().st_uid==os.geteuid() and stat.S_IMODE(output.stat().st_mode)==0o700
def write_json(name,value):
    data=json.dumps(value,sort_keys=True).encode()+b'\n'
    assert len(data)<=262144
    fd=os.open(output/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    with os.fdopen(fd,'wb') as stream: stream.write(data)
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
inputs={}
for name in ['VMDisplayPresenter.swift','VisiblePresentationProbe.swift']:
    source=root/('macos/PerpendicularDesktop' if name=='VMDisplayPresenter.swift' else 'macos/Tests')/name
    destination=output/name
    with destination.open('xb') as stream: stream.write(source.read_bytes())
    destination.chmod(0o600); inputs[name]=digest(destination)
binary=output/'visible-presentation-probe'
compile_result=subprocess.run(['swiftc','-O','-parse-as-library','-swift-version','6','-warnings-as-errors','-target','arm64-apple-macosx14.0',str(output/'VMDisplayPresenter.swift'),str(output/'VisiblePresentationProbe.swift'),'-o',str(binary)],capture_output=True)
write_json('build.json',{'mode':mode,'source_sha256':inputs,'compiler_exit':compile_result.returncode,'compiler_diagnostics_tail':compile_result.stderr[-8192:].decode(errors='replace'),'ui_executed':False})
if compile_result.returncode:
    print(json.dumps({'status':'build_failed','output':str(output)}));raise SystemExit(1)
binary.chmod(0o700)
binary_sha=digest(binary)
if mode=='--build-only':
    print(json.dumps({'status':'built_not_run','output':str(output),'binary_sha256':binary_sha,'visible_window':False}));raise SystemExit(0)
if mode=='--build-pair':
    variants=[]
    for suffix,value in [('parent-clean','0'),('parent-dirty','1')]:
        private=output/suffix; private.mkdir(mode=0o700)
        title='Perpendicular Presentation '+('Parent Clean' if value=='0' else 'Parent Dirty')
        app=private/(title+'.app'); app.mkdir(mode=0o700)
        contents=app/'Contents'; contents.mkdir(mode=0o700)
        macos=contents/'MacOS'; macos.mkdir(mode=0o700)
        executable=macos/'Probe'; shutil.copyfile(binary,executable); executable.chmod(0o700)
        environment={'PERPENDICULAR_PRESENTATION_PROBE_MODE':'parent-flipped',
            'PERPENDICULAR_PRESENTATION_PROBE_PARENT_INVALIDATION':value,
            'PERPENDICULAR_PRESENTATION_PROBE_HIDDEN_ASSIGNMENT':'0',
            'PERPENDICULAR_PRESENTATION_PROBE_RUN_VISIBLE':'1',
            'PERPENDICULAR_PRESENTATION_PROBE_OUTPUT_DIR':str(private),
            'PERPENDICULAR_DISPLAY_TELEMETRY_DIR':str(private)}
        info={'CFBundleExecutable':'Probe','CFBundleIdentifier':'org.perpendicular.presentation-probe.'+suffix,
            'CFBundleName':title,'CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0',
            'NSHighResolutionCapable':True,'LSEnvironment':environment}
        info_path=contents/'Info.plist'
        with info_path.open('xb') as stream:stream.write(plistlib.dumps(info,sort_keys=True))
        info_path.chmod(0o600)
        assert digest(executable)==binary_sha and plistlib.loads(info_path.read_bytes())==info
        variants.append({'name':suffix,'app':str(app),'output_directory':str(private),
            'environment':environment,'binary_sha256':digest(executable),'info_sha256':digest(info_path)})
    # Keep exactly the same compiler-produced MachO in both bundles: resigning
    # different Info.plists into each executable would change their bytes.
    # These are local test launch bundles, not distributed/signed app packages.
    manifest={'schema':1,'status':'prepared_not_run','compiled_once':True,'ui_executed':False,
        'source_sha256':inputs,'binary_sha256':binary_sha,'variants':variants,
        'controlled_difference':'Only per-lease parent invalidation; both use the same flipped black parent and no per-lease hidden assignment.',
        'bundle_signature':'No app-bundle resign; identical compiler-produced executables. No registration, installation or launch performed.',
        'default_mode_unchanged':'standalone, parent invalidation off, hidden assignment off',
        'runtime_limit_seconds':15,'requested_source_seconds':12,
        'observation_window':'Admit after >=4s and >=1s continuously active/key/visible/unoccluded; end at first tick >=11s. Report interruption and raw counter windows, not total/12 as steady FPS.'}
    write_json('pair.json',manifest)
    print(json.dumps({'status':'prepared_not_run','manifest':str(output/'pair.json'),'binary_sha256':binary_sha,'variants':variants},indent=2))
    raise SystemExit(0)
env={key:value for key,value in os.environ.items() if not key.startswith(('PERPENDICULAR_','DYLD_','QEMU_','VIRGL_','NPT_','ANGLE_'))}
env.update(requested)
env['PERPENDICULAR_DISPLAY_TELEMETRY_DIR']=str(output)
# The watchdog owns ONLY this newly spawned probe PID, never a VM/other app.
# stdout/stderr go to /dev/null; the probe's sole diagnostic output is boundedJSON.
process=subprocess.Popen([str(binary),'--run-visible',str(output)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
timed_out=False
try: code=process.wait(timeout=15)
except subprocess.TimeoutExpired:
    timed_out=True;process.kill();code=process.wait()
write_json('run.json',{'status':'watchdog_timeout' if timed_out else 'exited','exit_code':code,'deadline_seconds':15,'source_sha256':inputs,'binary_sha256':binary_sha,'visible_window_requested':True,'probe_environment':requested})
print(json.dumps({'status':'watchdog_timeout' if timed_out else 'finished','exit_code':code,'output':str(output)}))
raise SystemExit(1 if timed_out or code else 0)
PY
