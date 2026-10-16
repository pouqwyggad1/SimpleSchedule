using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Microsoft.Extensions.Configuration;
using SimpleSchedule.Pwa;

public static class AuthRegression
{
    public static async Task Run(Action<bool, string> expect)
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Supabase:Url"] = "https://project.supabase.co", ["Supabase:PublishableKey"] = "sb_publishable_test",
            ["Supabase:ServiceRoleKey"] = "sb_secret_test"
        }).Build();
        var transport = new FakeAuth();
        var gateway = new SupabaseGateway(new HttpClient(transport), config);
        for (int i = 0; i < 6; i++) await gateway.RequestCode($"user{i}@example.test", CancellationToken.None);
        expect(transport.Count == 6, "independent code requests are delegated to Supabase, without a shared four-send quota");

        transport.Response = () => Rejected("{\"code\":\"over_request_rate_limit\",\"msg\":\"PRIVATE PROVIDER DETAILS\"}", new(TimeSpan.FromSeconds(75)));
        var error = await Rejection(gateway);
        expect(error.Status == 429 && error.RetryAfterSeconds == 75, "provider Retry-After delta reaches API error");
        expect(!error.Message.Contains("PRIVATE"), "provider diagnostics are not exposed");

        transport.Response = () => Rejected("{\"code\":\"over_email_send_rate_limit\"}", new(DateTimeOffset.UtcNow.AddSeconds(120)));
        error = await Rejection(gateway);
        expect(error.RetryAfterSeconds is >= 118 and <= 120, "provider Retry-After HTTP date reaches API error");
        expect(error.Message.Contains("Почтовый сервис"), "provider email quota is distinguishable from code retry cooldown");

        transport.Response = () => Rejected("not-json", null);
        error = await Rejection(gateway);
        expect(error.Status == 429 && error.RetryAfterSeconds == 60, "unknown provider throttle gives a bounded retry suggestion");

        transport.Response = () => Rejected("{}", new(DateTimeOffset.UtcNow.AddSeconds(-120)));
        expect((await Rejection(gateway)).RetryAfterSeconds == 1, "past provider retry time never produces a negative wait");
    }

    private static async Task<ApiException> Rejection(SupabaseGateway gateway)
    {
        try { await gateway.RequestCode("user@example.test", CancellationToken.None); }
        catch (ApiException error) { return error; }
        throw new Exception("Expected provider throttle");
    }

    private static HttpResponseMessage Rejected(string body, RetryConditionHeaderValue? retry)
    {
        var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        response.Headers.RetryAfter = retry;
        return response;
    }

    private sealed class FakeAuth : HttpMessageHandler
    {
        public int Count { get; private set; }
        public Func<HttpResponseMessage> Response { get; set; } = () => new(HttpStatusCode.OK) { Content = new StringContent("{}", Encoding.UTF8, "application/json") };
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            if (request.RequestUri!.AbsolutePath != "/auth/v1/otp") throw new Exception("Unexpected auth test path");
            Count++;
            return Task.FromResult(Response());
        }
    }
}
