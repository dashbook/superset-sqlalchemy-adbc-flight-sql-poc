######################################################################
# Node stage to deal with static asset construction
######################################################################
ARG PY_VER=3.11-slim-bookworm

# if BUILDPLATFORM is null, set it to 'amd64' (or leave as is otherwise).
ARG BUILDPLATFORM=${BUILDPLATFORM:-amd64}
FROM --platform=${BUILDPLATFORM} node:16-bookworm-slim AS superset-node

ARG NPM_BUILD_CMD="build"

RUN apt-get update -qq \
    && apt-get install -yqq --no-install-recommends \
        build-essential \
        python3

ENV BUILD_CMD=${NPM_BUILD_CMD} \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
# NPM ci first, as to NOT invalidate previous steps except for when package.json changes
WORKDIR /app/superset-frontend

RUN --mount=type=bind,target=/frontend-mem-nag.sh,src=./apache-superset/docker/frontend-mem-nag.sh \
    /frontend-mem-nag.sh

RUN --mount=type=bind,target=./package.json,src=./apache-superset/superset-frontend/package.json \
    --mount=type=bind,target=./package-lock.json,src=./apache-superset/superset-frontend/package-lock.json \
    npm ci

COPY ./apache-superset/superset-frontend ./
# This seems to be the most expensive step
RUN npm run ${BUILD_CMD}

######################################################################
# Final lean image...
######################################################################
FROM python:${PY_VER}

# Switching to root to install the required packages
USER root

# Update OS and install packages
RUN apt-get update -qq && \
    apt-get install -yqq --no-install-recommends\
        build-essential \
        ca-certificates \
        curl \
        default-libmysqlclient-dev \
        iputils-ping \
        libpq-dev \
        libboost-all-dev \
        libffi-dev \
        libldap2-dev \
        libsasl2-dev \
        libsqlite3-dev \
        libssl-dev \
        netcat-traditional \
        ninja-build \
        sqlite3 \
        wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create an application user
RUN useradd app_user --create-home

ARG APP_DIR=/app

RUN mkdir --parents ${APP_DIR} && \
    chown app_user:app_user ${APP_DIR} && \
    chown --recursive app_user:app_user /usr/local

USER app_user

WORKDIR ${APP_DIR}

# Setup a Python Virtual environment
ENV VIRTUAL_ENV=${APP_DIR}/venv
RUN python3 -m venv ${VIRTUAL_ENV} && \
    echo ". ${VIRTUAL_ENV}/bin/activate" >> ~/.bashrc && \
    . ~/.bashrc && \
    pip install --upgrade setuptools pip

# Set the PATH so that the Python Virtual environment is referenced for subsequent RUN steps (hat tip: https://pythonspeed.com/articles/activate-virtualenv-dockerfile/)
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Copy the application code into the image
COPY --chown=app_user:app_user . ./adbc

WORKDIR ${APP_DIR}/adbc

# Install Apache Superset (using source)
RUN cp ./superset_config_files/setup.py ./apache-superset && \
    cp ./superset_config_files/sql_lab.py ./apache-superset/superset/sql_lab.py && \
    pip install --editable ./apache-superset

# Install Poetry package manager and then install the local ADBC SQLAlchemy driver project
ENV POETRY_VIRTUALENVS_CREATE="false"
RUN pip install poetry && \
    poetry install

ENV FLASK_APP="superset.app:create_app()"

COPY --chown=app_user:app_user --from=superset-node /app/superset/static/assets apache-superset/superset/static/assets

# Initialize superset
WORKDIR ${APP_DIR}/adbc

EXPOSE 8088

ENTRYPOINT ["scripts/start_superset.sh"]
