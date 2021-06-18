# Build from source
FROM bpfk/agora-builder:latest AS Builder
ARG AGORA_VERSION="HEAD"
WORKDIR /root/faucet/
ADD . /root/faucet/
RUN AGORA_VERSION=${AGORA_VERSION} dub build --skip-registry=all --compiler=ldc2

FROM alpine:edge
WORKDIR /root/faucet/
RUN apk add --no-cache ldc-runtime llvm-libunwind libgcc libsodium sqlite-libs
COPY frontend/ /usr/share/faucet/frontend/
COPY --from=Builder /root/faucet/bin/faucet /usr/bin/faucet
ENTRYPOINT [ "/usr/bin/faucet" ]
