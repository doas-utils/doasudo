# Alpine image with `doas` and `nopass` rule.
# Image is suitable for manual `sudo` / `doas` checks;
# default user is `user` (wheel + editas, nopass rule).
#
#   docker build -f tests/docker/Alpine.Dockerfile -t sudo-shim-alpine .
#   docker run --rm -it sudo-shim-alpine

FROM alpine:3.20

RUN apk add --no-cache doas make socat shadow

# `wheel` for nopass rule; `editas` for default broker access group.
RUN groupadd -f editas \
    && useradd -m -u 1000 -g wheel -G editas user \
    && printf '%s\n' 'permit nopass :wheel' > /etc/doas.conf \
    && chmod 400 /etc/doas.conf

WORKDIR /src

COPY . .

RUN chown -R user /src

USER user
WORKDIR /src
RUN make EDIT_BROKER_TTY=/dev/null \
    && doas make install EDIT_BROKER_TTY=/dev/null \
    && doas sh -c 'cat /etc/doas-sudo-shim/doas-snippet.conf >> /etc/doas.conf' \
    && doas chown -R user /src

CMD ["sh"]
