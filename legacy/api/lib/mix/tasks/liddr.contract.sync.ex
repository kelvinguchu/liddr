defmodule Mix.Tasks.Liddr.Contract.Sync do
  use Mix.Task

  @shortdoc "Syncs docs/API_CONTRACT.md from router source"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    output = LiddrWeb.ApiContract.render_markdown()
    output_path = LiddrWeb.ApiContract.contract_path()

    output_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(output_path, output)

    Mix.shell().info("Synced API contract: #{output_path}")
  end
end
