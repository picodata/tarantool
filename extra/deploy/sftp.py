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
    version = exec_capture_stdout(git_version_cmd)
    version_array = version.split('-')
    version_1 = version_array[0]
    version_array_1 = version_1.split('.')
    version_2 = '.'.join([version_array_1[0], version_array_1[1]])
    return version_2

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
    dist_dir_x86_64 = '/'.join([dst_dir, 'x86_64'])
    dist_dir_sprms  = '/'.join([dst_dir, 'SRPMS'])
    
    for f in os.listdir(src_dir):
        src_file = os.path.join(src_dir, f)
        dst_file = ''

        split = f.split(os.path.extsep, 1)
        if len(split) < 2:
            continue

        ext = split[1]
        if ext == '.rpm':
            dst_file = os.path.join(dist_dir_x86_64, f)
        elif ext == '.src.rpm':
            dst_file = os.path.join(dist_dir_sprms, f)
 
        if dst_file != '':
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
    dst_dir = '/'.join([version, env_os, env_dist])
 
    if is_deb(env_os):        
        upload_deb(sftp, src_dir, dst_dir)
    elif is_rpm(env_os):
        upload_rpm(sftp, src_dir, dst_dir)
    else:
        print("unknown package type")

if __name__ == "__main__":
    main()