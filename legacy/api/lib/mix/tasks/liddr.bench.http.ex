defmodule Mix.Tasks.Liddr.Bench.Http do
  use Mix.Task

  @shortdoc "Benchmarks hot HTTP endpoints against the running dev API"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          scenario: :string,
          base_url: :string,
          concurrency: :integer,
          requests: :integer,
          warmup: :integer,
          request_total: :integer,
          mixed_total: :integer
        ]
      )

    Liddr.Benchmark.Http.run(opts)
  end
end
