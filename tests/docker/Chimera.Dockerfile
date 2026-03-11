# Chimera image with `doas` and `nopass` rule.
# Image is suitable for manual `sudo` / `doas` checks;
# default user is `user` (wheel + editas, nopass rule).
#
#   docker build -f tests/docker/Chimera.Dockerfile -t sudo-shim-chimera .
#   docker run --rm -it sudo-shim-chimera

FROM chimeralinux/chimera:latest

RUN apk add --no-cache opendoas gmake socat shadow

ENV MAKE=gmake

# `wheel` for nopass rule; `editas` for default broker access group.
RUN groupadd -f wheel \
    && groupadd -f editas \
    && useradd -m -u 1000 -g wheel -G editas user \
    && printf '%s\n' 'permit nopass :wheel' > /etc/doas.conf \
    && chmod 400 /etc/doas.conf

WORKDIR /src

COPY . .

RUN chown -R user /src

USER user
WORKDIR /src
RUN gmake EDIT_BROKER_TTY=/dev/null \
    && doas gmake install EDIT_BROKER_TTY=/dev/null \
    && doas sh -c 'cat /etc/doas-sudo-shim/doas-snippet.conf >> /etc/doas.conf' \
    && doas chown -R user /src

CMD ["sh"]
