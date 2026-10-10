"""Release authority and draft management; package upload is deliberately separate."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
from release_artifacts import sha, verify_local, verify_all, publication_decision

REPO = 'onlo-ai/onlo-mobile-sdks'


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def api(path):
    return json.loads(run('gh', 'api', f'repos/{REPO}/{path}'))


def validate_candidate(version, commit, tag_commit, in_main, protected, ci_passed):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('invalid release version')
    if not re.fullmatch(r'[a-f0-9]{40}', commit) or commit != tag_commit:
        raise ValueError('tag/SHA mismatch')
    if not in_main or not protected:
        raise ValueError('candidate must belong to protected main')
    if not ci_passed:
        raise ValueError('exact-SHA main CI missing or failed')


def authority(version):
    commit = run('git', 'rev-parse', 'HEAD')
    subprocess.run(['git', 'fetch', '--no-tags', 'origin', 'main'], check=True)
    tag = run('git', 'ls-remote', '--tags', 'origin', f'refs/tags/{version}', f'refs/tags/{version}^{{}}')
    refs = dict(line.split()[::-1] for line in tag.splitlines())
    tag_commit = refs.get(f'refs/tags/{version}^{{}}', refs.get(f'refs/tags/{version}'))
    in_main = subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'origin/main']).returncode == 0
    branch = api('branches/main')
    runs = api(f'actions/workflows/release-qualification.yml/runs?head_sha={commit}&event=push&branch=main&per_page=100')['workflow_runs']
    valid = [r for r in runs if r['head_sha'] == commit and r['head_branch'] == 'main' and r['event'] == 'push']
    latest = max(valid, key=lambda r: r['run_number'], default=None)
    validate_candidate(version, commit, tag_commit, in_main, branch['protected'], latest is not None and latest['conclusion'] == 'success')
    if Path('VERSION').read_text().strip() != version:
        raise ValueError('release version differs from source')
    return commit


def release(version):
    return json.loads(run('gh', 'release', 'view', version, '--repo', REPO, '--json', 'isDraft,tagName,assets'))


def unpack(directory):
    with tarfile.open(directory / 'prepared.tar.gz') as archive:
        # Never extract links, devices, absolute paths or traversal members.
        seen, total = set(), 0
        for member in archive:
            if member.name in seen:
                raise ValueError('duplicate prepared archive member')
            seen.add(member.name)
            total += member.size
            if total > 200 * 1024 * 1024:
                raise ValueError('prepared archive exceeds size limit')
            parts = Path(member.name).parts
            if member.name.startswith('/') or '..' in parts or not (member.isfile() or member.isdir()):
                raise ValueError('unsafe prepared archive')
        destination = directory / 'prepared'
        destination.mkdir()
        for member in archive:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.extractfile(member).read())


def restore(version, directory):
    info = release(version)
    if not info['isDraft']:
        raise ValueError('release is public; no mutation allowed')
    directory.mkdir(parents=True, exist_ok=True)
    run('gh', 'release', 'download', version, '--repo', REPO, '--pattern', 'manifest.json', '--pattern', 'prepared.tar.gz', '--dir', str(directory))
    unpack(directory)
    manifest = json.loads((directory / 'manifest.json').read_text())
    if manifest != json.loads((directory / 'prepared/manifest.json').read_text()):
        raise ValueError('manifest assets disagree')
    verify_local(directory / 'prepared', manifest)
    return manifest


def upload_status(version, states, directory):
    path = directory / 'release-status.json'
    path.write_text(json.dumps({'sdks': states, 'decision': publication_decision(states)}, indent=2) + '\n')
    run('gh', 'release', 'upload', version, str(path), '--repo', REPO, '--clobber')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as output:
            output.write('\n| SDK | Registry artifact |\n| --- | --- |\n')
            for name, state in states.items():
                output.write(f'| {name} | {state} |\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['authority', 'draft', 'restore', 'verify', 'finalize'])
    parser.add_argument('version')
    parser.add_argument('--directory', type=Path, default=Path('.release'))
    parser.add_argument('--manifest-sha')
    args = parser.parse_args()
    commit = authority(args.version)
    if args.command == 'authority':
        print(commit)
        return
    directory = args.directory
    if args.command == 'restore':
        manifest = restore(args.version, directory)
        if manifest['commit'] != commit or manifest['version'] != args.version:
            raise ValueError('draft belongs to another source/version')
        return
    manifest_path = directory / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest['commit'] != commit or manifest['version'] != args.version:
        raise ValueError('approved source differs from manifest')
    verify_local(directory, manifest)
    if args.manifest_sha and sha(manifest_path.read_bytes()) != args.manifest_sha:
        raise ValueError('manifest changed after approval request')
    states = verify_all(manifest)
    if args.command == 'draft':
        if publication_decision(states) == 'hard-stop':
            raise ValueError(f'registry preflight blocked: {states}')
        notes = Path('CHANGELOG.md').read_text().split(f'## {args.version}\n', 1)[1].split('\n## ', 1)[0].strip()
        notes_file = directory.parent / 'release-notes.md'
        notes_file.write_text(notes + '\n\nPublication in progress; see release-status.json.\n')
        bundle = directory.parent / 'prepared.tar.gz'
        with tarfile.open(bundle, 'w:gz') as archive:
            for path in sorted(directory.rglob('*')):
                if path.is_file():
                    archive.add(path, arcname=str(path.relative_to(directory)))
        run('gh', 'release', 'create', args.version, str(bundle), str(manifest_path), '--repo', REPO, '--verify-tag', '--draft', '--title', f'Onlo Mobile SDKs {args.version}', '--notes-file', str(notes_file))
        upload_status(args.version, states, directory.parent)
        return
    if not release(args.version)['isDraft']:
        raise ValueError('release must remain draft during verification')
    upload_status(args.version, states, directory.parent)
    if args.command == 'finalize':
        if publication_decision(states) != 'finalize':
            raise ValueError('all four registry artifacts must verify before finalizing')
        run('gh', 'release', 'edit', args.version, '--repo', REPO, '--draft=false')
    elif publication_decision(states) == 'hard-stop':
        raise ValueError('registry verification blocked publication')


if __name__ == '__main__':
    main()
