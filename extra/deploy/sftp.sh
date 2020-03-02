#!/bin/bash
VERSION=$(git describe --long --always)
echo ${VERSION}

DIR=${OS}/${DIST}/${VERSION}
echo ${DIR}

for FILE in build/*
do
  FILENAME="${FILE##*/}"
  echo "uploading ${FILE} to ${DIR}/${FILENAME}"
  curl --ftp-create-dirs -T ${FILE} --insecure sftp://${SFTP_USER}:${SFTP_PASSWORD}@${SFTP_SERVER}/${DIR}/${FILENAME}
done  