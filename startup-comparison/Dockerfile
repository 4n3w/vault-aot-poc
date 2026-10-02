# One image per app, built from the app's folder:
#   docker build -f startup-comparison/Dockerfile --build-arg JAR=build/libs/startup-<app>-0.0.1.jar <app folder>
# The AOT apps get -Dspring.aot.enabled=true from JAVA_TOOL_OPTIONS in their Deployment.
FROM eclipse-temurin:25-jre
ARG JAR
COPY ${JAR} /app/app.jar
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
