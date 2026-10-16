FROM node:22-bookworm-slim AS client
WORKDIR /source/client
COPY client/package.json client/package-lock.json ./
RUN npm ci --no-fund
COPY client/ ./
RUN npm run build

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS server
WORKDIR /source/server
COPY server/ ./
RUN dotnet restore SimpleSchedule.Pwa.csproj --locked-mode
RUN dotnet publish SimpleSchedule.Pwa.csproj -c Release -o /out --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=server /out ./
COPY --from=client /source/client/dist/ ./wwwroot/
ENV ASPNETCORE_URLS=http://+:8080
ENV ASPNETCORE_ENVIRONMENT=Production
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "SimpleSchedule.Pwa.dll"]
