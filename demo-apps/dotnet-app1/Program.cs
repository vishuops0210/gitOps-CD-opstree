var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

string appName = "dotnet-app1";

app.MapGet("/", () => new { app = appName, message = $"Hello from {appName}!" });
app.MapGet("/health", () => new { status = "UP" });

app.Run("http://0.0.0.0:8080");
