# Build from source
FROM alpine:3.12 AS Builder
WORKDIR /root/faucet/
RUN apk add --no-cache build-base dub ldc libsodium-dev openssl-dev sqlite-dev zlib-dev
ADD . /root/faucet/
RUN dub build

FROM alpine:3.12
WORKDIR /root/faucet/
RUN apk add --no-cache ldc-runtime libexecinfo libgcc libsodium sqlite-libs
COPY --from=Builder /root/faucet/bin/faucet /usr/bin/faucet
ENTRYPOINT [ "/usr/bin/faucet" ]
