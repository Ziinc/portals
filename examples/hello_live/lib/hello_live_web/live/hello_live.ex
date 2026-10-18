defmodule HelloLiveWeb.HelloLive do
  @moduledoc """
  Calls `greeter.hello(name)` in a Python, Ruby, PHP, Java and Go worker,
  and in a JavaScript worker on each of Node.js, Bun, Deno and QuickJS.
  Each call runs as a separate async task, so the replies arrive
  independently.
  """

  use Phoenix.LiveView

  alias HelloLive.Languages

  @accents %{
    "python" => "#3776ab",
    "ruby" => "#cc342d",
    "node" => "#5fa04e",
    "bun" => "#f472b6",
    "deno" => "#111827",
    "quickjs" => "#e0b400",
    "php" => "#777bb4",
    "java" => "#e76f00",
    "go" => "#00add8"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, name: "world", languages: Languages.all(), replies: %{})}
  end

  @impl true
  def handle_event("name", %{"name" => name}, socket) do
    {:noreply, assign(socket, name: name)}
  end

  def handle_event("hello_all", %{"name" => name}, socket) do
    socket = assign(socket, name: name)
    {:noreply, Enum.reduce(Languages.all(), socket, &say_hello(&2, &1.id))}
  end

  def handle_event("hello", %{"language" => id}, socket) do
    {:noreply, say_hello(socket, id)}
  end

  defp say_hello(socket, id) do
    name = socket.assigns.name

    socket
    |> update(:replies, &Map.put(&1, id, :pending))
    |> start_async({:hello, id}, fn -> Languages.hello(id, name) end)
  end

  @impl true
  def handle_async({:hello, id}, {:ok, reply}, socket) do
    {:noreply, update(socket, :replies, &Map.put(&1, id, reply))}
  end

  def handle_async({:hello, id}, {:exit, reason}, socket) do
    {:noreply, update(socket, :replies, &Map.put(&1, id, {:error, inspect(reason), 0}))}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :accents, @accents)

    ~H"""
    <main>
      <h1>Hello from supported Portals languages</h1>
      <p class="lede">
        One LiveView, one supervised Portals worker pool per runtime. Each button calls
        <code>greeter.hello(name)</code>
        in another runtime.
      </p>

      <form id="greeting" class="controls" phx-change="name" phx-submit="hello_all">
        <label for="name">Name</label>
        <input id="name" type="text" name="name" value={@name} autocomplete="off" />
        <button class="primary" type="submit">Say hello in all languages</button>
      </form>

      <div class="grid">
        <section
          :for={language <- @languages}
          id={"lang-" <> language.id}
          class="card"
          style={"--accent: #{@accents[language.id]}"}
        >
          <header>
            <h2>{language.name}</h2>
            <button class="say" phx-click="hello" phx-value-language={language.id}>
              Say hello
            </button>
          </header>
          <code>Portals.Pool.call({inspect(language.pool)}, "greeter", "hello", [name])</code>
          <.reply reply={@replies[language.id]} />
        </section>
      </div>
    </main>
    """
  end

  defp reply(%{reply: nil} = assigns), do: ~H|<div class="reply pending">Not called yet</div>|
  defp reply(%{reply: :pending} = assigns), do: ~H|<div class="reply pending">Calling…</div>|

  defp reply(%{reply: {:ok, greeting, micros}} = assigns) do
    assigns = assign(assigns, greeting: greeting, ms: Float.round(micros / 1000, 2))

    ~H"""
    <div class="reply">{@greeting}</div>
    <div class="timing">round trip {@ms} ms</div>
    """
  end

  defp reply(%{reply: {:error, message, _}} = assigns) do
    assigns = assign(assigns, :message, message)
    ~H|<div class="reply error">{@message}</div>|
  end
end
