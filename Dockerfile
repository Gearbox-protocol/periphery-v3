FROM ghcr.io/foundry-rs/foundry:stable

ENV CI=true
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

# install node
RUN apk add --no-cache \
    bash \
    nodejs npm

# install pnpm
RUN wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.bashrc" SHELL="$(which bash)" bash -

WORKDIR /app

COPY . /app

RUN pnpm install && forge build

ENTRYPOINT [ "/app/script/migrate.sh" ]
