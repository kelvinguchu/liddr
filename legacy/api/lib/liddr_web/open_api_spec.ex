defmodule LiddrWeb.OpenApiSpec do
  @moduledoc false

  @openapi_version "3.0.3"
  @body_methods MapSet.new(["POST", "PUT", "PATCH"])
  @secure_access MapSet.new(["authenticated", "ops_admin"])

  def spec do
    %{
      "openapi" => @openapi_version,
      "info" => %{
        "title" => "Liddr API",
        "version" => "1.0.0",
        "description" => "Router-derived API surface for development and integration."
      },
      "servers" => [
        %{
          "url" => System.get_env("PUBLIC_API_BASE_URL") || "http://localhost:4000",
          "description" => "Current API base URL"
        }
      ],
      "paths" => build_paths(),
      "components" => %{
        "securitySchemes" => %{
          "bearerAuth" => %{
            "type" => "http",
            "scheme" => "bearer",
            "bearerFormat" => "JWT"
          }
        }
      }
    }
    |> OpenApiSpex.OpenApi.Decode.decode()
  end

  defp build_paths do
    LiddrWeb.ApiContract.route_metadata()
    |> Enum.sort_by(&{&1.path, &1.method})
    |> Enum.reduce(%{}, fn route, acc ->
      method_key = route.method |> String.downcase()
      path_item = Map.get(acc, route.path, %{})
      operation = build_operation(route)
      Map.put(acc, route.path, Map.put(path_item, method_key, operation))
    end)
  end

  defp build_operation(route) do
    %{
      "operationId" => operation_id(route),
      "summary" => summary(route),
      "tags" => [tag(route.path)],
      "responses" => responses(),
      "parameters" => path_parameters(route.path),
      "security" => security(route.access),
      "requestBody" => request_body(route.method),
      "x-liddr-access" => route.access,
      "x-liddr-idempotent" => route.idempotent
    }
    |> compact_map()
  end

  defp responses do
    %{
      "200" => %{
        "description" => "Success",
        "content" => %{
          "application/json" => %{
            "schema" => %{
              "type" => "object",
              "properties" => %{
                "data" => %{"type" => "object", "additionalProperties" => true}
              },
              "required" => ["data"]
            }
          }
        }
      },
      "default" => %{
        "description" => "Error",
        "content" => %{
          "application/json" => %{
            "schema" => %{
              "type" => "object",
              "properties" => %{
                "error" => %{
                  "type" => "object",
                  "properties" => %{
                    "code" => %{"type" => "string"},
                    "message" => %{"type" => "string"},
                    "details" => %{"type" => "object", "additionalProperties" => true}
                  },
                  "required" => ["code", "message"]
                }
              },
              "required" => ["error"]
            }
          }
        }
      }
    }
  end

  defp request_body(method) do
    if MapSet.member?(@body_methods, method) do
      %{
        "required" => true,
        "content" => %{
          "application/json" => %{
            "schema" => %{
              "type" => "object",
              "additionalProperties" => true
            }
          }
        }
      }
    end
  end

  defp security(access) do
    if MapSet.member?(@secure_access, access) do
      [%{"bearerAuth" => []}]
    end
  end

  defp path_parameters(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.filter(&String.starts_with?(&1, ":"))
    |> Enum.map(fn <<":", name::binary>> ->
      %{
        "name" => name,
        "in" => "path",
        "required" => true,
        "schema" => %{"type" => "string"}
      }
    end)
  end

  defp operation_id(route) do
    path =
      route.path
      |> String.trim_leading("/")
      |> String.replace("/", "_")
      |> String.replace(":", "")

    "#{String.downcase(route.method)}_#{path}"
  end

  defp summary(route) do
    action =
      route.action
      |> action_label()
      |> String.replace("_", " ")
      |> String.capitalize()

    "#{action} (#{route.access})"
  end

  defp tag(path) do
    case String.split(path, "/", trim: true) do
      ["api", "ops" | _] -> "ops"
      ["api", "auth" | _] -> "auth"
      ["api", "rides" | _] -> "rides"
      ["api", "subscriptions" | _] -> "subscriptions"
      ["api", "verification" | _] -> "verification"
      ["api", "payments" | _] -> "payments"
      ["api", value | _] -> value
      _ -> "api"
    end
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp action_label(action) when is_atom(action), do: Atom.to_string(action)
  defp action_label(action) when is_binary(action), do: action
  defp action_label(_action), do: "plug"
end
