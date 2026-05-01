defmodule Mix.Tasks.LinearAgent.Setup do
  @moduledoc """
  Prints the Linear OAuth install URL and validates native agent prerequisites.
  """

  use Mix.Task

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Linear.{Agent, OAuth}

  @shortdoc "Prepare Symphony's Linear Agent integration"

  @impl true
  def run(args) do
    workflow_path = List.first(args) || Path.expand("WORKFLOW.md")
    :ok = Workflow.set_workflow_file_path(Path.expand(workflow_path))
    Application.ensure_all_started(:req)

    config = Config.settings!()
    state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    Mix.shell().info("Linear OAuth install URL:")
    Mix.shell().info(OAuth.authorize_url(state))
    Mix.shell().info("")
    Mix.shell().info("Token file: #{config.linear_agent.token_path}")
    Mix.shell().info("Webhook path: #{config.linear_agent.webhook_path}")

    case OAuth.load_token(config.linear_agent.token_path) do
      {:ok, _token} ->
        validate_required_statuses(config.linear_agent.required_statuses)

      {:error, _reason} ->
        Mix.shell().info("Required status validation skipped until the OAuth token file exists.")
    end
  end

  defp validate_required_statuses(required_statuses) do
    case Agent.validate_required_statuses(required_statuses) do
      :ok ->
        Mix.shell().info("Required Linear statuses are present.")

      {:error, %{missing_statuses: missing}} ->
        Mix.shell().error("Missing required Linear statuses:")

        Enum.each(missing, fn %{team: team, missing: statuses} ->
          Mix.shell().error("- #{team}: #{Enum.join(statuses, ", ")}")
        end)
    end
  end
end
