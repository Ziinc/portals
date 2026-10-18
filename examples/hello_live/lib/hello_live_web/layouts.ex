defmodule HelloLiveWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Hello from supported Portals languages</title>
        <style>
          * { box-sizing: border-box; }
          body { margin: 0; font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
                 background: #f6f7fb; color: #1f2430; }
          main { max-width: 1080px; margin: 0 auto; padding: 40px 32px; }
          h1 { font-size: 30px; margin: 0 0 6px; }
          .lede { color: #5b6275; margin: 0 0 28px; font-size: 16px; }
          form.controls { display: flex; gap: 12px; align-items: center; margin-bottom: 28px; }
          form.controls label { font-weight: 600; }
          input[type=text] { font-size: 17px; padding: 10px 14px; border: 1px solid #cfd4e2;
                             border-radius: 8px; width: 260px; background: white; }
          button { font: inherit; cursor: pointer; border: 0; border-radius: 8px; }
          .primary { background: #4f46e5; color: white; font-size: 16px; font-weight: 600; padding: 11px 18px; }
          .grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 18px; }
          .card.third { grid-column: span 2; }
          .card.half { grid-column: span 3; }
          .card.full { grid-column: 1 / -1; min-height: 0; }
          .single { display: flex; flex-direction: column; gap: 10px; }
          .note { margin: 0; color: #5b6275; font-size: 14px; }
          .runtimes { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; }
          .runtime { border: 1px solid #e6e8f0; border-top: 4px solid var(--accent); border-radius: 10px;
                     padding: 12px 14px; display: flex; flex-direction: column; gap: 6px; background: #fbfbfe; }
          .runtime h3 { margin: 0; font-size: 16px; }
          .runtime .reply { font-size: 15px; min-height: 42px; }
          .card { background: white; border-radius: 12px; padding: 18px; border-top: 5px solid var(--accent);
                  box-shadow: 0 1px 3px rgba(20, 24, 40, .08); display: flex; flex-direction: column; gap: 10px;
                  min-height: 168px; }
          .card header { display: flex; justify-content: space-between; align-items: center; }
          .card h2 { font-size: 19px; margin: 0; }
          .say { background: color-mix(in srgb, var(--accent) 14%, white); color: #1f2430;
                 font-size: 14px; font-weight: 600; padding: 6px 12px; }
          code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12.5px; color: #5b6275; }
          .reply { font-size: 16px; line-height: 1.4; min-height: 46px; }
          .reply.pending { color: #8a90a2; font-style: italic; }
          .reply.error { color: #b42318; }
          .timing { font-size: 13px; color: #8a90a2; }
        </style>
        <script src="/assets/phoenix/phoenix.min.js">
        </script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
            const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: { _csrf_token: csrfToken }
            });
            liveSocket.connect();
          });
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
