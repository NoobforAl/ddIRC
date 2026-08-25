# Tor, for exercising the proxy setting against the real thing.
#
# Built from Alpine and its own `tor` package rather than pulled from a
# third-party image. This is the one container in `dev/` whose whole job is
# privacy, and "some stranger's Docker Hub tag" is a poor foundation for that
# even in a development fixture.
FROM alpine:3.21

RUN apk add --no-cache tor

COPY torrc /etc/tor/torrc

# Tor refuses to start unless its data directory is owned by the user it runs
# as, and it will not create one it cannot own. Setting that up here rather
# than in a bind mount matters: a host directory arrives owned by root, which
# is exactly the failure this avoids.
RUN mkdir -p /var/lib/tor && chown -R tor:tor /var/lib/tor && chmod 700 /var/lib/tor

USER tor
EXPOSE 9050

# --verify-config would be nice as a build step, but the data directory does
# not exist until the volume is mounted at run time.
CMD ["tor", "-f", "/etc/tor/torrc"]
