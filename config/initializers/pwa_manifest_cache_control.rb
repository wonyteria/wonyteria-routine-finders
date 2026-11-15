# Keep the canonical manifest URL/start URL stable while allowing metadata updates.
# This wraps Static too: its general one-year asset policy must not cover the manifest.
class PwaManifestCacheControl
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    if env["PATH_INFO"] == "/manifest.json"
      headers = headers.dup
      headers.delete("Cache-Control")
      headers["cache-control"] = "no-cache, max-age=0, must-revalidate"
    end
    [status, headers, body]
  end
end

Rails.application.config.middleware.insert_before(0, PwaManifestCacheControl)
