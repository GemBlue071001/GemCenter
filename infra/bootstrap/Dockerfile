FROM python:3.12-alpine

RUN apk add --no-cache nodejs npm zip \
    && pip install --no-cache-dir awscli

COPY bootstrap.sh /bootstrap/bootstrap.sh

ENTRYPOINT ["/bin/sh", "/bootstrap/bootstrap.sh"]
