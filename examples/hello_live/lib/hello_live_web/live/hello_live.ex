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
    "php" => "#777bb4",
    "javascript" => "#e0b400",
    "java" => "#e76f00",
    "go" => "#00add8"
  }

  # Each JavaScript runtime panel's accent, and the option that selects it.
  @runtimes %{
    "node" => {"#5fa04e", ":node"},
    "bun" => {"#f472b6", ":bun"},
    "deno" => {"#111827", ":deno"},
    "quickjs" => {"#e0b400", ":quickjs"}
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, name: "world", cards: Languages.cards(), replies: %{})}
  end

  @impl true
  def handle_event("name", %{"name" => name}, socket) do
    {:noreply, assign(socket, name: name)}
  end

  def handle_event("hello_all", %{"name" => name}, socket) do
    socket = assign(socket, name: name)
    {:noreply, Enum.reduce(Languages.all(), socket, &say_hello(&2, &1.id))}
  end

  def handle_event("hello", %{"card" => card_id}, socket) do
    card = Enum.find(Languages.cards(), &(&1.id == card_id))
    {:noreply, Enum.reduce(card.targets, socket, &say_hello(&2, &1))}
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
    assigns = assign(assigns, accents: @accents, runtimes: @runtimes)

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
          :for={card <- @cards}
          id={"lang-" <> card.id}
          class={"card #{card.width}"}
          style={"--accent: #{@accents[card.id]}"}
        >
          <header>
            <h2>{card.name}</h2>
            <button class="say" phx-click="hello" phx-value-card={card.id}>
              {if length(card.targets) > 1, do: "Say hello on all runtimes", else: "Say hello"}
            </button>
          </header>

          <%= if card.id == "javascript" do %>
            <p class="note">
              The same <code>greeter.js</code>
              on four runtimes, picked with <code>Portals.JavaScript.worker_opts(runtime: ...)</code>.
            </p>
            <div class="runtimes">
              <div
                :for={id <- card.targets}
                id={"target-" <> id}
                class="runtime"
                style={"--accent: #{elem(@runtimes[id], 0)}"}
              >
                <h3>{HelloLive.Languages.fetch!(id).name}</h3>
                <code>runtime: {elem(@runtimes[id], 1)}</code>
                <.reply reply={@replies[id]} />
              </div>
            </div>
          <% else %>
            <div id={"target-" <> hd(card.targets)} class="single">
              <code>
                Portals.Pool.call({inspect(HelloLive.Languages.fetch!(hd(card.targets)).pool)}, "greeter", "hello", [name])
              </code>
              <.reply reply={@replies[hd(card.targets)]} />
            </div>
          <% end %>
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
