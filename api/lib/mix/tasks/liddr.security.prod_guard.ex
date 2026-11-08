defmodule Mix.Tasks.Liddr.Security.ProdGuard do
  use Mix.Task

  @shortdoc "Fails when production build exposes API docs routes"

  @docs_paths ["/api/openapi", "/api/docs"]

  @impl Mix.Task
  def run(_args) do
    ensure_prod_env!()
    Mix.Task.run("compile")

    docs_enabled? = Application.get_env(:liddr, :api_docs_enabled, false)

    if docs_enabled? do
      Mix.raise("api_docs_enabled must be false in MIX_ENV=prod builds")
    end

    exposed_docs_paths =
      LiddrWeb.Router.__routes__()
      |> Enum.map(& &1.path)
      |> Enum.filter(&(&1 in @docs_paths))

    if exposed_docs_paths != [] do
      Mix.raise("prod router exposes docs routes: #{Enum.join(exposed_docs_paths, ", ")}")
    end

    Mix.shell().info("Prod guard passed: API docs routes are disabled.")
  end

  defp ensure_prod_env! do
    if Mix.env() != :prod do
      Mix.raise("liddr.security.prod_guard must run with MIX_ENV=prod")
    end
  end
end
