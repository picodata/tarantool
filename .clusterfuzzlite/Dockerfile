FROM gcr.io/oss-fuzz-base/base-builder
RUN apt-get update && apt-get install -y \
    build-essential cmake make coreutils sed lld \
    autoconf automake libtool zlib1g-dev \
    libreadline-dev libncurses5-dev libssl-dev \
    libunwind-dev luajit wget ninja-build \
    libzstd-dev libyaml-dev libcurl4-openssl-dev

RUN wget https://github.com/unicode-org/icu/releases/download/release-71-1/icu4c-71_1-src.tgz && \
    tar xzvf ./icu4c-71_1-src.tgz -C $SRC

COPY . $SRC/tarantool
WORKDIR $SRC/tarantool

COPY ./.clusterfuzzlite/build.sh $SRC/
