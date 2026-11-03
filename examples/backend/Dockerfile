# syntax=docker/dockerfile:1
# The example backends, with the OTel Java agent, the Pyroscope agent and its OTel extension in /agents.
# The agents only run when JAVA_TOOL_OPTIONS loads them (examples/docker-compose.yml); Docker Swarm runs the
# same image without them (examples/swarm/stack.yml).
FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /src
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -q -B dependency:go-offline
COPY src src
RUN --mount=type=cache,target=/root/.m2 mvn -q -B package -DskipTests

FROM eclipse-temurin:25-jre
ARG OTEL_AGENT_VERSION=2.33.1
ARG PYROSCOPE_AGENT_VERSION=2.9.2
ARG PYROSCOPE_OTEL_VERSION=2.1.4
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar /agents/
ADD https://github.com/grafana/pyroscope-java/releases/download/v${PYROSCOPE_AGENT_VERSION}/pyroscope.jar /agents/
ADD https://github.com/grafana/otel-profiling-java/releases/download/v${PYROSCOPE_OTEL_VERSION}/pyroscope-otel.jar /agents/
RUN chmod -R a+rX /agents
COPY --from=build /src/target/backend.jar /app/backend.jar
USER 1000
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=70", "-jar", "/app/backend.jar"]
