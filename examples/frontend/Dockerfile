# syntax=docker/dockerfile:1
FROM node:24-alpine AS build
WORKDIR /src
COPY package.json .
RUN --mount=type=cache,target=/root/.npm npm install --no-audit --no-fund
COPY . .
ARG VITE_FARO_URL=http://faro.lgtm.company.org/demo/collect
RUN npm run build

FROM nginx:1.29-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist /usr/share/nginx/html
EXPOSE 8080
