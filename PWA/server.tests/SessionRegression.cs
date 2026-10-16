using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.FileProviders;
using SimpleSchedule.Pwa;

public static class SessionRegression
{
    public static async Task Run(Action<bool, string> expect)
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Supabase:Url"] = "https://project.supabase.co", ["Supabase:PublishableKey"] = "sb_publishable_test",
            ["Supabase:ServiceRoleKey"] = "sb_secret_test", ["Session:EncryptionKey"] = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32))
        }).Build();
        var transport = new FakeSupabase();
        var gateway = new SupabaseGateway(new HttpClient(transport), config);
        var sessions = new SessionService(gateway, config);
        var services = new ServiceCollection().AddSingleton<IWebHostEnvironment>(new TestEnvironment()).BuildServiceProvider();
        var create = new DefaultHttpContext { RequestServices = services };
        var original = new TokenSet("ACCESS_TOKEN_PRIVATE", "REFRESH_TOKEN_PRIVATE", DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600, new("user-a", "a@example.test"));
        await sessions.Create(create, original, CancellationToken.None);
        var cookie = create.Response.Headers.SetCookie.ToString();
        expect(cookie.Contains("httponly", StringComparison.OrdinalIgnoreCase) && cookie.Contains("secure", StringComparison.OrdinalIgnoreCase) && cookie.Contains("samesite=strict", StringComparison.OrdinalIgnoreCase), "production cookie HttpOnly Secure Strict");
        expect(!cookie.Contains("ACCESS_TOKEN") && !cookie.Contains("REFRESH_TOKEN") && !cookie.Contains("a@example.test"), "cookie contains no tokens or identity");
        expect(transport.Cipher != null && !transport.Cipher.Contains("TOKEN_PRIVATE") && !transport.Cipher.Contains("a@example.test"), "database payload encrypted");
        var read = new DefaultHttpContext { RequestServices = services };
        read.Request.Headers.Cookie = cookie.Split(';')[0];
        var restored = await sessions.Get(read, CancellationToken.None);
        expect(restored == original, "encrypted session roundtrip");
        try { SessionService.GuardAccount(read, restored!); expect(false, "missing account guard"); }
        catch (ApiException e) { expect(e.Status == 409, "missing intended account denied"); }
        read.Request.Headers["X-SimpleSchedule-Account"] = "user-b";
        try { SessionService.GuardAccount(read, restored!); expect(false, "cross tab account guard"); }
        catch (ApiException e) { expect(e.Status == 409, "different account header cannot upload to new cookie account"); }
        read.Request.Headers["X-SimpleSchedule-Account"] = "user-a";
        SessionService.GuardAccount(read, restored!); expect(true, "matching account accepted");

        // A fresh SessionService instance decrypts the stored session after a process restart.
        var restarted = new SessionService(gateway, config);
        expect(await restarted.Get(read, CancellationToken.None) == original, "session survives process restart with same key");
        var expiredCreate = new DefaultHttpContext { RequestServices = services };
        await sessions.Create(expiredCreate, original with { ExpiresAt = 0 }, CancellationToken.None);
        read.Request.Headers.Cookie = expiredCreate.Response.Headers.SetCookie.ToString().Split(';')[0];
        var refreshed = await sessions.Get(read, CancellationToken.None);
        expect(refreshed?.AccessToken == "NEW_ACCESS" && refreshed.RefreshToken == "NEW_REFRESH" && transport.RefreshCount == 1, "expired access refreshes on server and persists rotated tokens");
        expect(await restarted.Get(read, CancellationToken.None) == refreshed && transport.RefreshCount == 1, "rotated token survives subsequent request without second refresh");
        await sessions.SignOut(read, CancellationToken.None);
        expect(transport.Cipher == null && transport.LogoutCount == 1 && await sessions.Get(read, CancellationToken.None) == null, "signout revokes and removes durable session");
        var corrupted = new DefaultHttpContext { RequestServices = services };
        await sessions.Create(corrupted, original, CancellationToken.None);
        transport.Cipher = "not-valid-base64!";
        read.Request.Headers.Cookie = corrupted.Response.Headers.SetCookie.ToString().Split(';')[0];
        expect(await sessions.Get(read, CancellationToken.None) == null && transport.Cipher == null, "corrupt session fails closed");
    }

    private sealed class FakeSupabase : HttpMessageHandler
    {
        public string? Cipher { get; set; }
        public int RefreshCount { get; private set; }
        public int LogoutCount { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content == null ? null : JsonNode.Parse(await request.Content.ReadAsStringAsync(cancellationToken));
            JsonNode? result = new JsonObject();
            switch (request.RequestUri!.AbsolutePath)
            {
                case "/rest/v1/rpc/pwa_session_create": Cipher = body!["p_payload"]!.GetValue<string>(); break;
                case "/rest/v1/rpc/pwa_session_claim": result = Cipher == null ? new JsonObject { ["missing"] = true } : new JsonObject { ["payload"] = Cipher }; break;
                case "/rest/v1/rpc/pwa_session_release": Cipher = body!["p_payload"]?.GetValue<string>() ?? Cipher; break;
                case "/rest/v1/rpc/pwa_session_remove": Cipher = null; break;
                case "/auth/v1/token":
                    RefreshCount++;
                    result = new JsonObject { ["access_token"] = "NEW_ACCESS", ["refresh_token"] = "NEW_REFRESH", ["expires_in"] = 3600,
                        ["user"] = new JsonObject { ["id"] = "user-a", ["email"] = "a@example.test" } }; break;
                case "/auth/v1/logout": LogoutCount++; break;
                default: throw new Exception("Unexpected Supabase path");
            }
            return new(HttpStatusCode.OK) { Content = new StringContent(result.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }
    private sealed class TestEnvironment : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = "Test";
        public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();
        public string WebRootPath { get; set; } = "";
        public string EnvironmentName { get; set; } = "Production";
        public string ContentRootPath { get; set; } = "";
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
