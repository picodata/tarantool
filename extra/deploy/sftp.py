#!/usr/bin/env python   

import os
import subprocess

import paramiko

def exec_capture_stdout(cmd):
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE)
    (stdout, stderr) = proc.communicate()
    return stdout.strip().decode('utf-8')

git_version_cmd = 'git describe --long --always'
def get_version():
    return exec_capture_stdout(git_version_cmd)

def is_deb(os):
    return (os == 'debian' or os == 'ubuntu')

def is_rpm(os):
    return (os == 'el' or os == 'fedora')

def upload_deb(sftp, src_dir, dst_dir):
    for f in os.listdir(src_dir):
        _, ext = os.path.splitext(f)
        if (ext == '.deb' or ext == '.dsc'):
            src_file = os.path.join(src_dir, f)
            dst_file = os.path.join(dst_dir, f)
            print('uploading %s to %s' % (src_file, dst_file))
            sftp.put(src_file, dst_file)

def upload_rpm(sftp, src_dir, dst_dir):
    for f in os.listdir(src_dir):
        _, ext = os.path.splitext(f)
        if (ext == '.rpm' or ext == '.src.rpm'):
            src_file = os.path.join(src_dir, f)
            dst_file = os.path.join(dst_dir, f)
            print('uploading %s to %s' % (src_file, dst_file))
            sftp.put(src_file, dst_file)

def main():
    env_sftp_host = os.environ.get('SFTP_HOST')
    env_sftp_port = int(os.environ.get('SFTP_PORT'))

    env_sftp_user = os.environ.get('SFTP_USER')
    env_sftp_pass = os.environ.get('SFTP_PASSWORD')

    env_os = os.environ.get('OS')
    env_dist = os.environ.get('DIST')
    version = get_version()

    t = paramiko.Transport((env_sftp_host, env_sftp_port))
    t.connect(None, env_sftp_user, env_sftp_pass)

    sftp = paramiko.SFTPClient.from_transport(t)

    src_dir = 'build/'
    dst_dir = '/'.join([env_os, env_dist, version])

    print('creating directory %s' % (dst_dir))
    sftp.mkdir(dst_dir)

    if is_deb(env_os):        
        upload_deb(sftp, src_dir, dst_dir)
    elif is_rpm(env_os):
        upload_rpm(sftp, src_dir, dst_dir)
    else:
        print("unknown package type")

if __name__ == "__main__":
    main()