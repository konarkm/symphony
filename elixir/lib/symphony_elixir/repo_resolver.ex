defmodule SymphonyElixir.RepoResolver do
  @moduledoc """
  Deterministic local repo inventory for agent-side repository resolution.
  """

  alias SymphonyElixir.Config

  @spec configured_roots() :: [Path.t()]
  def configured_roots do
    Config.settings!().linear_agent.repo_roots
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  @spec local_repositories() :: [%{path: Path.t(), remote: String.t() | nil, name: String.t()}]
  def local_repositories do
    configured_roots()
    |> Enum.flat_map(&repos_under_root/1)
    |> Enum.uniq_by(& &1.path)
  end

  @spec find_local(String.t()) :: {:ok, map()} | {:ambiguous, [map()]} | :not_found
  def find_local(query) when is_binary(query) do
    normalized_query = normalize(query)

    matches =
      local_repositories()
      |> Enum.filter(fn repo ->
        normalize(repo.name) == normalized_query or
          String.contains?(normalize(repo.path), normalized_query) or
          (is_binary(repo.remote) and String.contains?(normalize(repo.remote), normalized_query))
      end)

    case matches do
      [repo] -> {:ok, repo}
      [] -> :not_found
      repos -> {:ambiguous, repos}
    end
  end

  defp repos_under_root(root) do
    if File.dir?(root) do
      root
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.flat_map(&repo_info/1)
    else
      []
    end
  end

  defp repo_info(path) do
    if File.dir?(Path.join(path, ".git")) do
      [%{path: path, name: Path.basename(path), remote: git_remote(path)}]
    else
      []
    end
  end

  defp git_remote(path) do
    case System.cmd("git", ["remote", "get-url", "origin"], cd: path, stderr_to_stdout: true) do
      {remote, 0} -> String.trim(remote)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end
