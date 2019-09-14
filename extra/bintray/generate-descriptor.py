#!/usr/bin/env python3

import os
import copy
import json
import datetime
import subprocess

template = {
    "package": {
        "name": "tarantool",
        "repo": None, # autogenerated
        "subject": "picodata",
        "desc": "Tarantool is an in-memory database and application server",
        "website_url": "https://picodata.io",
        "issue_tracker_url": "https://github.com/picodata/tarantool/issues",
        "vcs_url": "https://github.com/picodata/tarantool.git",
        "github_use_tag_release_notes": False,
        "github_release_notes_file": "RELEASE.txt",
        "licenses": ["BSD"],
        "labels": [],
        "public_download_numbers": False,
        "public_stats": False,
    },
    "version": {
        "name": None, # autogenerated
        "desc": "autogenerated release",
        "released": None, # autogenerated
        "gpgSign": False,
    },
    "files": None, # autogenerated
    "publish": True
}

DESCRIPTOR_FILENAME="descriptor.json"
DESCRIPTOR_PATH=os.path.join("extra/bintray", DESCRIPTOR_FILENAME)

PACKAGE_NAME="tarantool"
PACKAGE_DEBIAN_TAG="main"
PACKAGE_DEBIAN_ARCHITECTURE="amd64"
PACKAGE_RPM_ARCHITECTURE="x86_64"

def package_type(os):
    if os == 'el' or os == 'fedora':
        return 'rpm'
    elif os == 'debian' or os == 'ubuntu':
        return 'deb'

    assert(False)

def exec_capture_stdout(cmd):
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE)
    (stdout, stderr) = proc.communicate()
    return stdout.strip().decode('utf-8')

git_date_cmd = "git show --no-patch --no-notes --pretty='%cd' --date=default HEAD"
def exec_capture_commit_time():
    time = exec_capture_stdout(git_date_cmd)
    dtime = datetime.datetime.strptime(time, "%a %b %d %H:%M:%S %Y %z")
    return dtime.strftime("%Y-%m-%dT%H:%M:%S")

def construct_repo(version, os):
    ptype = package_type(os)
    repo_array = version.split(".")
    repo_array = repo_array[:2]
    repo_array.append(ptype)
    return '-'.join(repo_array)

def construct_debian_upload_pattern():
    return '/'.join(["pool", PACKAGE_DEBIAN_TAG, PACKAGE_NAME[0], PACKAGE_NAME, "$1"])

def construct_rpm_upload_pattern(os, dist):
    return '/'.join([os, "linux", dist, PACKAGE_RPM_ARCHITECTURE, "$1"])

def construct_debian_matrix_params(dist, arch):
    return {
        "deb_distribution": dist,
        "deb_component": PACKAGE_DEBIAN_TAG,
        "deb_architecture": arch,
    }

def construct_debian_files(dist, arch):
    return {
        "includePattern": "build/(.*_" + arch + "\.deb)",
        "uploadPattern":  construct_debian_upload_pattern(),
        "matrixParams":   construct_debian_matrix_params(dist, arch),
    }

def construct_files(os, dist):
    ptype = package_type(os)
    files = []

    if ptype == 'deb':
        files.append(construct_debian_files(dist, "all"))
        files.append(construct_debian_files(dist, PACKAGE_DEBIAN_ARCHITECTURE))
    else:
        files.append({
            "includePattern": "build/(.*\.rpm)",
            "uploadPattern":  construct_rpm_upload_pattern(os, dist),
        })

    return files

def construct_source_upload_pattern(version):
    version_dir = ".".join(version.split(".")[:2])
    return '/'.join([PACKAGE_NAME, version_dir, "$1"])

def construct_source_files(version):
    return [{
        "includePattern": "build/(.*\.tar\.gz)",
        "uploadPattern":  construct_source_upload_pattern(version),
    }]

def main():
    env_os = os.environ.get('OS')
    env_dist = os.environ.get('DIST')
    env_target = os.environ.get('TARGET')

    version = exec_capture_stdout('git describe --long --always')
    if version is None:
        print("Failed to obtain source")

    out = copy.deepcopy(template)
    out['version']['name'] = version

    if env_target == 'source':
        print("Generating %s for %s:%s for source" % (
            DESCRIPTOR_FILENAME,
            PACKAGE_NAME, version,
        ))

        out['package']['repo'] = "source"
        out['version']['released'] = exec_capture_commit_time()
        out['files'] =  construct_source_files(version)

    elif (env_os is not None) and (env_dist is not None):
        print("Generating %s for %s:%s for OS=%s DIST=%s" % (
            DESCRIPTOR_FILENAME,
            PACKAGE_NAME, version,
            env_os,
            env_dist,
        ))

        out['package']['repo'] = construct_repo(version, env_os)
        out['version']['released'] = exec_capture_commit_time()
        out['files'] =  construct_files(env_os, env_dist)

    else:
        print("We shouldn't upload that, skipping")
        exit(0)

    with open(DESCRIPTOR_PATH, 'w') as desc_file:
        json.dump(out, desc_file, indent="  ")
        desc_file.write("\n")

    print("Done. Result in '%s'" % DESCRIPTOR_PATH)

if __name__ == "__main__":
    main()
