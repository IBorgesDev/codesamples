FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
ENV ANALYTICS_SCHEMA_PATH=/app/schema/events.json
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
COPY --from=schema events.json ./schema/events.json
USER node
EXPOSE 8080
HEALTHCHECK --interval=5s --timeout=3s --retries=10 CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["node", "dist/index.js"]
