# Build from source
FROM alpine:3.12 AS Builder
ARG AGORA_VERSION="HEAD"
WORKDIR /root/faucet/
RUN apk add --no-cache build-base dub ldc libsodium-dev openssl-dev sqlite-dev zlib-dev
ADD . /root/faucet/
RUN AGORA_VERSION=${AGORA_VERSION} dub build --skip-registry=all --compiler=ldc2

FROM alpine:3.12
WORKDIR /root/faucet/
RUN apk add --no-cache ldc-runtime libexecinfo libgcc libsodium sqlite-libs
COPY --from=Builder /root/faucet/bin/faucet /usr/bin/faucet
ENTRYPOINT [ "/usr/bin/faucet" ]
