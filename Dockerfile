# Trivial image so the docker-build job has something real to build.
FROM alpine:3.20
RUN echo "playpen" > /etc/playpen-marker
ENTRYPOINT ["cat", "/etc/playpen-marker"]
