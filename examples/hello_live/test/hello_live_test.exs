defmodule HelloLiveWeb.HelloLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint HelloLiveWeb.Endpoint

  @runtimes %{
    "python" => "Python",
    "ruby" => "Ruby",
    "node" => "Node.js",
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

      assert view |> element("#lang-#{id} .reply") |> render() =~
               "Hello, Portals! I&#39;m #{runtime}",
             "no reply from #{runtime} in:\n#{html}"
    end
  end

  test "a single language can be greeted on its own" do
    {:ok, view, _html} = live(build_conn(), "/")

    view |> element("#lang-go button", "Say hello") |> render_click()
    render_async(view, 10_000)

    assert view |> element("#lang-go .reply") |> render() =~ "Hello, world! I&#39;m Go"
    assert view |> element("#lang-python .reply") |> render() =~ "Not called yet"
  end
end
