defmodule HelloLiveWeb.HelloLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint HelloLiveWeb.Endpoint

  @runtimes %{
    "python" => "Python",
    "ruby" => "Ruby",
    "node" => "JavaScript on Node.js",
    "bun" => "JavaScript on Bun",
    "deno" => "JavaScript on Deno",
    "quickjs" => "JavaScript on QuickJS",
    "php" => "PHP",
    "java" => "Java",
    "go" => "Go"
  }

  test "every language says hello" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Hello from supported Portals languages"

    view |> form("form.controls", name: "Portals") |> render_submit()

    for {id, runtime} <- @runtimes do
      html = render_async(view, 10_000)

      assert view |> element("#target-#{id} .reply") |> render() =~
               "Hello, Portals! I&#39;m #{runtime}",
             "no reply from #{runtime} in:\n#{html}"
    end
  end

  test "a single language can be greeted on its own" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#lang-go button", "Say hello") |> render_click()
    render_async(view, 10_000)

    assert view |> element("#target-go .reply") |> render() =~ "Hello, world! I&#39;m Go"
    assert view |> element("#target-python .reply") |> render() =~ "Not called yet"
  end

  test "the JavaScript card greets every runtime at once" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#lang-javascript header button") |> render_click()

    for {id, runtime} <- [node: "Node.js", bun: "Bun", deno: "Deno", quickjs: "QuickJS"] do
      render_async(view, 10_000)

      assert view |> element("#target-#{id} .reply") |> render() =~
               "Hello, world! I&#39;m JavaScript on #{runtime}"
    end

    assert view |> element("#target-go .reply") |> render() =~ "Not called yet"
  end
end
