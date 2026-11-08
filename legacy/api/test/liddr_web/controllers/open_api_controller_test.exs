defmodule LiddrWeb.OpenApiControllerTest do
  use LiddrWeb.ConnCase, async: true

  test "GET /api/openapi returns router-derived OpenAPI JSON", %{conn: conn} do
    conn = get(conn, "/api/openapi")
    assert %{"openapi" => "3.0.3", "paths" => paths} = json_response(conn, 200)
    assert get_in(paths, ["/api/health", "get", "operationId"])
  end

  test "GET /api/docs renders swagger ui", %{conn: conn} do
    conn = get(conn, "/api/docs")
    body = html_response(conn, 200)
    assert body =~ "Swagger UI"
  end
end
