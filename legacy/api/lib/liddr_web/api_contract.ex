defmodule LiddrWeb.ApiContract do
  @moduledoc false

  @public_exact_paths MapSet.new([
                        "/api/health",
                        "/api/reports/categories",
                        "/api/openapi",
                        "/api/docs"
                      ])
  @public_prefixes ["/api/auth/"]
  @webhook_paths MapSet.new([
                   "/api/payments/mpesa/stk-callback",
                   "/api/payments/c2b-validation",
                   "/api/payments/c2b-confirmation",
                   "/api/payments/tx-status-callback",
                   "/api/payments/mpesa/c2b-validation",
                   "/api/payments/mpesa/c2b-confirmation",
                   "/api/payments/mpesa/tx-status-callback"
                 ])
  @ops_prefixes ["/api/ops/", "/api/moderation/"]

  def contract_path do
    Path.expand("../../../docs/API_CONTRACT.md", __DIR__)
  end

  def route_metadata do
    routes =
      Phoenix.Router.routes(LiddrWeb.Router)
      |> Enum.filter(&String.starts_with?(&1.path, "/api"))

    idempotent_map = build_idempotent_map(routes)

    Enum.map(routes, fn route ->
      %{
        method: route.verb |> to_string() |> String.upcase(),
        path: route.path,
        access: access_scope(route.path),
        idempotent: Map.get(idempotent_map, {route.plug, route.plug_opts}, false),
        controller: route.plug,
        action: route.plug_opts
      }
    end)
  end

  def channels_metadata do
    [
      %{topic: "driver:*", module: LiddrWeb.DriverChannel, auth: "socket_token_required"},
      %{topic: "ride:*", module: LiddrWeb.RideChannel, auth: "socket_token_required"}
    ]
  end

  def render_markdown do
    routes = route_metadata()
    channels = channels_metadata()

    [
      "# API Contract",
      "",
      "Generated from `api/lib/liddr_web/router.ex` via `mix liddr.contract.sync`.",
      "Do not hand-edit this file.",
      "",
      "## Response Envelope",
      "",
      "- Success: `{ \"data\": ... }`",
      "- Error: `{ \"error\": { \"code\": \"...\", \"message\": \"...\", \"details\": ...? } }`",
      "",
      "## Idempotency",
      "",
      "- Header: `idempotency-key` (8-120 chars).",
      "- Reusing the same key with different payload returns `409 IDEMPOTENCY_KEY_REUSED`.",
      "- Same key while request is still processing returns `409 IDEMPOTENCY_REQUEST_IN_PROGRESS`.",
      "- Invalid key format returns `422 INVALID_IDEMPOTENCY_KEY`.",
      "",
      "## Real-time Channels",
      "",
      channels_markdown(channels),
      "",
      "## HTTP Routes",
      "",
      "| Method | Path | Access | Idempotent | Controller#Action |",
      "|---|---|---|---|---|"
      | route_rows(routes)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp route_rows(routes) do
    Enum.map(routes, fn route ->
      [
        "| ",
        route.method,
        " | `",
        route.path,
        "` | `",
        route.access,
        "` | `",
        yes_no(route.idempotent),
        "` | `",
        inspect(route.controller),
        "#",
        action_label(route.action),
        "` |"
      ]
      |> IO.iodata_to_binary()
    end)
  end

  defp channels_markdown(channels) do
    Enum.map(channels, fn channel ->
      "- `#{channel.topic}` via `#{inspect(channel.module)}` (requires socket token auth)."
    end)
  end

  defp build_idempotent_map(routes) do
    routes
    |> Enum.uniq_by(&{&1.plug, &1.plug_opts})
    |> Enum.reduce(%{}, fn route, acc ->
      Map.put(acc, {route.plug, route.plug_opts}, action_uses_idempotency?(route))
    end)
  end

  defp action_uses_idempotency?(%{plug: controller, plug_opts: action})
       when is_atom(controller) and is_atom(action) do
    with true <- Code.ensure_loaded?(controller),
         source when is_list(source) <- controller.module_info(:compile)[:source],
         source_path <- List.to_string(source),
         true <- File.exists?(source_path),
         {:ok, file_source} <- File.read(source_path),
         {:ok, action_source} <- extract_action_source(file_source, Atom.to_string(action)) do
      String.contains?(action_source, "Idempotency.execute(")
    else
      _ -> false
    end
  end

  defp action_uses_idempotency?(_route), do: false

  defp extract_action_source(file_source, action_name) do
    pattern =
      ~r/def\s+#{Regex.escape(action_name)}\s*\(.*?(?=^\s*defp?\s+[a-zA-Z0-9_!?]+\s*\(|\z)/ms

    case Regex.run(pattern, file_source) do
      [match] -> {:ok, match}
      _ -> :error
    end
  end

  defp access_scope(path) do
    cond do
      MapSet.member?(@public_exact_paths, path) -> "public"
      Enum.any?(@public_prefixes, &String.starts_with?(path, &1)) -> "public"
      MapSet.member?(@webhook_paths, path) -> "public_webhook"
      Enum.any?(@ops_prefixes, &String.starts_with?(path, &1)) -> "ops_admin"
      true -> "authenticated"
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp action_label(action) when is_atom(action), do: Atom.to_string(action)
  defp action_label(action) when is_binary(action), do: action
  defp action_label(action), do: inspect(action)
end
