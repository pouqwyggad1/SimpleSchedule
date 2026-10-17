using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.RateLimiting;
using SimpleSchedule.Pwa;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 2_000_000);
builder.Services.ConfigureHttpJsonOptions(o => { o.SerializerOptions.MaxDepth = 32; });
builder.Services.AddMemoryCache();
builder.Services.AddHttpClient("supabase", c => c.Timeout = TimeSpan.FromSeconds(25));
builder.Services.AddHttpClient("university", c => c.Timeout = TimeSpan.FromSeconds(25))
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, Credentials = null, PreAuthenticate = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
        ConnectTimeout = TimeSpan.FromSeconds(12), MaxResponseHeadersLength = 32, MaxConnectionsPerServer = 2
    });
builder.Services.AddSingleton(sp => new SupabaseGateway(sp.GetRequiredService<IHttpClientFactory>().CreateClient("supabase"), sp.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton<SessionService>();
builder.Services.AddSingleton(sp => new UniversityService(sp.GetRequiredService<IHttpClientFactory>().CreateClient("university"), sp.GetRequiredService<Microsoft.Extensions.Caching.Memory.IMemoryCache>()));
builder.Services.AddSingleton<ScheduleWorker>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<ScheduleWorker>());
builder.Services.AddHttpClient("push", c => c.Timeout = TimeSpan.FromSeconds(12))
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false, ConnectTimeout = TimeSpan.FromSeconds(8) });
builder.Services.AddSingleton(sp => new PushSender(sp.GetRequiredService<IHttpClientFactory>().CreateClient("push"), sp.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton<PushWorker>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<PushWorker>());
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = 429;
    o.OnRejected = async (context, ct) =>
    {
        int? retryAfterSeconds = context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var delay)
            ? Math.Max(1, (int)Math.Ceiling(delay.TotalSeconds)) : null;
        if (retryAfterSeconds is { } seconds)
            context.HttpContext.Response.Headers.RetryAfter = seconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        await context.HttpContext.Response.WriteAsJsonAsync(new { error = "Слишком много запросов. Подождите немного.", retryAfterSeconds }, ct);
    };
    // Auth email throttling belongs to Supabase: a local RemoteIpAddress bucket behind
    // Render can count independent users together and block delivery after four attempts.
    foreach (var (name, permits, minutes) in new[] { ("auth-verify", 12, 10), ("refresh", 3, 1), ("lists", 30, 1), ("sync", 120, 1) })
        o.AddPolicy(name, ctx => RateLimitPartition.GetFixedWindowLimiter(ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new FixedWindowRateLimiterOptions { PermitLimit = permits, Window = TimeSpan.FromMinutes(minutes), QueueLimit = 0, AutoReplenishment = true }));
});

var app = builder.Build();
// Configure a canonical HTTPS PublicOrigin behind Render. Never trust arbitrary forwarded hosts.
// Only X-Forwarded-Proto affects secure cookie detection; the canonical Origin comparison below
// does not derive an allowlist from proxy headers.
app.UseForwardedHeaders(new ForwardedHeadersOptions { ForwardedHeaders = ForwardedHeaders.XForwardedProto });
app.Use(async (context, next) =>
{
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "no-referrer";
    context.Response.Headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()";
    context.Response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'";
    if (context.Request.Path.StartsWithSegments("/api")) context.Response.Headers.CacheControl = "no-store";
    try
    {
        if (context.Request.Method is "POST" or "PUT" or "PATCH" or "DELETE" && context.Request.Path != "/api/jobs/run")
        {
            string expected = app.Configuration["PublicOrigin"]?.TrimEnd('/') ?? "";
            if (expected.Length == 0 && app.Environment.IsDevelopment())
                expected = context.Request.Scheme + "://" + context.Request.Host;
            if (!Uri.TryCreate(expected, UriKind.Absolute, out var origin) ||
                (!app.Environment.IsDevelopment() && origin.Scheme != "https") ||
                context.Request.Headers.Origin.Count != 1 || context.Request.Headers.Origin.ToString() != expected)
                throw new ApiException(403, "Запрос отклонён: откройте приложение по его основному адресу.");
            if (!context.Request.HasJsonContentType()) throw new ApiException(415, "Ожидается запрос JSON.");
            if (context.Request.Headers["Sec-Fetch-Site"] == "cross-site") throw new ApiException(403, "Запрос с другого сайта запрещён.");
        }
        await next();
    }
    catch (ApiException error)
    {
        context.Response.StatusCode = error.Status;
        if (error.RetryAfterSeconds is { } seconds)
            context.Response.Headers.RetryAfter = seconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        await context.Response.WriteAsJsonAsync(new { error = error.Message, retryAfterSeconds = error.RetryAfterSeconds });
    }
    catch (Exception error) when (error is ArgumentException or InvalidDataException or System.Text.Json.JsonException or BadHttpRequestException)
    { context.Response.StatusCode = 400; await context.Response.WriteAsJsonAsync(new { error = "Некорректный запрос или изменилась разметка расписания. Сохранённые данные доступны." }); }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
    catch (Exception)
    { context.Response.StatusCode = 503; await context.Response.WriteAsJsonAsync(new { error = "Сервис временно недоступен. Локальные изменения сохранены, повторите позже." }); }
});
app.UseRateLimiter();
app.UseDefaultFiles();
app.UseStaticFiles(new StaticFileOptions { OnPrepareResponse = ctx =>
{
    if (ctx.File.Name is "sw.js" or "push-handler.js" or "index.html" or "manifest.webmanifest") ctx.Context.Response.Headers.CacheControl = "no-cache";
} });

app.MapGet("/api/health", (SessionService sessions, ScheduleWorker worker, PushWorker push) => Results.Ok(new { status = "ok", authConfigured = sessions.Configured, automaticRefreshConfigured = worker.Configured, notificationsConfigured = push.Configured }));
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));
app.MapGet("/api/auth/session", async (HttpContext ctx, SessionService sessions, CancellationToken ct) =>
{
    var tokens = await sessions.Get(ctx, ct);
    return Results.Ok(new { configured = sessions.Configured, user = tokens?.User });
});
app.MapPost("/api/auth/request-code", async (EmailRequest body, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) =>
{
    sessions.RequireConfigured(); await gateway.RequestCode(Validation.Email(body.Email), ct);
    return Results.Ok(new { sent = true, retryAfterSeconds = SupabaseGateway.EmailResendIntervalSeconds });
});
app.MapPost("/api/auth/verify-code", async (VerifyRequest body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) =>
{
    sessions.RequireConfigured();
    if (body.Code is null || !System.Text.RegularExpressions.Regex.IsMatch(body.Code, "\\A[0-9]{6}\\z")) throw new ApiException(400, "Введите шестизначный код из письма.");
    var tokens = await gateway.Verify(Validation.Email(body.Email), body.Code, ct);
    await sessions.Create(ctx, tokens, ct); return Results.Ok(new { user = tokens.User });
}).RequireRateLimiting("auth-verify");
app.MapPost("/api/auth/sign-out", async (System.Text.Json.Nodes.JsonObject body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, PushWorker push, CancellationToken ct) => {
    if (push.Configured) {
        if (SessionService.SessionId(ctx) is { } id) await gateway.ServiceRpc("pwa_push_remove_session", new { p_session = id }, ct);
        if (body["deviceId"] is System.Text.Json.Nodes.JsonValue value && value.TryGetValue<string>(out var device) && Guid.TryParseExact(device, "D", out _)) {
            var tokens = await sessions.Get(ctx, ct);
            if (tokens != null) await gateway.ServiceRpc("pwa_push_device", new { p_user = tokens.User.Id, p_device = device, p_remove = true }, ct);
        }
    }
    await sessions.SignOut(ctx, ct); return Results.Ok(new { signedOut = true });
});
app.MapGet("/api/push/config", (PushSender sender, PushWorker worker) => Results.Ok(new { configured = worker.Configured, publicKey = worker.Configured ? sender.PublicKey : "" }));
app.MapPost("/api/push/register", async (PushRegistration body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, PushWorker push, CancellationToken ct) => {
    if (!push.Configured) throw new ApiException(503, "Сервер уведомлений ещё не настроен.");
    var tokens = await sessions.Get(ctx, ct) ?? throw new ApiException(401, "Сначала войдите в аккаунт.");
    SessionService.GuardAccount(ctx, tokens); PushSender.Validate(body);
    await gateway.ServiceRpc("pwa_push_register", new { p_user = tokens.User.Id, p_device = body.DeviceId,
        p_session = SessionService.SessionId(ctx), p_endpoint = body.Endpoint, p_keys = body.Keys }, ct);
    return Results.Ok(new { registered = true });
}).RequireRateLimiting("sync");
app.MapPost("/api/push/device", async (PushDevice body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) => {
    if (!Guid.TryParseExact(body.DeviceId, "D", out _)) throw new ApiException(400, "Некорректное устройство.");
    var tokens = await sessions.Get(ctx, ct) ?? throw new ApiException(401, "Сначала войдите в аккаунт.");
    SessionService.GuardAccount(ctx, tokens);
    var device = await gateway.ServiceRpc("pwa_push_device", new { p_user = tokens.User.Id, p_device = body.DeviceId }, ct);
    return Results.Ok(new { registered = device != null });
}).RequireRateLimiting("sync");
app.MapPost("/api/push/unregister", async (PushDevice body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) => {
    if (!Guid.TryParseExact(body.DeviceId, "D", out _)) throw new ApiException(400, "Некорректное устройство.");
    var tokens = await sessions.Get(ctx, ct) ?? throw new ApiException(401, "Сначала войдите в аккаунт.");
    SessionService.GuardAccount(ctx, tokens);
    await gateway.ServiceRpc("pwa_push_device", new { p_user = tokens.User.Id, p_device = body.DeviceId, p_remove = true }, ct);
    return Results.Ok(new { removed = true });
}).RequireRateLimiting("sync");
app.MapPost("/api/push/test", async (PushDevice body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, PushSender sender, CancellationToken ct) => {
    if (!Guid.TryParseExact(body.DeviceId, "D", out _)) throw new ApiException(400, "Некорректное устройство.");
    var tokens = await sessions.Get(ctx, ct) ?? throw new ApiException(401, "Сначала войдите в аккаунт.");
    SessionService.GuardAccount(ctx, tokens);
    var device = await gateway.ServiceRpc("pwa_push_device", new { p_user = tokens.User.Id, p_device = body.DeviceId, p_test = true }, ct);
    if (device == null) throw new ApiException(429, "Подключите устройство или повторите проверку через минуту.", 60);
    string status = await sender.Send(device.Deserialize<PushRegistration>(SupabaseGateway.Json)!, new { title = "SimpleSchedule", body = "Уведомления на этом устройстве работают.", tag = "simpleschedule-test", url = "/?mode=schedule", expiresAt = DateTimeOffset.UtcNow.AddMinutes(2).ToUnixTimeMilliseconds() }, 120, ct);
    if (status == "expired") await gateway.ServiceRpc("pwa_push_device", new { p_user = tokens.User.Id, p_device = body.DeviceId, p_remove = true }, ct);
    if (status != "sent") throw new ApiException(502, status == "expired" ? "Подписка истекла. Подключите устройство снова." : "Push-служба не приняла уведомление. Повторите позже.");
    return Results.Ok(new { sent = true });
}).RequireRateLimiting("refresh");
app.MapGet("/api/sync", async (HttpContext ctx, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) =>
{
    var tokens = await sessions.Get(ctx, ct) ?? throw new ApiException(401, "Войдите по почте, чтобы включить синхронизацию.");
    SessionService.GuardAccount(ctx, tokens);
    return Results.Ok(await gateway.Sync(tokens.AccessToken, [], ct));
}).RequireRateLimiting("sync");
app.MapPost("/api/sync", async (SyncRequest body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) =>
{
    Validation.Operations(body.Operations);
    var tokens = await sessions.Get(ctx, ct) ?? throw new ApiException(401, "Войдите по почте, чтобы включить синхронизацию.");
    SessionService.GuardAccount(ctx, tokens);
    return Results.Ok(await gateway.Sync(tokens.AccessToken, body.Operations, ct));
}).RequireRateLimiting("sync");
app.MapGet("/api/university/institutes", async (UniversityService university, CancellationToken ct) => Results.Ok(new { options = await university.Institutes(ct) })).RequireRateLimiting("lists");
app.MapGet("/api/university/groups", async (string instituteId, UniversityService university, CancellationToken ct) => Results.Ok(new { options = await university.Groups(instituteId, ct) })).RequireRateLimiting("lists");
app.MapPost("/api/schedule/refresh", async (RefreshRequest body, UniversityService university, CancellationToken ct) => Results.Ok(await university.Refresh(body, ct))).RequireRateLimiting("refresh");
app.MapPost("/api/jobs/run", async (HttpContext ctx, ScheduleWorker worker, PushWorker push, CancellationToken ct) =>
{
    var secret = app.Configuration["Jobs:Secret"];
    string supplied = ctx.Request.Headers.Authorization.ToString();
    if (string.IsNullOrEmpty(secret) || secret.Length < 32 ||
        !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes("Bearer " + secret), Encoding.UTF8.GetBytes(supplied)))
        return Results.Unauthorized();
    int notifications = await push.RunOnce(ct);
    bool processed = worker.Configured && await worker.RunOnce(ct);
    return Results.Ok(new { processed, notifications });
});
app.MapFallback(async ctx =>
{
    if (ctx.Request.Path.StartsWithSegments("/api")) { ctx.Response.StatusCode = 404; await ctx.Response.WriteAsJsonAsync(new { error = "Неизвестный адрес API." }); return; }
    var file = Path.Combine(app.Environment.WebRootPath ?? Path.Combine(app.Environment.ContentRootPath, "wwwroot"), "index.html");
    if (!File.Exists(file)) { ctx.Response.StatusCode = 404; await ctx.Response.WriteAsync("PWA client is not built. Build PWA/client and copy dist to server/wwwroot."); return; }
    ctx.Response.ContentType = "text/html; charset=utf-8"; ctx.Response.Headers.CacheControl = "no-cache"; await ctx.Response.SendFileAsync(file);
});
app.Run();

public partial class Program { }
